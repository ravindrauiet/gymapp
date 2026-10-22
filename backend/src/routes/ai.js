import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { z } from 'zod';
import { config } from '../config.js';
import { queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { HttpError, badRequest, validate } from '../utils/http.js';

const router = Router();
router.use(requireAuth('user'));

// Every call costs OpenAI credits — cap each member's usage.
router.use(
  rateLimit({
    windowMs: 10 * 60 * 1000,
    limit: 40,
    standardHeaders: true,
    legacyHeaders: false,
    keyGenerator: (req) => req.user.id,
    message: { error: 'Mansi needs a short breather — please try again in a few minutes.' },
  }),
);

const toDataUrl = (b64) => (b64.startsWith('data:') ? b64 : `data:image/jpeg;base64,${b64}`);

/** Calls OpenAI chat completions and maps failures to messages that are safe to show members. */
async function openai(body) {
  if (!config.openaiApiKey) throw badRequest('AI features are not configured on the server yet');
  let response;
  try {
    response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.openaiApiKey}` },
      body: JSON.stringify({ model: config.openaiModel, ...body }),
      signal: AbortSignal.timeout(60_000),
    });
  } catch (err) {
    console.error('OpenAI request failed:', err);
    throw new HttpError(503, 'Mansi is unreachable right now. Please try again.');
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    // Never forward OpenAI's raw error: it can echo part of the API key.
    console.error('OpenAI error:', response.status, data?.error?.message);
    if (response.status === 429) throw new HttpError(503, 'Mansi is getting a lot of questions — try again in a minute.');
    if (response.status === 400) throw badRequest('That image or message could not be processed. Try another one.');
    throw new HttpError(503, 'Mansi is unavailable right now. Please try again shortly.');
  }
  return data.choices?.[0]?.message?.content ?? '';
}

// ---------------------------------------------------------------------------
// 1. Vision: read a meal photo or a packaged-food nutrition label
// ---------------------------------------------------------------------------

const NUTRITION_JSON = `{
  "name": "Concise dish or product name, with brand for packaged food (e.g. 'Paneer Tikka (150 g)' or 'Yoga Bar Protein Bar – Almond Fudge')",
  "servingUnit": "The portion the numbers refer to (e.g. '1 plate (250 g)', '1 bar (50 g)', '100 g')",
  "calories": 250,
  "proteinG": 18.5,
  "carbsG": 22.0,
  "fatG": 8.0,
  "fibreG": 3.5,
  "ironMg": 1.2,
  "calciumMg": 140,
  "sodiumMg": 210,
  "magnesiumMg": 35,
  "category": "One of: Protein, Carbs, Dairy, Meals, Snacks, Lean Meat, Supplements, Beverages, Cereals & Muesli",
  "confidence": "high | medium | low",
  "educationalNotes": "1–2 sentence practical tip about this food for someone who trains"
}`;

const PROMPTS = {
  meal:
    'You are a sports nutritionist who estimates nutrition from food photos, with deep knowledge of Indian home cooking, ' +
    'restaurant dishes and thalis. Identify every item on the plate, estimate realistic portion sizes from visual cues ' +
    '(plate size, cutlery, hands), and sum the nutrition for the whole plate as one serving. ' +
    'If the image does not show food, set name to "Not a food item", all numbers to 0 and confidence to "low".',
  label:
    'You read packaged-food nutrition labels (Nutrition Facts / Nutritional Information panels, including Indian FSSAI labels). ' +
    'Transcribe the values exactly as printed. Prefer the "per serving" column; if only "per 100 g" is printed, use that and set ' +
    'servingUnit to "100 g". Convert kJ to kcal if only energy in kJ is shown (1 kcal = 4.184 kJ). Read the product and brand name ' +
    'from the pack if visible. Use 0 for nutrients not printed. If no label is visible, estimate from the product and set confidence to "low".',
};

router.post('/nutrition-from-image', async (req, res) => {
  const { imageBase64, mode } = validate(
    z.object({
      imageBase64: z.string().min(100, 'imageBase64: image is empty').max(12_000_000, 'Image is too large'),
      mode: z.enum(['meal', 'label']).default('meal'),
    }),
    req.body,
  );

  const content = await openai({
    messages: [
      { role: 'system', content: `${PROMPTS[mode]}\nRespond ONLY with a JSON object of this shape:\n${NUTRITION_JSON}` },
      {
        role: 'user',
        content: [
          { type: 'text', text: mode === 'label' ? 'Read this nutrition label.' : 'Estimate the nutrition of this meal.' },
          // Labels have small print, so they need the high-resolution pass.
          { type: 'image_url', image_url: { url: toDataUrl(imageBase64), detail: mode === 'label' ? 'high' : 'auto' } },
        ],
      },
    ],
    response_format: { type: 'json_object' },
    temperature: 0.2,
    max_tokens: 700,
  });

  let extracted;
  try {
    extracted = JSON.parse(content);
  } catch {
    throw new HttpError(502, 'Could not read that image. Try a clearer photo.');
  }
  const num = (v) => (Number.isFinite(Number(v)) && Number(v) >= 0 ? Number(v) : 0);
  for (const k of ['proteinG', 'carbsG', 'fatG', 'fibreG', 'ironMg', 'calciumMg', 'sodiumMg', 'magnesiumMg']) {
    extracted[k] = Math.round(num(extracted[k]) * 10) / 10;
  }
  extracted.calories = Math.round(num(extracted.calories));
  if (extracted.name === 'Not a food item') {
    throw badRequest("That doesn't look like food or a nutrition label. Try another photo.");
  }
  res.json({ extracted, mode });
});

// ---------------------------------------------------------------------------
// 2. Mansi — the member's AI fitness & nutrition coach
// ---------------------------------------------------------------------------

const chatSchema = z.object({
  messages: z
    .array(z.object({ role: z.enum(['user', 'assistant']), content: z.string().min(1).max(4000) }))
    .min(1)
    .max(60),
  imageBase64: z.string().min(100).max(12_000_000).optional(),
});

/** What Mansi knows about the member, pulled fresh for every reply. */
async function memberContext(userId) {
  const [user, goal, plan, today, week] = await Promise.all([
    queryOne(`SELECT name, city, gender FROM users WHERE id = $1`, [userId]),
    queryOne(`SELECT * FROM user_goals WHERE user_id = $1`, [userId]),
    queryOne(
      `SELECT p.name, s.ends_at FROM subscriptions s JOIN plans p ON p.id = s.plan_id
        WHERE s.user_id = $1 AND s.status = 'active' AND now() BETWEEN s.starts_at AND s.ends_at
        ORDER BY s.ends_at DESC LIMIT 1`,
      [userId],
    ),
    queryOne(
      `SELECT COALESCE(SUM(calories), 0)::int AS kcal, COALESCE(SUM(protein_g), 0)::float AS protein,
              COALESCE(SUM(carbs_g), 0)::float AS carbs, COALESCE(SUM(fat_g), 0)::float AS fat,
              COALESCE(string_agg(food_name, ', '), '') AS foods
         FROM meal_logs WHERE user_id = $1 AND logged_on = (now() AT TIME ZONE $2)::date`,
      [userId, config.tz],
    ),
    queryOne(
      `SELECT (SELECT COUNT(*) FROM checkins WHERE user_id = $1 AND checked_in_at > now() - interval '7 days')::int AS checkins,
              (SELECT COUNT(*) FROM activity_logs WHERE user_id = $1 AND logged_at > now() - interval '7 days')::int AS workouts`,
      [userId],
    ),
  ]);

  const lines = [`Name: ${user?.name ?? 'unknown'}`, `City: ${user?.city ?? 'unknown'}`];
  if (goal) {
    lines.push(
      `Goal: ${goal.goalType.replace('_', ' ')} — ${goal.currentWeightKg} kg now, target ${goal.targetWeightKg} kg`,
      `Body: ${goal.age} y, ${goal.gender}, ${goal.heightCm} cm, activity ${goal.activityLevel.replace('_', ' ')}`,
      `Daily targets: ${goal.dailyCalorieTarget} kcal, protein ${goal.dailyProteinG} g, carbs ${goal.dailyCarbsG} g, fat ${goal.dailyFatG} g`,
    );
  } else {
    lines.push('Goal: not set yet (suggest setting it in the app under Profile → Fitness goal)');
  }
  lines.push(
    today.kcal > 0
      ? `Eaten today: ${today.kcal} kcal, P ${Math.round(today.protein)} g, C ${Math.round(today.carbs)} g, F ${Math.round(today.fat)} g (${today.foods.slice(0, 300)})`
      : 'Eaten today: nothing logged yet',
    `Last 7 days: ${week.checkins} venue check-ins, ${week.workouts} logged workouts`,
    `FitKey plan: ${plan ? `${plan.name} (active)` : 'no active plan'}`,
  );
  return lines.join('\n');
}

router.post('/chat', async (req, res) => {
  const { messages, imageBase64 } = validate(chatSchema, req.body);
  if (messages[messages.length - 1].role !== 'user') throw badRequest('The last message must be from the member');

  const systemPrompt = `You are Mansi, the friendly AI fitness & nutrition coach inside the FITKEY app (India).
Personality: warm, encouraging, practical and honest — like a knowledgeable friend who is a certified trainer and sports nutritionist. You may use light Hinglish if the member writes in Hinglish.

Expertise: strength training & progressive overload, hypertrophy, fat loss, cardio, mobility, yoga, injury-safe form cues, recovery & sleep, and sports nutrition built around Indian food (dal, roti, rice, paneer, curd, eggs, chicken, soya, sattu, sprouts, whey).

What you know about this member right now:
${await memberContext(req.user.id)}

FITKEY app features you can point members to: Explore (gyms, pools, yoga, sports, MMA, dance venues), Check-in with QR, FitKey Pass plans, Fuel Log (meal diary), AI Meal Scanner (photo → macros), Barcode scanner, Studio workout videos, FitPro trainers (online / home / gym), Store (supplements & gear), HealthStop (clinics & chemists), Gym Buddy, Challenges & leaderboard, Progress report.

Rules:
- Personalise answers using the member data above (targets, what they ate today, their goal). Do the maths for them.
- Be concise: short paragraphs, **bold** key numbers, "- " bullet lists, and "### " headings only for longer plans. No tables.
- Give specific quantities (grams, sets × reps, minutes), not vague advice.
- If the member shares a photo, describe what you see and give relevant feedback (meal macros estimate, form check, equipment use).
- Medical safety: you are not a doctor. For pain, injuries, chest pain, dizziness, eating disorders, pregnancy, diabetes or other conditions, give general safe guidance and recommend a doctor (HealthStop in the app lists nearby clinics). Never suggest steroids, extreme diets under 1200 kcal, or unsafe supplements.
- Stay on fitness, health, nutrition, wellbeing and the FITKEY app. Politely steer other topics back.`;

  // Keep the request small: the last 20 turns are plenty of context.
  const history = messages.slice(-20).map((m) => ({ role: m.role, content: m.content }));
  if (imageBase64) {
    const last = history[history.length - 1];
    last.content = [
      { type: 'text', text: last.content },
      { type: 'image_url', image_url: { url: toDataUrl(imageBase64), detail: 'auto' } },
    ];
  }

  const reply = await openai({
    messages: [{ role: 'system', content: systemPrompt }, ...history],
    max_tokens: 900,
    temperature: 0.7,
  });
  res.json({ reply: reply.trim() || "Sorry, I couldn't come up with an answer — could you rephrase that?" });
});

export default router;

import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, validate } from '../utils/http.js';

const router = Router();
router.use(requireAuth('user'));

/**
 * 1. AI Vision: Extract nutrition info from photo of food or label
 */
router.post('/nutrition-from-image', async (req, res) => {
  const schema = z.object({
    imageBase64: z.string().min(20),
  });
  const { imageBase64 } = validate(schema, req.body);

  if (!config.openaiApiKey) {
    throw badRequest('OpenAI API key not configured on server');
  }

  // Format image data URI
  const imageUrl = imageBase64.startsWith('data:')
    ? imageBase64
    : `data:image/jpeg;base64,${imageBase64}`;

  try {
    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${config.openaiApiKey}`,
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [
          {
            role: 'system',
            content:
              'You are a certified sports nutritionist and dietary analyzer. ' +
              'Given an image of a food dish, meal plate, or nutrition facts label, identify the dish and accurately estimate or extract the nutritional composition. ' +
              'Respond ONLY with a JSON object adhering to this schema:\n' +
              '{\n' +
              '  "name": "Concise food or dish title (e.g. 2 Boiled Eggs with Brown Toast, or Paneer Tikka 150g)",\n' +
              '  "servingUnit": "e.g. 1 plate (200g) or 1 serving",\n' +
              '  "calories": 250,\n' +
              '  "proteinG": 18.5,\n' +
              '  "carbsG": 22.0,\n' +
              '  "fatG": 8.0,\n' +
              '  "fibreG": 3.5,\n' +
              '  "ironMg": 1.2,\n' +
              '  "calciumMg": 140,\n' +
              '  "sodiumMg": 210,\n' +
              '  "magnesiumMg": 35,\n' +
              '  "category": "One of: Protein, Carbs, Dairy, Meals, Snacks, Lean Meat, Supplements",\n' +
              '  "educationalNotes": "1-2 sentence tip about this meal for fitness and health."\n' +
              '}',
          },
          {
            role: 'user',
            content: [
              {
                type: 'text',
                text: 'Extract all nutritional and macro/micronutrient information from this food photo or nutrition label.',
              },
              {
                type: 'image_url',
                image_url: { url: imageUrl, detail: 'low' },
              },
            ],
          },
        ],
        response_format: { type: 'json_object' },
        max_tokens: 600,
      }),
    });

    const data = await response.json();
    if (!response.ok) {
      console.error('OpenAI Vision error:', data);
      throw new Error(data.error?.message || 'Failed to extract nutrition from image');
    }

    const content = data.choices[0]?.message?.content;
    const extracted = JSON.parse(content);

    res.json({ extracted });
  } catch (err) {
    console.error('Vision extraction exception:', err);
    res.status(500).json({ error: err.message || 'Vision analysis failed' });
  }
});

/**
 * 2. FitKey AI Coach Chatbot
 */
const chatSchema = z.object({
  messages: z.array(
    z.object({
      role: z.enum(['user', 'assistant', 'system']),
      content: z.string().min(1),
    }),
  ).min(1),
});

router.post('/chat', async (req, res) => {
  const { messages } = validate(chatSchema, req.body);

  if (!config.openaiApiKey) {
    throw badRequest('OpenAI API key not configured on server');
  }

  // Fetch user goals for personalized fitness & macro context
  const userGoal = await queryOne(`SELECT * FROM user_goals WHERE user_id = $1`, [req.user.id]);
  const goalContext = userGoal
    ? `User Fitness Profile: Goal=${userGoal.goal_type || userGoal.goalType}, Daily Calorie Target=${userGoal.daily_calorie_target || userGoal.dailyCalorieTarget} kcal, Daily Protein Target=${userGoal.daily_protein_g || userGoal.dailyProteinG}g, Target Weight=${userGoal.target_weight_kg || userGoal.targetWeightKg}kg.`
    : 'User Fitness Profile: Not configured yet. Advise on general progressive training and balanced nutrition.';

  const systemPrompt =
    'You are "FitKey AI Coach", an elite AI fitness trainer, sports nutritionist and workout companion in the FITKEY mobile app.\n' +
    'Your expertise covers:\n' +
    '- Progressive overload resistance training, hypertrophy, compound lifts, strength programming, cardio, and yoga.\n' +
    '- Sports nutrition, macronutrient splits (protein/carbs/fats), micronutrients, and hydration.\n' +
    '- Tailored advice for Indian & global dietary staples (dal, paneer, roti, sattu, eggs, chicken breast, curd, whey protein).\n' +
    '- Hyperlocal gym & recovery advice.\n\n' +
    `${goalContext}\n\n` +
    'Keep your replies motivating, conversational, scientifically sound, concise, and formatted with clean bullet points where appropriate.';

  try {
    const response = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${config.openaiApiKey}`,
      },
      body: JSON.stringify({
        model: 'gpt-4o-mini',
        messages: [{ role: 'system', content: systemPrompt }, ...messages],
        max_tokens: 800,
        temperature: 0.7,
      }),
    });

    const data = await response.json();
    if (!response.ok) {
      console.error('OpenAI Chat error:', data);
      throw new Error(data.error?.message || 'Chatbot generation failed');
    }

    const reply = data.choices[0]?.message?.content;
    res.json({ reply });
  } catch (err) {
    console.error('Chat exception:', err);
    res.status(500).json({ error: err.message || 'Chatbot response failed' });
  }
});

export default router;

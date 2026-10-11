/**
 * Seeds demo data so the User app has something to show: plans, a demo partner with live venues,
 * FitKey Studio videos, this week's/month's contests, and an admin account (ADMIN_PHONE).
 * Safe to re-run: existing rows are left alone.
 */
import { config } from '../config.js';
import { pool, query, queryOne } from './index.js';

const PLANS = [
  {
    code: 'gym_monthly', name: 'FitKey Gym', sort: 1, price: 149900, days: 30,
    categories: ['gym', 'yoga_studio', 'dance'],
    description: 'Unlimited access to partner gyms, yoga studios and dance classes.',
    features: ['All partner gyms', 'Yoga & dance studios', 'FitKey Studio videos'],
  },
  {
    code: 'sports_monthly', name: 'FitKey Sports', sort: 2, price: 199900, days: 30,
    categories: ['swimming_pool', 'sports_club'],
    description: 'Swimming pools, badminton courts and sports clubs.',
    features: ['Swimming pools', 'Badminton & racquet sports', 'Sports clubs'],
  },
  {
    code: 'combat_monthly', name: 'FitKey Combat', sort: 3, price: 179900, days: 30,
    categories: ['mma', 'martial_arts'],
    description: 'Boxing, MMA, judo and karate centres.',
    features: ['Boxing & MMA gyms', 'Judo / Karate dojos', 'Trainer-led sessions'],
  },
  {
    code: 'all_access_monthly', name: 'FitKey All Access', sort: 0, price: 349900, days: 30,
    categories: ['gym', 'swimming_pool', 'sports_club', 'yoga_studio', 'mma', 'martial_arts', 'dance'],
    description: 'One key to every FITKEY venue.',
    features: ['Every partner venue', 'All categories', 'Priority support'],
  },
];

const photo = (seed, i) => `https://picsum.photos/seed/fitkey-${seed}-${i}/800/500`;
const photos = (seed) => [1, 2, 3, 4, 5].map((i) => photo(seed, i));

const VENUES = [
  { name: 'Iron Paradise Gym', area: 'Indiranagar', categories: ['gym'], lat: 12.9719, lng: 77.6412, trainer: true,
    equipment: ['Treadmills', 'Squat racks', 'Dumbbells up to 50kg', 'Cable machines'], amenities: ['locker', 'shower', 'ac', 'parking'] },
  { name: 'AquaFit Swimming Centre', area: 'Koramangala', categories: ['swimming_pool'], lat: 12.9352, lng: 77.6245, trainer: true,
    equipment: ['25m pool', 'Kickboards'], amenities: ['locker', 'shower', 'changing_room'] },
  { name: 'Shuttle Smash Arena', area: 'HSR Layout', categories: ['sports_club'], lat: 12.9116, lng: 77.6474, trainer: false,
    equipment: ['6 badminton courts', 'Table tennis'], amenities: ['parking', 'drinking_water', 'changing_room'] },
  { name: 'Prana Yoga Studio', area: 'Jayanagar', categories: ['yoga_studio'], lat: 12.925, lng: 77.5838, trainer: true,
    equipment: ['Mats', 'Blocks', 'Straps'], amenities: ['ac', 'drinking_water'] },
  { name: 'Knockout MMA Club', area: 'Whitefield', categories: ['mma', 'martial_arts'], lat: 12.9698, lng: 77.75, trainer: true,
    equipment: ['Boxing ring', 'Heavy bags', 'Mats'], amenities: ['locker', 'shower', 'parking'] },
  { name: 'Groove Dance & Zumba', area: 'Malleshwaram', categories: ['dance'], lat: 13.0035, lng: 77.5709, trainer: true,
    equipment: ['Sound system', 'Mirrors'], amenities: ['ac', 'changing_room'] },
  { name: 'PowerHouse Fitness', area: 'BTM Layout', categories: ['gym'], lat: 12.9166, lng: 77.6101, trainer: true,
    equipment: ['Free weights', 'Cardio zone', 'Functional area'], amenities: ['locker', 'shower', 'ac', 'wifi'] },
];

const SAMPLE = 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample';
const VIDEOS = [
  ['gym', 'Full Body Strength — 30 min', 'Rahul Verma', 'beginner', `${SAMPLE}/ForBiggerBlazes.mp4`, 1800],
  ['gym', 'Push Day Hypertrophy', 'Rahul Verma', 'intermediate', `${SAMPLE}/ForBiggerEscapes.mp4`, 2400],
  ['yoga', 'Morning Sun Salutations', 'Ananya Iyer', 'beginner', `${SAMPLE}/ForBiggerFun.mp4`, 1200],
  ['yoga', 'Hip Mobility Flow', 'Ananya Iyer', 'intermediate', `${SAMPLE}/ForBiggerJoyrides.mp4`, 1500],
  ['dance', 'Zumba Cardio Party', 'Priya Nair', 'beginner', `${SAMPLE}/ForBiggerMeltdowns.mp4`, 1800],
  ['boxing', 'Boxing Basics: Stance & Jab', 'Vikram Singh', 'beginner', `${SAMPLE}/ForBiggerBlazes.mp4`, 900],
  ['boxing', 'Heavy Bag HIIT', 'Vikram Singh', 'advanced', `${SAMPLE}/ForBiggerEscapes.mp4`, 1200],
  ['martial_arts', 'Karate Kata for Beginners', 'Sensei Kenji Rao', 'beginner', `${SAMPLE}/ForBiggerFun.mp4`, 1300],
  ['martial_arts', 'Judo Breakfalls (Ukemi)', 'Sensei Kenji Rao', 'beginner', `${SAMPLE}/ForBiggerJoyrides.mp4`, 1000],
];

async function seed() {
  for (const p of PLANS) {
    await query(
      `INSERT INTO plans (code, name, description, categories, price_paise, duration_days, features, sort_order)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8) ON CONFLICT (code) DO NOTHING`,
      [p.code, p.name, p.description, p.categories, p.price, p.days, p.features, p.sort],
    );
  }
  console.log(`✔ Plans (${PLANS.length})`);

  const partner = await queryOne(
    `INSERT INTO users (phone, role, name, email, city) VALUES ('+910000000001', 'partner', 'Demo Partner', 'partner@fitkey.demo', 'Bengaluru')
     ON CONFLICT (phone, role) DO UPDATE SET updated_at = now() RETURNING id`,
  );
  for (const v of VENUES) {
    const exists = await queryOne(`SELECT 1 FROM venues WHERE owner_id = $1 AND name = $2`, [partner.id, v.name]);
    if (exists) continue;
    await query(
      `INSERT INTO venues (owner_id, name, description, categories, address, area, city, latitude, longitude,
         opens_at, closes_at, open_days, contact_phone, trainer_available, equipment, amenities, photos, status)
       VALUES ($1, $2, $3, $4, $5, $6, 'Bengaluru', $7, $8, '06:00', '22:00', '{mon,tue,wed,thu,fri,sat,sun}',
               '+910000000001', $9, $10, $11, $12, 'live')`,
      [partner.id, v.name, `${v.name} — a FITKEY partner venue in ${v.area}.`, v.categories, `${v.area}, Bengaluru`,
        v.area, v.lat, v.lng, v.trainer, v.equipment, v.amenities, photos(v.name.replace(/\W+/g, '').toLowerCase())],
    );
  }
  console.log(`✔ Demo partner (+910000000001) with ${VENUES.length} live venues in Bengaluru`);

  const videoCount = await queryOne(`SELECT COUNT(*) AS n FROM videos`);
  if (videoCount.n === 0) {
    for (const [category, title, trainer, level, url, secs] of VIDEOS) {
      await query(
        `INSERT INTO videos (category, title, description, trainer_name, level, video_url, duration_seconds)
         VALUES ($1, $2, $3, $4, $5, $6, $7)`,
        [category, title, `${title} with FITKEY trainer ${trainer}.`, trainer, level, url, secs],
      );
    }
  }
  console.log('✔ FitKey Studio videos');

  const contestCount = await queryOne(
    `SELECT COUNT(*) AS n FROM contests WHERE ends_on >= (now() AT TIME ZONE $1)::date`,
    [config.tz],
  );
  if (contestCount.n === 0) {
    await query(
      `WITH t AS (SELECT (now() AT TIME ZONE $1)::date AS d)
       INSERT INTO contests (title, description, period, metric, starts_on, ends_on, reward)
       SELECT 'Weekly Check-in Champion', 'Check in on as many days as you can this week.', 'weekly', 'checkins',
              date_trunc('week', t.d)::date, (date_trunc('week', t.d) + interval '6 days')::date, 'FITKEY T-shirt + 1 week free' FROM t
       UNION ALL
       SELECT 'Monthly 50K Run', 'Log your runs — highest distance this month wins.', 'monthly', 'running_km',
              date_trunc('month', t.d)::date, (date_trunc('month', t.d) + interval '1 month - 1 day')::date, '₹2,000 sportswear voucher' FROM t
       UNION ALL
       SELECT 'Streak Master', 'Longest streak of consecutive check-in days this month.', 'monthly', 'streak',
              date_trunc('month', t.d)::date, (date_trunc('month', t.d) + interval '1 month - 1 day')::date, '1 month All Access free' FROM t`,
      [config.tz],
    );
  }
  console.log('✔ Contests');

  if (config.adminPhone) {
    await query(
      `INSERT INTO users (phone, role, name) VALUES ($1, 'admin', 'FITKEY Admin') ON CONFLICT (phone, role) DO NOTHING`,
      [config.adminPhone],
    );
    console.log(`✔ Admin account ${config.adminPhone}`);
  }
}

try {
  await seed();
} catch (err) {
  console.error('✖ Seed failed:', err.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}

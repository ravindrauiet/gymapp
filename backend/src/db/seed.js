/**
 * Seeds demo data so the User app has something to show: plans, a demo partner with live venues,
 * FitKey Studio videos, this week's/month's contests, and an admin account (ADMIN_PHONE).
 * Safe to re-run: existing rows are left alone.
 */
import { config } from '../config.js';
import { photosFor } from './demoPhotos.js';
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
        v.area, v.lat, v.lng, v.trainer, v.equipment, v.amenities, photosFor(v.categories, VENUES.indexOf(v))],
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

  // ---- 3. Food items (Food Encyclopedia) ------------------------------------
  const foodCount = await queryOne(`SELECT COUNT(*) AS n FROM food_items`);
  if (+foodCount.n === 0) {
    const FOODS = [
      { name: '1 Boiled Egg (Large)', unit: '1 egg (50g)', cal: 78, p: 6.3, c: 0.6, f: 5.3, fib: 0.0, fe: 0.6, mg: 6, ca: 25, na: 62, cat: 'Protein', notes: 'Rich in choline and complete protein with all 9 essential amino acids.' },
      { name: '1 Whole Wheat Roti', unit: '1 roti (40g)', cal: 104, p: 3.1, c: 20.2, f: 0.9, fib: 2.8, fe: 1.2, mg: 38, ca: 15, na: 115, cat: 'Carbs', notes: 'Complex carbs providing sustained energy with natural dietary fiber.' },
      { name: '100g Fresh Paneer (Cottage Cheese)', unit: '100g', cal: 265, p: 18.3, c: 4.2, f: 20.8, fib: 0.0, fe: 0.2, mg: 25, ca: 480, na: 22, cat: 'Dairy & Protein', notes: 'Slow-digesting casein protein, ideal for overnight muscle repair and high calcium.' },
      { name: 'Chicken Breast (Grilled/Raw)', unit: '100g', cal: 165, p: 31.0, c: 0.0, f: 3.6, fib: 0.0, fe: 1.0, mg: 29, ca: 15, na: 74, cat: 'Lean Meat', notes: 'Gold standard lean protein with near zero fat and carbs.' },
      { name: 'Yellow Dal Tadka (Cooked)', unit: '1 bowl (150g)', cal: 168, p: 9.2, c: 22.4, f: 4.8, fib: 5.2, fe: 2.4, mg: 45, ca: 38, na: 310, cat: 'Lentils', notes: 'High dietary fiber and complex carbohydrates for digestive gut balance.' },
      { name: 'Cooked Brown Rice', unit: '1 cup (150g)', cal: 166, p: 3.8, c: 35.2, f: 1.4, fib: 2.4, fe: 0.8, mg: 56, ca: 10, na: 5, cat: 'Grains', notes: 'Whole grain retaining bran and germ, lower glycemic index than white rice.' },
      { name: 'Whey Protein Isolate Scoop', unit: '1 scoop (30g)', cal: 120, p: 27.0, c: 1.0, f: 0.5, fib: 0.0, fe: 0.4, mg: 24, ca: 130, na: 90, cat: 'Supplements', notes: 'Fastest absorbing protein, best consumed within 45 mins post-workout.' },
      { name: 'Rolled Oats with Milk', unit: '1 bowl (200g)', cal: 210, p: 8.5, c: 32.0, f: 5.0, fib: 4.0, fe: 1.8, mg: 62, ca: 180, na: 120, cat: 'Breakfast Grains', notes: 'Rich in beta-glucan soluble fiber to help maintain healthy lipid profiles.' },
      { name: 'Ripe Banana', unit: '1 medium (118g)', cal: 105, p: 1.3, c: 27.0, f: 0.3, fib: 3.1, fe: 0.3, mg: 32, ca: 6, na: 1, cat: 'Fruits', notes: 'High in potassium and fast carbohydrates, prevents workout cramping.' },
      { name: 'Natural Greek Yogurt', unit: '100g', cal: 97, p: 10.0, c: 3.6, f: 5.0, fib: 0.0, fe: 0.1, mg: 11, ca: 110, na: 36, cat: 'Dairy', notes: 'Twice the protein of regular curd and packed with live active gut probiotics.' },
      { name: 'California Almonds', unit: '10 pieces (15g)', cal: 87, p: 3.2, c: 3.1, f: 7.4, fib: 1.8, fe: 0.6, mg: 40, ca: 39, na: 1, cat: 'Nuts & Healthy Fats', notes: 'Natural Vitamin E and monounsaturated fatty acids for cardiovascular health.' },
      { name: 'Atlantic Salmon Fillet', unit: '100g', cal: 206, p: 22.1, c: 0.0, f: 12.3, fib: 0.0, fe: 0.5, mg: 30, ca: 12, na: 59, cat: 'Seafood', notes: 'Rich in anti-inflammatory EPA and DHA Omega-3 fatty acids.' },
    ];
    for (const f of FOODS) {
      await query(
        `INSERT INTO food_items (name, serving_unit, calories, protein_g, carbs_g, fat_g, fibre_g, iron_mg, magnesium_mg, calcium_mg, sodium_mg, category, educational_notes)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
        [f.name, f.unit, f.cal, f.p, f.c, f.f, f.fib, f.fe, f.mg, f.ca, f.na, f.cat, f.notes],
      );
    }
    console.log(`✔ Food encyclopedia items (${FOODS.length})`);
  }

  // ---- 2. Marketplace Vendor & Products -------------------------------------
  const vendor = await queryOne(
    `INSERT INTO marketplace_vendors (partner_id, business_name, gstin, bank_name, bank_account_no, ifsc_code, verification_status)
     VALUES ($1, 'Apex Fitness Gear & Nutrition', '29AABCU9603R1ZM', 'HDFC Bank', '50100456789123', 'HDFC0000123', 'verified')
     ON CONFLICT (partner_id) DO UPDATE SET verification_status = 'verified' RETURNING id`,
    [partner.id],
  );

  const productCount = await queryOne(`SELECT COUNT(*) AS n FROM marketplace_products`);
  if (+productCount.n === 0) {
    const PRODUCTS = [
      {
        title: 'Optimum Nutrition Gold Standard 100% Whey (Double Rich Chocolate 2 lbs)',
        brand: 'Optimum Nutrition',
        category: 'supplements',
        desc: 'The world\'s #1 best-selling whey protein powder. Delivers 24g of whey protein with primary source Whey Protein Isolate and 5.5g of naturally occurring BCAAs.',
        price: 319900,
        origPrice: 389900,
        stock: 25,
        images: ['https://images.unsplash.com/photo-1579722821273-0f6c7d44362f?w=600', 'https://images.unsplash.com/photo-1593095948071-474c5cc2989d?w=600'],
        specs: { "Protein Per Serving": "24g", "BCAAs": "5.5g", "Servings Per Tub": "30", "Flavor": "Double Rich Chocolate", "Dietary Preference": "Vegetarian" },
      },
      {
        title: 'MuscleBlaze Creatine Monohydrate CreAMP (250g)',
        brand: 'MuscleBlaze',
        category: 'supplements',
        desc: 'Micronized creatine monohydrate engineered for rapid ATP regeneration, explosive power output and accelerated intra-workout muscular endurance.',
        price: 89900,
        origPrice: 119900,
        stock: 40,
        images: ['https://images.unsplash.com/photo-1593095948071-474c5cc2989d?w=600'],
        specs: { "Type": "Micronized 200 Mesh", "Creatine Per Scoop": "3g", "Servings": "83", "Flavour": "Unflavoured" },
      },
      {
        title: 'FitKey Pro Seamless Athletic T-Shirt (Stealth Black)',
        brand: 'FitKey Apparel',
        category: 'apparel',
        desc: 'Engineered 4-way stretch fabric with moisture-wicking capillary microfibers and laser-cut ventilation zones for supreme comfort during heavy lifting.',
        price: 129900,
        origPrice: 199900,
        stock: 60,
        images: ['https://images.unsplash.com/photo-1521572267360-ee0c2909d518?w=600', 'https://images.unsplash.com/photo-1581655353564-df123a1eb820?w=600'],
        specs: { "Material": "88% Polyester, 12% Spandex", "Fit": "Athletic Modern Fit", "Wash Care": "Machine Wash Cold", "Anti-Odor": "Silver-Ion treated" },
      },
      {
        title: 'Under Armour HeatGear 7" Training Shorts (Carbon Grey)',
        brand: 'Under Armour',
        category: 'apparel',
        desc: 'Ultra-lightweight stretch woven outer shorts with supportive internal liner, zippered utility pocket and breathable mesh side panels.',
        price: 189900,
        origPrice: 249900,
        stock: 35,
        images: ['https://images.unsplash.com/photo-1562183241-b937e95585b6?w=600'],
        specs: { "Inseam": "7 inches", "Pockets": "2 hand pockets + 1 zip phone pocket", "Technology": "HeatGear Fast Dry" },
      },
      {
        title: 'Fitbit Charge 6 Fitness Tracker with Heart Rate & GPS',
        brand: 'Fitbit',
        category: 'wearables',
        desc: 'Advanced health tracker with built-in GPS, optical PPG heart rate sensor, SpO2 blood oxygen tracking, EDA stress scanner, and up to 7-day battery life.',
        price: 1499900,
        origPrice: 1699900,
        stock: 15,
        images: ['https://images.unsplash.com/photo-1575311373937-040b8e1fd5b6?w=600'],
        specs: { "Battery Life": "7 Days", "Water Resistance": "50m (Swimproof)", "Compatibility": "Android & iOS", "Sensors": "GPS, ECG, SpO2, EDA" },
      },
      {
        title: 'Garmin Forerunner 55 Smart Running Watch (Aqua Blue)',
        brand: 'Garmin',
        category: 'wearables',
        desc: 'Easy-to-use GPS running smartwatch that monitors heart rate, tracks pace, gives daily workout suggestions, and estimates VO2 max.',
        price: 1899000,
        origPrice: 2249000,
        stock: 10,
        images: ['https://images.unsplash.com/photo-1508685096489-7aacd43bd3b1?w=600'],
        specs: { "Display": "Transflective Sunlight-Visible", "Weight": "37g", "Battery Life": "Up to 2 weeks in smartwatch mode", "PacePro": "Enabled" },
      },
      {
        title: 'IronCore 10mm Quick-Release Lever Powerlifting Belt',
        brand: 'IronCore Gear',
        category: 'gear',
        desc: 'Heavy-duty 10mm top-grain cowhide leather weightlifting belt with zinc-alloy lever buckle designed for maximum intra-abdominal pressure during squats and deadlifts.',
        price: 299900,
        origPrice: 449900,
        stock: 25,
        images: ['https://images.unsplash.com/photo-1517838277536-f5f99be501cd?w=600'],
        specs: { "Thickness": "10mm", "Width": "4 inches standard", "Buckle": "Heavy Duty Zinc-Alloy Lever", "Certification": "IPF Spec Compatible" },
      },
      {
        title: 'FlexGrip Heavy-Duty Pull-Up & Loop Resistance Bands (Set of 5)',
        brand: 'FlexGrip',
        category: 'gear',
        desc: 'Stackable natural latex resistance loop bands spanning 15 lbs to 125 lbs resistance for pull-up assists, powerlifting banded squats, and full-body rehab.',
        price: 149900,
        origPrice: 219900,
        stock: 45,
        images: ['https://images.unsplash.com/photo-1598289431512-b97b0917affc?w=600'],
        specs: { "Resistance Levels": "Red (15-35lb), Black (25-65lb), Purple (35-85lb), Green (50-125lb)", "Material": "100% Natural Malaysian Latex", "Door Anchor": "Included" },
      },
    ];

    for (const p of PRODUCTS) {
      await query(
        `INSERT INTO marketplace_products (vendor_id, title, brand, category, description, price_paise, original_price_paise, stock_quantity, images, specs)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
        [vendor.id, p.title, p.brand, p.category, p.desc, p.price, p.origPrice, p.stock, p.images, JSON.stringify(p.specs)],
      );
    }
    console.log(`✔ Marketplace products (${PRODUCTS.length})`);
  }

  // ---- 6. FitPro On-Demand Trainers -----------------------------------------
  const trainerCount = await queryOne(`SELECT COUNT(*) AS n FROM trainers`);
  if (+trainerCount.n === 0) {
    const TRAINERS = [
      {
        name: 'Vikram Malhotra',
        photo: 'https://images.unsplash.com/photo-1567013127542-490d757e51fc?w=400',
        bio: '10+ years coaching powerlifters and physique athletes. Specializes in progressive overload, compound movement biomechanics, and injury prevention.',
        rating: 4.95,
        reviews: 48,
        certs: ['ACSM Certified Personal Trainer', 'CSCS Strength & Conditioning Specialist'],
        specs: ['Gym Training', 'Weightlifting'],
        modes: ['online', 'home', 'gym'],
        rate: 120000,
      },
      {
        name: 'Ananya Deshmukh',
        photo: 'https://images.unsplash.com/photo-1544367567-0f2fcb009e0b?w=400',
        bio: 'Combines Ashtanga Vinyasa yoga with musculoskeletal physiotherapy to relieve chronic back pain, restore joint mobility, and build core stamina.',
        rating: 4.98,
        reviews: 62,
        certs: ['RYT 500 Yoga Alliance Certified', 'Master of Physiotherapy (MPT Ortho)'],
        specs: ['Yoga', 'Personal Rehab'],
        modes: ['online', 'home', 'gym'],
        rate: 100000,
      },
      {
        name: 'Rohan Fernandez',
        photo: 'https://images.unsplash.com/photo-1583454110551-21f2fa2afe61?w=400',
        bio: 'National Kickboxing Federation Coach & BJJ practitioner. Focused on explosive striking, agility drills, footwork conditioning, and functional combat cardio.',
        rating: 4.92,
        reviews: 35,
        certs: ['National Kickboxing Federation Certified Coach', 'BJJ Purple Belt Instructor'],
        specs: ['MMA/Boxing', 'Judo/Karate'],
        modes: ['online', 'gym'],
        rate: 150000,
      },
      {
        name: 'Pooja Hegde',
        photo: 'https://images.unsplash.com/photo-1518611012118-696072aa579a?w=400',
        bio: 'High-energy certified Zumba and functional aerobics instructor. Crafting dance workouts combining Latin beats, Bollywood rhythm, and high-calorie burn.',
        rating: 4.89,
        reviews: 54,
        certs: ['Licensed Zumba Fitness Instructor (ZIN)', 'ACE Group Fitness Instructor'],
        specs: ['Dance/Zumba'],
        modes: ['online', 'home', 'gym'],
        rate: 90000,
      },
      {
        name: 'Karan Singhal',
        photo: 'https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=400',
        bio: 'Former state-level competitive swimmer. Coaches stroke biomechanics, freestyle efficiency, flip-turns, and competitive water conditioning.',
        rating: 4.94,
        reviews: 29,
        certs: ['FINA Level 2 Certified Swimming Coach', 'Red Cross Water Safety Instructor'],
        specs: ['Swimming', 'Gym Training'],
        modes: ['gym'],
        rate: 140000,
      },
    ];

    for (const t of TRAINERS) {
      await query(
        `INSERT INTO trainers (partner_id, name, photo_url, bio, rating, review_count, certifications, specializations, training_modes, hourly_rate_paise)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
        [partner.id, t.name, t.photo, t.bio, t.rating, t.reviews, t.certs, t.specs, t.modes, t.rate],
      );
    }
    console.log(`✔ FitPro trainers (${TRAINERS.length})`);
  }

  // ---- 7. HealthStop: Chemists & Clinics ------------------------------------
  const chemistCount = await queryOne(`SELECT COUNT(*) AS n FROM health_chemists`);
  if (+chemistCount.n === 0) {
    const CHEMISTS = [
      {
        name: 'Apollo Pharmacy — 24/7 Indiranagar',
        address: '100 Feet Rd, HAL 2nd Stage, Indiranagar, Bengaluru',
        city: 'Bengaluru',
        dist: 0.8,
        hours: '24x7 Open',
        delivery: true,
        deliveryTime: '25-35 mins delivery',
        phone: '+918025210001',
        lat: 12.973,
        lng: 77.640,
      },
      {
        name: 'MedPlus Pharmacy Koramangala',
        address: '80 Feet Rd, 4th Block, Koramangala, Bengaluru',
        city: 'Bengaluru',
        dist: 1.4,
        hours: '7:00 AM - 11:30 PM',
        delivery: true,
        deliveryTime: '30-45 mins delivery',
        phone: '+918025531234',
        lat: 12.934,
        lng: 77.625,
      },
      {
        name: 'Wellness Forever Chemist & Superstore',
        address: '27th Main Rd, Sector 1, HSR Layout, Bengaluru',
        city: 'Bengaluru',
        dist: 2.1,
        hours: '24x7 Open',
        delivery: true,
        deliveryTime: '20-30 mins delivery',
        phone: '+918041238999',
        lat: 12.912,
        lng: 77.648,
      },
      {
        name: 'Fortis HealthWorld Chemist',
        address: 'Bannerghatta Main Rd, BTM 2nd Stage, Bengaluru',
        city: 'Bengaluru',
        dist: 3.5,
        hours: '8:00 AM - 10:30 PM',
        delivery: false,
        deliveryTime: 'In-store pickup only',
        phone: '+918066214444',
        lat: 12.908,
        lng: 77.599,
      },
    ];

    for (const c of CHEMISTS) {
      await query(
        `INSERT INTO health_chemists (name, address, city, distance_km, operational_hours, delivery_available, delivery_time_est, phone, latitude, longitude)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
        [c.name, c.address, c.city, c.dist, c.hours, c.delivery, c.deliveryTime, c.phone, c.lat, c.lng],
      );
    }
    console.log(`✔ HealthStop chemists (${CHEMISTS.length})`);
  }

  const clinicCount = await queryOne(`SELECT COUNT(*) AS n FROM health_clinics`);
  if (+clinicCount.n === 0) {
    const CLINICS = [
      {
        name: 'FitLife Sports Medicine & Physiotherapy Clinic',
        address: '12th Main Rd, Indiranagar, Bengaluru',
        city: 'Bengaluru',
        dist: 1.1,
        doctors: [
          { name: 'Dr. Aarav Mehta', degree: 'MBBS, MD Sports Medicine', specialty: 'Sports Injury Specialist' },
          { name: 'Dr. Sneha Rao', degree: 'BPT, MPT Orthopedics', specialty: 'Senior Physiotherapist' },
        ],
        facilities: ['Sports Rehab Gym', 'Ultrasound & Cryo Therapy', 'Body Composition Analyzer (DEXA)', 'Dry Needling Lab'],
        timings: '08:00 AM - 01:00 PM, 04:00 PM - 08:30 PM',
        fee: 80000,
        phone: '+919886012345',
        lat: 12.971,
        lng: 77.642,
      },
      {
        name: 'Apex Ortho & Joint Care Medical Clinic',
        address: '5th Block, Koramangala, Bengaluru',
        city: 'Bengaluru',
        dist: 1.8,
        doctors: [
          { name: 'Dr. Rajesh Kulkarni', degree: 'MS Ortho, DNB, Fellow Arthroscopy (UK)', specialty: 'Orthopedic Surgeon & Joint Care' },
        ],
        facilities: ['Digital X-Ray', 'PRP Therapy Unit', 'Joint Mobility Lab', 'ECG'],
        timings: '09:30 AM - 01:30 PM, 05:00 PM - 09:00 PM',
        fee: 95000,
        phone: '+919845098765',
        lat: 12.935,
        lng: 77.623,
      },
      {
        name: 'CareHealth Wellness & Family Clinic',
        address: '14th Main Rd, Sector 4, HSR Layout, Bengaluru',
        city: 'Bengaluru',
        dist: 2.4,
        doctors: [
          { name: 'Dr. Kavita Shenoy', degree: 'MBBS, MD Internal Medicine', specialty: 'General Physician & Lifestyle Consultant' },
        ],
        facilities: ['Diagnostic Pathology Lab', 'ECG', 'Annual Health Checkups', 'Dietetics & Nutrition'],
        timings: '08:30 AM - 02:00 PM, 05:30 PM - 09:00 PM',
        fee: 60000,
        phone: '+919880155443',
        lat: 12.914,
        lng: 77.645,
      },
    ];

    for (const c of CLINICS) {
      await query(
        `INSERT INTO health_clinics (name, address, city, distance_km, doctors, facilities, slot_timings, consultation_fee_paise, phone, latitude, longitude)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
        [c.name, c.address, c.city, c.dist, JSON.stringify(c.doctors), c.facilities, c.timings, c.fee, c.phone, c.lat, c.lng],
      );
    }
    console.log(`✔ HealthStop clinics (${CLINICS.length})`);
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

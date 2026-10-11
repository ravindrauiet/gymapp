import { Router } from 'express';
import { query } from '../db/index.js';
import { ACTIVITY_TYPES, AMENITIES, VENUE_CATEGORIES, VIDEO_CATEGORIES, WEEKDAYS } from '../utils/constants.js';

const router = Router();

/** GET /meta — static lists both apps use to build pickers and filters. */
router.get('/', async (_req, res) => {
  const cities = await query(`SELECT DISTINCT city FROM venues WHERE status = 'live' AND city IS NOT NULL ORDER BY city`);
  res.json({
    venueCategories: VENUE_CATEGORIES,
    videoCategories: VIDEO_CATEGORIES,
    amenities: AMENITIES,
    activityTypes: ACTIVITY_TYPES,
    weekdays: WEEKDAYS,
    cities: cities.map((c) => c.city),
  });
});

export default router;

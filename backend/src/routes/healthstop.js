import { Router } from 'express';
import { query } from '../db/index.js';

const router = Router();

// Chemist Directory (Pharmacies)
router.get('/chemists', async (req, res) => {
  const { city } = req.query;
  const conditions = [];
  const params = [];

  if (city) {
    params.push(city);
    conditions.push(`city = $${params.length}`);
  }

  const whereClause = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  const chemists = await query(
    `SELECT * FROM health_chemists ${whereClause} ORDER BY distance_km ASC`,
    params,
  );
  res.json({ chemists });
});

// Clinic Directory (Medical Clinics)
router.get('/clinics', async (req, res) => {
  const { city } = req.query;
  const conditions = [];
  const params = [];

  if (city) {
    params.push(city);
    conditions.push(`city = $${params.length}`);
  }

  const whereClause = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
  const clinics = await query(
    `SELECT * FROM health_clinics ${whereClause} ORDER BY distance_km ASC`,
    params,
  );
  res.json({ clinics });
});

export default router;

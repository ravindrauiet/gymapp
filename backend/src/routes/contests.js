import { Router } from 'express';
import { z } from 'zod';
import { requireAuth } from '../middleware/auth.js';
import { validate } from '../utils/http.js';
import { uuidSchema } from '../utils/schemas.js';
import { eventDetail, joinEvent, listEvents } from './events.js';
import { SCORING, pointsBoard } from './points.js';

/**
 * Legacy contest endpoints (older app builds and the Home screen). Contests are now Events —
 * these delegate to routes/events.js and keep the original response shapes (plus the new event fields).
 */
export const contestsRouter = Router();
export const leaderboardRouter = Router();
contestsRouter.use(requireAuth('user'));
leaderboardRouter.use(requireAuth('user'));

/** GET /contests?status=active|upcoming|past */
contestsRouter.get('/', async (req, res) => {
  const { status } = validate(z.object({ status: z.enum(['active', 'upcoming', 'past']).default('active') }), req.query);
  const { events } = await listEvents(req.user.id, {
    scope: 'all',
    status: status === 'active' ? 'live' : status,
    limit: 50,
  });
  res.json({ contests: events });
});

/** GET /contests/:id?city= — contest details + leaderboard. */
contestsRouter.get('/:id', async (req, res) => {
  const { city } = validate(z.object({ city: z.string().trim().min(1).optional() }), req.query);
  const d = await eventDetail(req.params.id, req.user.id, { city });
  res.json({ contest: d.event, leaderboard: d.leaderboard, teams: d.teams, eligibility: d.eligibility });
});

contestsRouter.post('/:id/join', async (req, res) => {
  const { orgId } = validate(z.object({ orgId: uuidSchema.optional() }), req.body ?? {});
  await joinEvent(req.params.id, req.user.id, { orgId });
  res.status(201).json({ joined: true });
});

/**
 * GET /leaderboard?period=weekly|monthly&city=
 * Overall FITKEY points (same scoring as GET /points, which also returns badges).
 */
leaderboardRouter.get('/', async (req, res) => {
  const { period, city } = validate(
    z.object({ period: z.enum(['weekly', 'monthly']).default('weekly'), city: z.string().trim().min(1).optional() }),
    req.query,
  );
  const rows = await pointsBoard({ period: period === 'monthly' ? 'month' : 'week', city });
  res.json({
    period,
    city: city ?? null,
    entries: rows.slice(0, 100),
    me: rows.find((r) => r.userId === req.user.id) ?? null,
    scoring: SCORING,
  });
});

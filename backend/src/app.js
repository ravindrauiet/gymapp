import { fileURLToPath } from 'node:url';
import cors from 'cors';
import express from 'express';
import helmet from 'helmet';
import morgan from 'morgan';
import { config } from './config.js';
import { pool } from './db/index.js';
import { errorHandler, notFoundHandler } from './middleware/errors.js';
import adminRouter from './routes/admin.js';
import authRouter from './routes/auth.js';
import buddyRouter from './routes/buddy.js';
import { filesRouter, uploadsRouter } from './routes/files.js';
import checkinsRouter from './routes/checkins.js';
import { contestsRouter, leaderboardRouter } from './routes/contests.js';
import healthRouter from './routes/health.js';
import meRouter from './routes/me.js';
import metaRouter from './routes/meta.js';
import partnerRouter from './routes/partner.js';
import { plansRouter, subscriptionsRouter } from './routes/plans.js';
import venuesRouter from './routes/venues.js';
import videosRouter from './routes/videos.js';
import goalsRouter from './routes/goals.js';
import { marketplaceRouter, partnerVendorRouter } from './routes/marketplace.js';
import nutritionRouter from './routes/nutrition.js';
import { trainersRouter, partnerTrainerRouter } from './routes/trainers.js';
import healthstopRouter from './routes/healthstop.js';
import aiRouter from './routes/ai.js';

export function createApp() {
  const app = express();
  app.set('trust proxy', 1);
  app.use(
    helmet({
      contentSecurityPolicy: {
        directives: {
          'img-src': ["'self'", 'data:', 'https:'],
          'media-src': ["'self'", 'https:'],
          // Allow the admin panel over plain HTTP on a LAN IP during development; terminate TLS in front in prod.
          'upgrade-insecure-requests': null,
        },
      },
    }),
  );
  app.use(cors({ origin: config.corsOrigins.includes('*') ? true : config.corsOrigins }));
  app.use(express.json({ limit: '15mb' }));
  app.use(morgan(config.isProd ? 'combined' : 'dev'));

  app.get('/health', async (_req, res) => {
    await pool.query('SELECT 1');
    res.json({ status: 'ok' });
  });

  const api = express.Router();
  // Shared by both apps
  api.use('/auth', authRouter);
  api.use('/me', meRouter);
  api.use('/meta', metaRouter);
  api.use('/uploads', uploadsRouter);
  api.use('/files', filesRouter);
  // Member (User app)
  api.use('/plans', plansRouter);
  api.use('/subscriptions', subscriptionsRouter);
  api.use('/venues', venuesRouter);
  api.use('/checkins', checkinsRouter);
  api.use('/videos', videosRouter);
  api.use('/buddy', buddyRouter);
  api.use('/contests', contestsRouter);
  api.use('/leaderboard', leaderboardRouter);
  api.use('/health', healthRouter);
  api.use('/goals', goalsRouter);
  api.use('/marketplace', marketplaceRouter);
  api.use('/nutrition', nutritionRouter);
  api.use('/trainers', trainersRouter);
  api.use('/healthstop', healthstopRouter);
  api.use('/ai', aiRouter);
  // Venue owner & vendor/trainer (Partner app)
  api.use('/partner', partnerRouter);
  api.use('/partner/vendor', partnerVendorRouter);
  api.use('/partner/trainer', partnerTrainerRouter);
  // FITKEY team
  api.use('/admin', adminRouter);

  app.use('/api/v1', api);

  // FITKEY team web panel (venue verification, plans, videos, contests)
  const adminPanel = fileURLToPath(new URL('../public/admin', import.meta.url));
  app.use('/admin', express.static(adminPanel));
  app.get('/', (_req, res) => res.redirect('/admin/'));
  app.use(notFoundHandler);
  app.use(errorHandler);
  return app;
}

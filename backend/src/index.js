import { createApp } from './app.js';
import { config } from './config.js';
import { pool } from './db/index.js';

const app = createApp();
const server = app.listen(config.port, () => {
  console.log(`FITKEY API listening on http://localhost:${config.port}/api/v1`);
});

function shutdown() {
  server.close(() => pool.end().finally(() => process.exit(0)));
}
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);

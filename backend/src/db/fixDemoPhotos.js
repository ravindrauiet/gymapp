// One-off repair: replaces random picsum.photos placeholders on existing venues with real category photos.
// Only touches venues whose photos contain picsum URLs; partner-uploaded photos are left alone.
import { photosFor } from './demoPhotos.js';
import { pool, query } from './index.js';

try {
  const venues = await query(
    `SELECT id, name, categories FROM venues WHERE EXISTS (SELECT 1 FROM unnest(photos) p WHERE p LIKE '%picsum.photos%')`,
  );
  for (const [i, v] of venues.entries()) {
    await query(`UPDATE venues SET photos = $2, updated_at = now() WHERE id = $1`, [v.id, photosFor(v.categories, i)]);
    console.log(`✔ ${v.name}`);
  }
  console.log(`Updated ${venues.length} venue(s).`);
} catch (err) {
  console.error('✖ Failed:', err.message);
  process.exitCode = 1;
} finally {
  await pool.end();
}

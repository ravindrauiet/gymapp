import { Router } from 'express';
import multer from 'multer';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, notFound } from '../utils/http.js';

export const FILES_PATH = '/api/v1/files/';
const MAX_BYTES = 3 * 1024 * 1024;
// Members also upload short AI Arena proof clips (MP4) and Circle chat voice notes (audio).
const MAX_VIDEO_BYTES = 12 * 1024 * 1024;
const ALLOWED = new Set(['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/aac', 'audio/mpeg', 'audio/webm', 'audio/ogg']);

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_VIDEO_BYTES, files: 1 },
  fileFilter: (_req, file, cb) =>
    ALLOWED.has(file.mimetype) ? cb(null, true) : cb(badRequest('Only images (JPEG, PNG, WebP), MP4 clips or audio notes are allowed')),
});

export const uploadsRouter = Router();
export const filesRouter = Router();

/**
 * POST /uploads (multipart, field "file") → { id, url }.
 * `url` is a server-relative path; clients prefix it with the API origin.
 */
uploadsRouter.post('/', requireAuth('user', 'partner', 'admin'), (req, res, next) => {
  upload.single('file')(req, res, async (err) => {
    try {
      if (err?.code === 'LIMIT_FILE_SIZE') throw badRequest('File is too large (images 3 MB, clips 12 MB)');
      if (err) throw err;
      if (!req.file) throw badRequest('Attach an image in the "file" field');
      if (req.file.mimetype.startsWith('image/') && req.file.size > MAX_BYTES) throw badRequest('Image must be under 3 MB');
      const file = await queryOne(
        `INSERT INTO files (owner_id, mime, size_bytes, data) VALUES ($1, $2, $3, $4) RETURNING id`,
        [req.user.id, req.file.mimetype, req.file.size, req.file.buffer],
      );
      res.status(201).json({ id: file.id, url: `${FILES_PATH}${file.id}` });
    } catch (e) {
      next(e);
    }
  });
});

/** GET /files/:id — public, immutable image bytes. */
filesRouter.get('/:id', async (req, res) => {
  const rows = await query(`SELECT mime, data FROM files WHERE id = $1`, [req.params.id]);
  if (!rows[0]) throw notFound('File not found');
  res.set({
    'Content-Type': rows[0].mime,
    'Cache-Control': 'public, max-age=31536000, immutable',
    'Cross-Origin-Resource-Policy': 'cross-origin',
  });
  res.send(rows[0].data);
});

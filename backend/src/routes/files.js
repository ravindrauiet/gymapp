import { Router } from 'express';
import multer from 'multer';
import { query, queryOne } from '../db/index.js';
import { requireAuth } from '../middleware/auth.js';
import { badRequest, notFound } from '../utils/http.js';

export const FILES_PATH = '/api/v1/files/';
const MAX_BYTES = 3 * 1024 * 1024;
const ALLOWED = new Set(['image/jpeg', 'image/png', 'image/webp']);

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: MAX_BYTES, files: 1 },
  fileFilter: (_req, file, cb) =>
    ALLOWED.has(file.mimetype) ? cb(null, true) : cb(badRequest('Only JPEG, PNG or WebP images are allowed')),
});

export const uploadsRouter = Router();
export const filesRouter = Router();

/**
 * POST /uploads (multipart, field "file") → { id, url }.
 * `url` is a server-relative path; clients prefix it with the API origin.
 */
uploadsRouter.post('/', requireAuth('partner', 'admin'), (req, res, next) => {
  upload.single('file')(req, res, async (err) => {
    try {
      if (err?.code === 'LIMIT_FILE_SIZE') throw badRequest('Image must be under 3 MB');
      if (err) throw err;
      if (!req.file) throw badRequest('Attach an image in the "file" field');
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

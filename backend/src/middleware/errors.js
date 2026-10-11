import { HttpError } from '../utils/http.js';

export function notFoundHandler(req, res) {
  res.status(404).json({ error: `Route ${req.method} ${req.path} not found` });
}

// eslint-disable-next-line no-unused-vars
export function errorHandler(err, req, res, _next) {
  if (err instanceof HttpError) {
    return res.status(err.status).json({ error: err.message, details: err.details });
  }
  if (err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'Malformed JSON body' });
  }
  // Postgres: invalid uuid / invalid input syntax → 400 instead of 500
  if (err.code === '22P02') {
    return res.status(400).json({ error: 'Invalid identifier or value' });
  }
  if (err.code === '23505') {
    return res.status(409).json({ error: 'Already exists' });
  }
  console.error(err);
  res.status(500).json({ error: 'Something went wrong' });
}

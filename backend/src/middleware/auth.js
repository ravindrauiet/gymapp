import jwt from 'jsonwebtoken';
import { config } from '../config.js';
import { forbidden, unauthorized } from '../utils/http.js';

export function signAccessToken(user) {
  return jwt.sign({ sub: user.id, role: user.role }, config.jwtSecret, { expiresIn: '30d' });
}

/**
 * Requires a valid Bearer token. Pass roles to restrict access, e.g. requireAuth('partner').
 * Sets req.user = { id, role }.
 */
export function requireAuth(...roles) {
  return (req, _res, next) => {
    const header = req.headers.authorization ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : null;
    if (!token) return next(unauthorized('Missing access token'));

    try {
      const payload = jwt.verify(token, config.jwtSecret);
      req.user = { id: payload.sub, role: payload.role };
    } catch {
      return next(unauthorized('Invalid or expired token'));
    }

    if (roles.length && !roles.includes(req.user.role)) {
      return next(forbidden(`This endpoint is for ${roles.join('/')} accounts`));
    }
    next();
  };
}

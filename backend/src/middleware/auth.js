import jwt from 'jsonwebtoken';
import { config } from '../config.js';
import { queryOne } from '../db/index.js';
import { forbidden, unauthorized } from '../utils/http.js';
import { staffBlockedPath } from '../utils/partner_rules.js';

/**
 * extra.staffId → an "act-as" token: a FitKey employee listing on behalf of this partner (Assisted Listing, BRD §8).
 * Act-as tokens are short-lived and checked on every request (see requireAuth).
 */
export function signAccessToken(user, extra = {}) {
  const claims = { sub: user.id, role: user.role };
  if (extra.staffId) claims.staffId = extra.staffId;
  return jwt.sign(claims, config.jwtSecret, { expiresIn: extra.staffId ? '12h' : '30d' });
}

export const STAFF_ACCESS_ENDED = 'This partner is live — FitKey assisted access has ended';

/**
 * For act-as requests: the employee must still be FitKey staff, the path must not be a money / member-data path,
 * and the partner must have nothing live yet (access is removed at go-live). Sets req.staffName.
 */
async function checkStaffActing(req) {
  if (staffBlockedPath(req.method, req.originalUrl ?? req.url)) {
    throw forbidden('Not available while a FitKey employee is acting for this partner');
  }
  const row = await queryOne(
    `SELECT s.name, s.is_fitkey_staff,
            (EXISTS (SELECT 1 FROM venues WHERE owner_id = $2 AND status = 'live')
             OR EXISTS (SELECT 1 FROM trainers WHERE partner_id = $2 AND listing_status = 'live')
             OR EXISTS (SELECT 1 FROM health_clinics WHERE owner_id = $2 AND listing_status = 'live')
             OR EXISTS (SELECT 1 FROM health_chemists WHERE owner_id = $2 AND listing_status = 'live')
             OR EXISTS (SELECT 1 FROM marketplace_vendors WHERE partner_id = $2 AND listing_status = 'live')) AS has_live
       FROM users s WHERE s.id = $1`,
    [req.staffId, req.user.id],
  );
  if (!row?.isFitkeyStaff) throw unauthorized('Assisted access has ended — sign in again');
  if (row.hasLive) throw forbidden(STAFF_ACCESS_ENDED);
  req.staffName = row.name ?? 'FitKey team';
}

/**
 * Requires a valid Bearer token. Pass roles to restrict access, e.g. requireAuth('partner').
 * Sets req.user = { id, role }; for act-as tokens also req.staffId / req.staffName (and applies the staff guard).
 */
export function requireAuth(...roles) {
  return (req, _res, next) => {
    const header = req.headers.authorization ?? '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : null;
    if (!token) return next(unauthorized('Missing access token'));

    let payload;
    try {
      payload = jwt.verify(token, config.jwtSecret);
      req.user = { id: payload.sub, role: payload.role };
    } catch {
      return next(unauthorized('Invalid or expired token'));
    }

    if (roles.length && !roles.includes(req.user.role)) {
      return next(forbidden(`This endpoint is for ${roles.join('/')} accounts`));
    }
    if (!payload.staffId) {
      req.staffId = null;
      return next();
    }
    req.staffId = payload.staffId;
    if (req._staffChecked) return next(); // nested routers: checked once per request
    checkStaffActing(req).then(
      () => {
        req._staffChecked = true;
        next();
      },
      next,
    );
  };
}

/** Route-level guard: 403 for act-as (staff) requests. Use on money / member-data endpoints. */
export function forbidStaffActing(req, _res, next) {
  if (req.staffId) return next(forbidden('Not available while a FitKey employee is acting for this partner'));
  next();
}

/** Route-level guard: only a FitKey employee using their own token (not acting for a partner). */
export async function requireStaff(req, _res, next) {
  try {
    if (req.staffId) throw forbidden('Switch back to your own FitKey account first');
    const u = await queryOne(`SELECT is_fitkey_staff FROM users WHERE id = $1`, [req.user.id]);
    if (!u?.isFitkeyStaff) throw forbidden('Only FitKey staff can list on behalf of partners');
    next();
  } catch (err) {
    next(err);
  }
}

import { query } from '../db/index.js';

/**
 * Creates an in-app notification. Never throws: a failed notification must not fail the action that caused it.
 * @param {string} userId recipient
 * @param {{type: string, title: string, body?: string, data?: object}} n
 */
export async function notify(userId, { type, title, body = null, data = {} }) {
  try {
    await query(`INSERT INTO notifications (user_id, type, title, body, data) VALUES ($1, $2, $3, $4, $5)`, [
      userId,
      type,
      title.slice(0, 160),
      body?.slice(0, 500) ?? null,
      data,
    ]);
  } catch (err) {
    console.error('notify failed:', err.message);
  }
}

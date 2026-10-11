import { z } from 'zod';

/** Accepts "9876543210", "+91 98765 43210", "+919876543210"; normalises to E.164 (defaults to +91). */
export const phoneSchema = z
  .string()
  .transform((s) => s.replace(/[\s-]/g, ''))
  .refine((s) => /^(\+\d{10,15}|\d{10})$/.test(s), 'Enter a valid phone number')
  .transform((s) => (s.startsWith('+') ? s : `+91${s}`));

export const uuidSchema = z.string().uuid();
export const dateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'Use YYYY-MM-DD');
export const timeSchema = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d(:[0-5]\d)?$/, 'Use HH:MM');

export const pagination = {
  page: z.coerce.number().int().min(1).default(1),
  limit: z.coerce.number().int().min(1).max(50).default(20),
};

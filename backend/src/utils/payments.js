import { HttpError } from './http.js';

/**
 * 426 (Upgrade Required) for the old "buy instantly" endpoints when real payments are on: the app must pay through
 * POST /payments/orders → Razorpay checkout → POST /payments/verify (routes/payments.js).
 */
export const paymentRequired = (purpose) =>
  new HttpError(426, 'Please update FITKEY to pay securely with Razorpay.', { code: 'PAYMENT_REQUIRED', purpose });

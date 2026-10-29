/**
 * Sends a one-time code to a work / college email address.
 * No email provider is configured yet: the code is printed to the server log. Plug a provider
 * (SES, SendGrid, Resend…) in here — callers only depend on this function.
 * @param {string} email
 * @param {string} code
 * @param {{orgName?: string}} [opts]
 */
export async function sendEmailOtp(email, code, { orgName } = {}) {
  console.log(`[email] OTP for ${email}${orgName ? ` (${orgName})` : ''}: ${code}`);
}

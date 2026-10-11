/**
 * Sends the login OTP. Phase 1 has no SMS provider wired up yet, so this logs to the console.
 * Plug in MSG91 / Twilio / Gupshup here before launch.
 */
export async function sendOtpSms(phone, code) {
  console.log(`[sms] OTP for ${phone}: ${code}`);
}

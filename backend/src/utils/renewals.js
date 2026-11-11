/**
 * Daily money jobs (contract §F):
 *  - Renewal alerts: the partner is notified 7 days and 1 day before a member's renewal — manual members
 *    (partner_members.renewal_on) and FitKey direct memberships (ends_on = renew-by date) — once each, deduped via
 *    partner_member_alerts. Manual members with remind_member get an SMS / WhatsApp (sendSms); direct members get
 *    an in-app reminder.
 *  - Booking requests still undecided at their slot start are rejected and refunded (routes/bookings.js).
 * startMoneyJobs() is called from src/index.js; it never runs under `node --test` or NODE_ENV=test.
 */
import { config } from '../config.js';
import { query, queryOne } from '../db/index.js';
import { notify } from './notify.js';
import { sendSms } from './sms.js';

const fmtDate = (d) => new Date(`${d}T00:00:00Z`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', timeZone: 'UTC' });

/** Sends today's 7-day and 1-day renewal alerts. Idempotent (safe to run many times a day). */
export async function runRenewalAlerts() {
  const t = await queryOne(`SELECT to_char(now() AT TIME ZONE $1, 'YYYY-MM-DD') AS today`, [config.tz]);
  let sent = 0;
  for (const [kind, days] of [['7d', 7], ['1d', 1]]) {
    // Manual members: claim the alert row first (ON CONFLICT DO NOTHING), then notify only the claimed ones.
    const manual = await query(
      `WITH due AS (
         SELECT m.id, m.name, m.phone, m.plan_label, m.renewal_on, m.remind_member, v.id AS venue_id, v.name AS venue_name, v.owner_id
         FROM partner_members m JOIN venues v ON v.id = m.venue_id
         WHERE m.archived_at IS NULL AND m.renewal_on = $1::date + $2::int
       ), claimed AS (
         INSERT INTO partner_member_alerts (member_key, kind, renewal_on)
         SELECT 'pm:' || id, $3, renewal_on FROM due ON CONFLICT DO NOTHING RETURNING member_key
       )
       SELECT due.*, to_char(due.renewal_on, 'YYYY-MM-DD') AS renewal_ymd FROM due JOIN claimed ON claimed.member_key = 'pm:' || due.id`,
      [t.today, days, kind],
    );
    for (const m of manual) {
      const when = days === 1 ? 'tomorrow' : `in 7 days (${fmtDate(m.renewalYmd)})`;
      await notify(m.ownerId, {
        type: 'member_renewal',
        title: `Renewal ${days === 1 ? 'tomorrow' : 'in 7 days'}: ${m.name}`,
        body: `${m.name}'s ${m.planLabel} at ${m.venueName} is due for renewal ${when}.`,
        data: { venueId: m.venueId, memberKey: `pm:${m.id}`, renewalOn: m.renewalYmd },
      });
      if (m.remindMember && m.phone) {
        await sendSms(m.phone, `Hi ${m.name}, your ${m.planLabel} at ${m.venueName} is due for renewal ${when}. See you at the centre! – FitKey`)
          .catch((e) => console.error('renewal sms failed:', e.message));
      }
      sent += 1;
    }

    // FitKey direct memberships ending on the target day that the member hasn't renewed yet.
    const direct = await query(
      `WITH due AS (
         SELECT d.id, d.user_id, d.plan_name, d.ends_on, u.name AS member_name, v.id AS venue_id, v.name AS venue_name, v.owner_id
         FROM direct_memberships d JOIN venues v ON v.id = d.venue_id JOIN users u ON u.id = d.user_id
         WHERE d.status = 'active' AND d.ends_on = $1::date + $2::int AND d.duration NOT IN ('hourly', 'day')
           AND NOT EXISTS (SELECT 1 FROM direct_memberships n WHERE n.user_id = d.user_id AND n.venue_id = d.venue_id
                             AND n.status = 'active' AND n.starts_on > d.starts_on)
       ), claimed AS (
         INSERT INTO partner_member_alerts (member_key, kind, renewal_on)
         SELECT 'dm:' || id, $3, ends_on FROM due ON CONFLICT DO NOTHING RETURNING member_key
       )
       SELECT due.*, to_char(due.ends_on, 'YYYY-MM-DD') AS ends_ymd FROM due JOIN claimed ON claimed.member_key = 'dm:' || due.id`,
      [t.today, days, kind],
    );
    for (const d of direct) {
      const when = days === 1 ? 'tomorrow' : `on ${fmtDate(d.endsYmd)}`;
      await notify(d.ownerId, {
        type: 'member_renewal',
        title: `Renewal ${days === 1 ? 'tomorrow' : 'in 7 days'}: ${d.memberName}`,
        body: `${d.memberName}'s ${d.planName} (bought on FitKey) at ${d.venueName} ends ${when}.`,
        data: { venueId: d.venueId, memberKey: `dm:${d.id}`, renewalOn: d.endsYmd },
      });
      await notify(d.userId, {
        type: 'membership_renewal',
        title: `${d.planName} at ${d.venueName} ends ${days === 1 ? 'tomorrow' : 'soon'}`,
        body: `Your membership ends ${when}. Renew in the FitKey app to keep visiting.`,
        data: { venueId: d.venueId, membershipId: d.id },
      });
      sent += 1;
    }
  }
  return sent;
}

let started = false;

/** Schedules the daily jobs (renewal alerts every 6 h — deduped, so effectively daily; request expiry every 15 min). */
export function startMoneyJobs() {
  if (started || process.env.NODE_ENV === 'test' || process.env.NODE_TEST_CONTEXT) return;
  started = true;
  const safe = (name, fn) => async () => {
    try {
      await fn();
    } catch (e) {
      console.error(`${name} job failed:`, e.message);
    }
  };
  const renewals = safe('renewal alerts', runRenewalAlerts);
  const expire = safe('booking request expiry', async () => {
    const { expireStaleRequests } = await import('../routes/bookings.js');
    await expireStaleRequests();
  });
  setTimeout(renewals, 60_000).unref();
  setInterval(renewals, 6 * 60 * 60 * 1000).unref();
  setInterval(expire, 15 * 60 * 1000).unref();
}

-- Partner BRD Run / Sell / Earn (backend-money). Additive and idempotent: runs on every server start.
-- Contract: docs/partner_brd_contract.md §F, §G, "Changes by backend-money".

-- Which partner_payouts row settled each earning (a payout run only picks up rows not yet settled).
ALTER TABLE visit_payouts ADD COLUMN IF NOT EXISTS payout_id UUID REFERENCES partner_payouts(id) ON DELETE SET NULL;
ALTER TABLE direct_memberships ADD COLUMN IF NOT EXISTS payout_id UUID REFERENCES partner_payouts(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS visit_payouts_unsettled_idx ON visit_payouts (visit_date) WHERE payout_id IS NULL;
CREATE INDEX IF NOT EXISTS visit_payouts_payout_idx ON visit_payouts (payout_id) WHERE payout_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS direct_memberships_payout_idx ON direct_memberships (payout_id) WHERE payout_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS partner_payouts_owner_idx ON partner_payouts (owner_id, period_start DESC);

-- Member-QR check-ins scanned by the partner record who scanned (method stays 'qr').
ALTER TABLE checkins ADD COLUMN IF NOT EXISTS scanned_by UUID REFERENCES users(id) ON DELETE SET NULL;

-- Booking requests: a rejected booking must not block the member from booking that centre again the same day.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'slot_bookings_one_per_day' AND indexdef LIKE '%rejected%') THEN
    DROP INDEX IF EXISTS slot_bookings_one_per_day;
    CREATE UNIQUE INDEX slot_bookings_one_per_day ON slot_bookings (user_id, venue_id, slot_date)
      WHERE status NOT IN ('cancelled', 'rejected');
  END IF;
END $$;
CREATE INDEX IF NOT EXISTS slot_bookings_requested_idx ON slot_bookings (venue_id, slot_date) WHERE status = 'requested';

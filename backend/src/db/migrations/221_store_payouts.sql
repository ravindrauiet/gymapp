-- Store-seller payouts (Partner BRD §10.4 "Sales, commission, payouts"). Idempotent and additive.
-- FitKey collects the money for store orders, so delivered order items are paid out to the seller (minus that year's
-- commission) in the weekly payout run; payout_id stops an item from being paid twice.
-- Trainers, clinics and chemists collect their money directly from members, so they have no FitKey payouts.
ALTER TABLE marketplace_order_items ADD COLUMN IF NOT EXISTS payout_id UUID REFERENCES partner_payouts(id) ON DELETE SET NULL;
ALTER TABLE marketplace_order_items ADD COLUMN IF NOT EXISTS commission_pct NUMERIC(5, 2);
ALTER TABLE marketplace_order_items ADD COLUMN IF NOT EXISTS commission_paise INT;
CREATE INDEX IF NOT EXISTS marketplace_order_items_unpaid_idx ON marketplace_order_items (vendor_id) WHERE payout_id IS NULL;

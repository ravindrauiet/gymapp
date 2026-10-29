-- Partner app insights: ratings dashboard, partner events, partner notifications.
-- Idempotent and additive (indexes only): runs on every server start.

-- Partner events are looked up by host venue (GET /events/partner/events).
CREATE INDEX IF NOT EXISTS contests_venue_idx ON contests (venue_id) WHERE venue_id IS NOT NULL;

-- A partner's trainer profile is looked up by its owner (ratings dashboard, booking notifications).
CREATE INDEX IF NOT EXISTS trainers_partner_idx ON trainers (partner_id) WHERE partner_id IS NOT NULL;

-- Recent-ratings feed for owners, newest first, paged by updated_at.
CREATE INDEX IF NOT EXISTS venue_ratings_venue_recent_idx ON venue_ratings (venue_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS trainer_ratings_trainer_recent_idx ON trainer_ratings (trainer_id, updated_at DESC);

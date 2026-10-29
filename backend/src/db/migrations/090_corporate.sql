-- Corporate Dashboard (BRD §10): self-serve tools for company / college HR.
-- Idempotent and additive only — runs on every server start.
--
-- PRIVACY: nothing here (and nothing in routes/corporate.js) reads weight_logs, meal_logs, user_goals or step_logs.
-- HR sees usage (passes, check-ins) and participation (events) only.

-- HR admins of an org. They sign in with the normal member OTP (role 'user'); this table grants dashboard access.
CREATE TABLE IF NOT EXISTS corporate_admins (
  org_id      UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role        VARCHAR(8) NOT NULL DEFAULT 'admin' CHECK (role IN ('owner', 'admin', 'viewer')),
  added_by    UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (org_id, user_id)
);
CREATE INDEX IF NOT EXISTS corporate_admins_user_idx ON corporate_admins (user_id);

-- Bulk pass purchases. PAYMENTS_MODE=mock: no money moves; payment_mode records that honestly.
CREATE TABLE IF NOT EXISTS corporate_orders (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id            UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
  plan_id           UUID NOT NULL REFERENCES plans(id),
  quantity          INT NOT NULL CHECK (quantity > 0),
  unit_price_paise  INT NOT NULL CHECK (unit_price_paise >= 0),
  amount_paise      INT NOT NULL CHECK (amount_paise >= 0),
  payment_mode      VARCHAR(12) NOT NULL DEFAULT 'mock',
  status            VARCHAR(12) NOT NULL DEFAULT 'mock_paid'
                    CHECK (status IN ('pending', 'mock_paid', 'paid', 'cancelled')),
  payment_ref       VARCHAR(120),
  created_by        UUID REFERENCES users(id) ON DELETE SET NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS corporate_orders_org_idx ON corporate_orders (org_id, created_at DESC);

CREATE TABLE IF NOT EXISTS corporate_invoices (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id          UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
  order_id        UUID NOT NULL UNIQUE REFERENCES corporate_orders(id) ON DELETE CASCADE,
  number          VARCHAR(32) NOT NULL UNIQUE,
  amount_paise    INT NOT NULL CHECK (amount_paise >= 0),
  status          VARCHAR(12) NOT NULL DEFAULT 'mock' CHECK (status IN ('mock', 'due', 'paid', 'void')),
  note            VARCHAR(300),
  issued_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  paid_at         TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS corporate_invoices_org_idx ON corporate_invoices (org_id, issued_at DESC);

-- Invitations sent by HR (single or CSV). No email provider: the token link is shown to HR to share.
CREATE TABLE IF NOT EXISTS corporate_invites (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
  email            VARCHAR(255) NOT NULL,
  name             VARCHAR(120),
  department       VARCHAR(80),
  token            VARCHAR(64) NOT NULL UNIQUE,
  status           VARCHAR(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'revoked')),
  invited_by       UUID REFERENCES users(id) ON DELETE SET NULL,
  accepted_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
  last_sent_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  accepted_at      TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS corporate_invites_org_idx ON corporate_invites (org_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS corporate_invites_open_email_uidx
  ON corporate_invites (org_id, lower(email)) WHERE status = 'pending';

-- A pass (seat from a corporate order) given to one employee. 'pending' = invited employee not verified yet;
-- the pass becomes a real `subscriptions` row as soon as they verify (see trigger below).
CREATE TABLE IF NOT EXISTS corporate_pass_assignments (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id           UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
  plan_id          UUID NOT NULL REFERENCES plans(id),
  user_id          UUID REFERENCES users(id) ON DELETE SET NULL,
  email            VARCHAR(255),
  status           VARCHAR(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'revoked')),
  subscription_id  UUID REFERENCES subscriptions(id) ON DELETE SET NULL,
  assigned_by      UUID REFERENCES users(id) ON DELETE SET NULL,
  assigned_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  activated_at     TIMESTAMPTZ,
  revoked_at       TIMESTAMPTZ,
  CHECK (user_id IS NOT NULL OR email IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS corporate_pass_org_idx ON corporate_pass_assignments (org_id, status);
CREATE INDEX IF NOT EXISTS corporate_pass_user_idx ON corporate_pass_assignments (user_id);
CREATE INDEX IF NOT EXISTS corporate_pass_email_idx ON corporate_pass_assignments (org_id, lower(email));

-- Inter-org battle invitations: the host org invites another org; accepting adds it to contest_orgs.
CREATE TABLE IF NOT EXISTS corporate_battle_invites (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  contest_id    UUID NOT NULL REFERENCES contests(id) ON DELETE CASCADE,
  from_org_id   UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
  to_org_id     UUID NOT NULL REFERENCES orgs(id) ON DELETE CASCADE,
  status        VARCHAR(10) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled')),
  message       VARCHAR(300),
  created_by    UUID REFERENCES users(id) ON DELETE SET NULL,
  responded_by  UUID REFERENCES users(id) ON DELETE SET NULL,
  responded_at  TIMESTAMPTZ,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (from_org_id <> to_org_id)
);
CREATE INDEX IF NOT EXISTS corporate_battle_to_idx ON corporate_battle_invites (to_org_id, status);
CREATE INDEX IF NOT EXISTS corporate_battle_from_idx ON corporate_battle_invites (from_org_id, status);
CREATE UNIQUE INDEX IF NOT EXISTS corporate_battle_open_uidx
  ON corporate_battle_invites (contest_id, to_org_id) WHERE status IN ('pending', 'accepted');

-- When someone becomes a verified member of an org (work-email OTP in the member app, an HR invite link, …):
--  * matching pending HR invites are marked accepted and their department is copied onto the membership;
--  * pending corporate passes for that email / user become real subscriptions (stacked after any current one).
CREATE OR REPLACE FUNCTION corporate_on_membership_verified() RETURNS trigger AS $$
DECLARE
  a        RECORD;
  plan_row RECORD;
  start_at TIMESTAMPTZ;
  sub_id   UUID;
  inv_dept VARCHAR(80);
BEGIN
  IF NEW.status <> 'verified' THEN
    RETURN NEW;
  END IF;

  IF NEW.work_email IS NOT NULL THEN
    SELECT department INTO inv_dept FROM corporate_invites
     WHERE org_id = NEW.org_id AND lower(email) = lower(NEW.work_email) AND department IS NOT NULL
     ORDER BY created_at DESC LIMIT 1;
    IF NEW.department IS NULL AND inv_dept IS NOT NULL THEN
      NEW.department := inv_dept;
    END IF;
    UPDATE corporate_invites
       SET status = 'accepted', accepted_user_id = NEW.user_id, accepted_at = now()
     WHERE org_id = NEW.org_id AND lower(email) = lower(NEW.work_email) AND status = 'pending';
  END IF;

  FOR a IN
    SELECT id, plan_id FROM corporate_pass_assignments
     WHERE org_id = NEW.org_id AND status = 'pending'
       AND (user_id = NEW.user_id OR (NEW.work_email IS NOT NULL AND lower(email) = lower(NEW.work_email)))
     ORDER BY assigned_at
     FOR UPDATE
  LOOP
    SELECT id, duration_days INTO plan_row FROM plans WHERE id = a.plan_id;
    SELECT GREATEST(now(), COALESCE(MAX(ends_at), now())) INTO start_at FROM subscriptions
     WHERE user_id = NEW.user_id AND plan_id = a.plan_id AND status = 'active' AND ends_at > now();
    INSERT INTO subscriptions (user_id, plan_id, status, starts_at, ends_at, amount_paise, payment_ref)
    VALUES (NEW.user_id, a.plan_id, 'active', start_at, start_at + make_interval(days => plan_row.duration_days), 0,
            'CORP-' || a.id::text)
    RETURNING id INTO sub_id;
    UPDATE corporate_pass_assignments
       SET status = 'active', user_id = NEW.user_id, subscription_id = sub_id, activated_at = now()
     WHERE id = a.id;
    INSERT INTO notifications (user_id, type, title, body, data)
    VALUES (NEW.user_id, 'corporate_pass', 'Your company pass is active',
            'Your employer has given you a FITKEY pass. Check in at any covered centre.',
            jsonb_build_object('orgId', NEW.org_id, 'subscriptionId', sub_id));
  END LOOP;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER corporate_membership_verified
  BEFORE INSERT OR UPDATE OF status, work_email ON org_memberships
  FOR EACH ROW EXECUTE FUNCTION corporate_on_membership_verified();

-- Company profile details shown on invoices / settings (orgs itself stays the shared minimal table).
CREATE TABLE IF NOT EXISTS corporate_org_profiles (
  org_id          UUID PRIMARY KEY REFERENCES orgs(id) ON DELETE CASCADE,
  legal_name      VARCHAR(160),
  industry        VARCHAR(80),
  city            VARCHAR(80),
  address         VARCHAR(400),
  billing_email   VARCHAR(255),
  gstin           VARCHAR(20),
  employee_count  INT CHECK (employee_count IS NULL OR employee_count >= 0),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

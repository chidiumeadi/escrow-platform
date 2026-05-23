-- ============================================================
-- Social Commerce Escrow Platform — Database Schema
-- PostgreSQL 15+
-- ============================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- ENUMS
-- ============================================================

CREATE TYPE user_role         AS ENUM ('buyer', 'seller', 'admin');
CREATE TYPE kyc_status        AS ENUM ('pending', 'verified', 'rejected');
CREATE TYPE listing_status    AS ENUM ('draft', 'active', 'sold', 'paused');
CREATE TYPE transaction_state AS ENUM (
  'initiated', 'funded', 'inspecting',
  'released', 'disputed', 'refunded', 'cancelled'
);
CREATE TYPE escrow_status     AS ENUM ('empty', 'funded', 'released', 'refunded');
CREATE TYPE payment_direction AS ENUM ('inflow', 'outflow');
CREATE TYPE payment_status    AS ENUM ('pending', 'processing', 'completed', 'failed', 'reversed');
CREATE TYPE wallet_status     AS ENUM ('active', 'suspended');
CREATE TYPE dispute_reason    AS ENUM (
  'item_not_received', 'not_as_described',
  'damaged', 'fraud', 'other'
);
CREATE TYPE dispute_status    AS ENUM (
  'open', 'under_review', 'escalated', 'resolved', 'closed'
);
CREATE TYPE dispute_verdict   AS ENUM (
  'buyer_wins', 'seller_wins', 'split',
  'partial_refund'
);
CREATE TYPE tx_event_type     AS ENUM (
  'created', 'funded', 'inspection_started',
  'disputed', 'released', 'refunded', 'cancelled'
);


-- ============================================================
-- USERS
-- ============================================================

CREATE TABLE users (
  id                  UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  email               TEXT          NOT NULL UNIQUE,
  phone               TEXT          UNIQUE,
  full_name           TEXT          NOT NULL,
  avatar_url          TEXT,
  role                user_role     NOT NULL DEFAULT 'buyer',
  kyc_status          kyc_status    NOT NULL DEFAULT 'pending',
  trust_score         NUMERIC(4,2)  NOT NULL DEFAULT 0.00
                        CHECK (trust_score BETWEEN 0 AND 5),
  password_hash       TEXT          NOT NULL,
  email_verified_at   TIMESTAMPTZ,
  created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_email      ON users (email);
CREATE INDEX idx_users_kyc_status ON users (kyc_status);


-- ============================================================
-- LISTINGS
-- ============================================================

CREATE TABLE listings (
  id          UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  seller_id   UUID           NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  title       TEXT           NOT NULL,
  description TEXT,
  price       NUMERIC(18,2)  NOT NULL CHECK (price > 0),
  currency    CHAR(3)        NOT NULL DEFAULT 'NGN',
  category    TEXT           NOT NULL,
  status      listing_status NOT NULL DEFAULT 'draft',
  images      JSONB          NOT NULL DEFAULT '[]',
  tags        JSONB          NOT NULL DEFAULT '[]',
  view_count  INT            NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_listings_seller_id ON listings (seller_id);
CREATE INDEX idx_listings_status    ON listings (status);
CREATE INDEX idx_listings_category  ON listings (category);
CREATE INDEX idx_listings_tags      ON listings USING GIN (tags);


-- ============================================================
-- TRANSACTIONS
-- ============================================================

CREATE TABLE transactions (
  id                   UUID               PRIMARY KEY DEFAULT gen_random_uuid(),
  listing_id           UUID               NOT NULL REFERENCES listings (id) ON DELETE RESTRICT,
  buyer_id             UUID               NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  seller_id            UUID               NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  amount               NUMERIC(18,2)      NOT NULL CHECK (amount > 0),
  currency             CHAR(3)            NOT NULL DEFAULT 'NGN',
  state                transaction_state  NOT NULL DEFAULT 'initiated',
  inspection_days      INT                NOT NULL DEFAULT 3 CHECK (inspection_days BETWEEN 1 AND 30),
  inspection_deadline  TIMESTAMPTZ,
  funded_at            TIMESTAMPTZ,
  released_at          TIMESTAMPTZ,
  created_at           TIMESTAMPTZ        NOT NULL DEFAULT NOW(),
  updated_at           TIMESTAMPTZ        NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_buyer_not_seller CHECK (buyer_id <> seller_id)
);

CREATE INDEX idx_transactions_listing_id ON transactions (listing_id);
CREATE INDEX idx_transactions_buyer_id   ON transactions (buyer_id);
CREATE INDEX idx_transactions_seller_id  ON transactions (seller_id);
CREATE INDEX idx_transactions_state      ON transactions (state);
CREATE INDEX idx_transactions_deadline   ON transactions (inspection_deadline)
  WHERE state = 'inspecting';


-- ============================================================
-- ESCROW ACCOUNTS
-- ============================================================

CREATE TABLE escrow_accounts (
  id               UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id   UUID          NOT NULL UNIQUE REFERENCES transactions (id) ON DELETE RESTRICT,
  held_amount      NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (held_amount >= 0),
  platform_fee     NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (platform_fee >= 0),
  seller_payout    NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (seller_payout >= 0),
  currency         CHAR(3)       NOT NULL,
  status           escrow_status NOT NULL DEFAULT 'empty',
  ledger_ref       TEXT          UNIQUE,
  locked_at        TIMESTAMPTZ,
  released_at      TIMESTAMPTZ,

  CONSTRAINT chk_escrow_amounts CHECK (
    held_amount = platform_fee + seller_payout OR held_amount = 0
  )
);

CREATE INDEX idx_escrow_transaction_id ON escrow_accounts (transaction_id);
CREATE INDEX idx_escrow_status         ON escrow_accounts (status);


-- ============================================================
-- TRANSACTION EVENTS  (append-only audit log)
-- ============================================================

CREATE TABLE transaction_events (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id  UUID          NOT NULL REFERENCES transactions (id) ON DELETE RESTRICT,
  actor_id        UUID          REFERENCES users (id) ON DELETE SET NULL,
  event_type      tx_event_type NOT NULL,
  metadata        JSONB         NOT NULL DEFAULT '{}',
  ip_address      INET,
  occurred_at     TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_tx_events_transaction_id ON transaction_events (transaction_id);
CREATE INDEX idx_tx_events_actor_id       ON transaction_events (actor_id);
CREATE INDEX idx_tx_events_occurred_at    ON transaction_events (occurred_at);

-- Prevent deletes and updates on this table
CREATE RULE no_update_tx_events AS ON UPDATE TO transaction_events DO INSTEAD NOTHING;
CREATE RULE no_delete_tx_events AS ON DELETE TO transaction_events DO INSTEAD NOTHING;


-- ============================================================
-- PAYMENT GATEWAYS
-- ============================================================

CREATE TABLE payment_gateways (
  id                    UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name                  TEXT        NOT NULL UNIQUE,
  provider              TEXT        NOT NULL,
  is_active             BOOLEAN     NOT NULL DEFAULT TRUE,
  config                JSONB       NOT NULL DEFAULT '{}',
  supported_currencies  JSONB       NOT NULL DEFAULT '[]',
  created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);


-- ============================================================
-- WALLET ACCOUNTS
-- ============================================================

CREATE TABLE wallet_accounts (
  id              UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         UUID          NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  currency        CHAR(3)       NOT NULL DEFAULT 'NGN',
  balance         NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (balance >= 0),
  locked_balance  NUMERIC(18,2) NOT NULL DEFAULT 0 CHECK (locked_balance >= 0),
  status          wallet_status NOT NULL DEFAULT 'active',
  created_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

  UNIQUE (user_id, currency)
);

CREATE INDEX idx_wallets_user_id ON wallet_accounts (user_id);


-- ============================================================
-- PAYMENTS
-- ============================================================

CREATE TABLE payments (
  id                 UUID              PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id     UUID              NOT NULL REFERENCES transactions (id) ON DELETE RESTRICT,
  wallet_account_id  UUID              REFERENCES wallet_accounts (id) ON DELETE SET NULL,
  gateway_id         UUID              REFERENCES payment_gateways (id) ON DELETE SET NULL,
  amount             NUMERIC(18,2)     NOT NULL CHECK (amount > 0),
  currency           CHAR(3)           NOT NULL,
  direction          payment_direction NOT NULL,
  status             payment_status    NOT NULL DEFAULT 'pending',
  gateway_ref        TEXT              UNIQUE,
  gateway_status     TEXT,
  gateway_response   JSONB             NOT NULL DEFAULT '{}',
  processed_at       TIMESTAMPTZ,
  created_at         TIMESTAMPTZ       NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_payments_transaction_id ON payments (transaction_id);
CREATE INDEX idx_payments_wallet_id      ON payments (wallet_account_id);
CREATE INDEX idx_payments_gateway_ref    ON payments (gateway_ref);
CREATE INDEX idx_payments_status         ON payments (status);


-- ============================================================
-- DISPUTES
-- ============================================================

CREATE TABLE disputes (
  id                UUID           PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id    UUID           NOT NULL UNIQUE REFERENCES transactions (id) ON DELETE RESTRICT,
  raised_by         UUID           NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  reason            dispute_reason NOT NULL,
  status            dispute_status NOT NULL DEFAULT 'open',
  description       TEXT           NOT NULL,
  evidence_urls     JSONB          NOT NULL DEFAULT '[]',
  assigned_agent_id UUID           REFERENCES users (id) ON DELETE SET NULL,
  deadline          TIMESTAMPTZ,
  created_at        TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at        TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_disputes_transaction_id    ON disputes (transaction_id);
CREATE INDEX idx_disputes_raised_by         ON disputes (raised_by);
CREATE INDEX idx_disputes_status            ON disputes (status);
CREATE INDEX idx_disputes_assigned_agent_id ON disputes (assigned_agent_id);


-- ============================================================
-- DISPUTE MESSAGES
-- ============================================================

CREATE TABLE dispute_messages (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id  UUID        NOT NULL REFERENCES disputes (id) ON DELETE CASCADE,
  sender_id   UUID        NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  body        TEXT        NOT NULL,
  attachments JSONB       NOT NULL DEFAULT '[]',
  is_internal BOOLEAN     NOT NULL DEFAULT FALSE,
  sent_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_dispute_messages_dispute_id ON dispute_messages (dispute_id);
CREATE INDEX idx_dispute_messages_sender_id  ON dispute_messages (sender_id);


-- ============================================================
-- DISPUTE RESOLUTIONS
-- ============================================================

CREATE TABLE dispute_resolutions (
  id                    UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
  dispute_id            UUID            NOT NULL UNIQUE REFERENCES disputes (id) ON DELETE RESTRICT,
  resolved_by           UUID            NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  verdict               dispute_verdict NOT NULL,
  buyer_refund_amount   NUMERIC(18,2)   NOT NULL DEFAULT 0 CHECK (buyer_refund_amount >= 0),
  seller_release_amount NUMERIC(18,2)   NOT NULL DEFAULT 0 CHECK (seller_release_amount >= 0),
  rationale             TEXT            NOT NULL,
  resolved_at           TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_resolutions_dispute_id  ON dispute_resolutions (dispute_id);
CREATE INDEX idx_resolutions_resolved_by ON dispute_resolutions (resolved_by);


-- ============================================================
-- REVIEWS
-- ============================================================

CREATE TABLE reviews (
  id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  reviewer_id   UUID        NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  reviewee_id   UUID        NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  transaction_id UUID       NOT NULL UNIQUE REFERENCES transactions (id) ON DELETE RESTRICT,
  rating        SMALLINT    NOT NULL CHECK (rating BETWEEN 1 AND 5),
  comment       TEXT,
  is_public     BOOLEAN     NOT NULL DEFAULT TRUE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT chk_no_self_review CHECK (reviewer_id <> reviewee_id)
);

CREATE INDEX idx_reviews_reviewer_id    ON reviews (reviewer_id);
CREATE INDEX idx_reviews_reviewee_id    ON reviews (reviewee_id);
CREATE INDEX idx_reviews_transaction_id ON reviews (transaction_id);


-- ============================================================
-- TRIGGERS — auto-update updated_at
-- ============================================================

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_users_updated_at
  BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_listings_updated_at
  BEFORE UPDATE ON listings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_transactions_updated_at
  BEFORE UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_wallets_updated_at
  BEFORE UPDATE ON wallet_accounts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_disputes_updated_at
  BEFORE UPDATE ON disputes
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ============================================================
-- TRIGGERS — auto-create escrow account on new transaction
-- ============================================================

CREATE OR REPLACE FUNCTION create_escrow_on_transaction()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO escrow_accounts (transaction_id, currency)
  VALUES (NEW.id, NEW.currency);
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_create_escrow
  AFTER INSERT ON transactions
  FOR EACH ROW EXECUTE FUNCTION create_escrow_on_transaction();


-- ============================================================
-- TRIGGERS — enforce valid transaction state transitions
-- ============================================================

CREATE OR REPLACE FUNCTION enforce_transaction_state_transition()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.state = NEW.state THEN
    RETURN NEW;
  END IF;

  IF NOT (
    (OLD.state = 'initiated'   AND NEW.state IN ('funded',     'cancelled')) OR
    (OLD.state = 'funded'      AND NEW.state IN ('inspecting', 'cancelled')) OR
    (OLD.state = 'inspecting'  AND NEW.state IN ('released',   'disputed',  'refunded')) OR
    (OLD.state = 'disputed'    AND NEW.state IN ('released',   'refunded'))
  ) THEN
    RAISE EXCEPTION
      'Invalid transaction state transition: % → %', OLD.state, NEW.state;
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_transaction_state_machine
  BEFORE UPDATE ON transactions
  FOR EACH ROW EXECUTE FUNCTION enforce_transaction_state_transition();


-- ============================================================
-- SEED: default payment gateways
-- ============================================================

INSERT INTO payment_gateways (name, provider, supported_currencies) VALUES
  ('Paystack NGN',  'paystack',  '["NGN"]'),
  ('Flutterwave',   'flutterwave', '["NGN","GHS","KES","ZAR","USD"]'),
  ('Stripe USD',    'stripe',    '["USD","EUR","GBP"]');

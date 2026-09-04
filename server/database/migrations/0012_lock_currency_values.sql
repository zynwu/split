-- Monetary ledger events keep the provider-independent settlement value that
-- was chosen when the event reached the server. These fields are separate from
-- the client payload so retrying the original payload remains idempotent.
ALTER TABLE ledger_events
	ADD COLUMN exchange_rate_to_usd NUMERIC(38, 18),
	ADD COLUMN usd_amount_minor_units BIGINT,
	ADD COLUMN rate_snapshot_date DATE;

ALTER TABLE ledger_events
	ADD CONSTRAINT ledger_events_currency_lock_chk
	CHECK (
		(exchange_rate_to_usd IS NULL AND usd_amount_minor_units IS NULL)
		OR (
			exchange_rate_to_usd IS NOT NULL
			AND exchange_rate_to_usd > 0
			AND usd_amount_minor_units IS NOT NULL
			AND usd_amount_minor_units >= 0
		)
	);

ALTER TABLE expenses
	ADD COLUMN exchange_rate_to_usd NUMERIC(38, 18),
	ADD COLUMN usd_total_minor_units BIGINT,
	ADD COLUMN rate_snapshot_date DATE;

ALTER TABLE payments
	ADD COLUMN exchange_rate_to_usd NUMERIC(38, 18),
	ADD COLUMN usd_amount_minor_units BIGINT,
	ADD COLUMN rate_snapshot_date DATE;

ALTER TABLE expense_splits
	ADD COLUMN usd_amount_minor_units BIGINT;

-- Existing USD records are already in the settlement currency and can be
-- backfilled exactly. Refuse to invent historical conversions for any older
-- non-USD event; its original server-time rate was not recorded before this
-- migration existed.
DO $$
BEGIN
	IF EXISTS (
		SELECT 1
		FROM ledger_events
		WHERE entity_type = 'expense'
			AND event_type IN ('expense.upsert', 'expense.created', 'expense.updated')
			AND (payload->>'currency_code') IS DISTINCT FROM 'USD'
	) OR EXISTS (
		SELECT 1
		FROM ledger_events
		WHERE entity_type = 'payment'
			AND event_type IN ('payment.upsert', 'payment.created', 'payment.updated')
			AND (payload->>'currency_code') IS DISTINCT FROM 'USD'
	) OR EXISTS (
		SELECT 1
		FROM expenses
		WHERE currency_code <> 'USD'
	) OR EXISTS (
		SELECT 1
		FROM payments
		WHERE currency_code <> 'USD'
	) THEN
		RAISE EXCEPTION
			'cannot lock existing non-USD records without their original exchange rates';
	END IF;
END $$;

UPDATE ledger_events
	SET exchange_rate_to_usd = 1,
		usd_amount_minor_units = (payload->>'total_minor_units')::BIGINT
	WHERE entity_type = 'expense'
		AND event_type IN ('expense.upsert', 'expense.created', 'expense.updated')
		AND payload->>'currency_code' = 'USD';

UPDATE ledger_events
	SET exchange_rate_to_usd = 1,
		usd_amount_minor_units = (payload->>'amount_minor_units')::BIGINT
	WHERE entity_type = 'payment'
		AND event_type IN ('payment.upsert', 'payment.created', 'payment.updated')
		AND payload->>'currency_code' = 'USD';

UPDATE expenses
	SET exchange_rate_to_usd = 1,
		usd_total_minor_units = total_minor_units
	WHERE currency_code = 'USD';

UPDATE payments
	SET exchange_rate_to_usd = 1,
		usd_amount_minor_units = amount_minor_units
	WHERE currency_code = 'USD';

UPDATE expense_splits
	SET usd_amount_minor_units = amount_minor_units;

ALTER TABLE expenses
	ALTER COLUMN exchange_rate_to_usd SET NOT NULL,
	ALTER COLUMN usd_total_minor_units SET NOT NULL;

ALTER TABLE expenses
	ADD CONSTRAINT expenses_exchange_rate_to_usd_chk
		CHECK (exchange_rate_to_usd > 0),
	ADD CONSTRAINT expenses_usd_total_minor_units_chk
		CHECK (usd_total_minor_units >= 0);

ALTER TABLE payments
	ALTER COLUMN exchange_rate_to_usd SET NOT NULL,
	ALTER COLUMN usd_amount_minor_units SET NOT NULL;

ALTER TABLE payments
	ADD CONSTRAINT payments_exchange_rate_to_usd_chk
		CHECK (exchange_rate_to_usd > 0),
	ADD CONSTRAINT payments_usd_amount_minor_units_chk
		CHECK (usd_amount_minor_units >= 0);

ALTER TABLE expense_splits
	ALTER COLUMN usd_amount_minor_units SET NOT NULL;

ALTER TABLE expense_splits
	ADD CONSTRAINT expense_splits_usd_amount_minor_units_chk
		CHECK (usd_amount_minor_units >= 0);

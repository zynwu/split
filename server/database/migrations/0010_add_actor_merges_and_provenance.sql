ALTER TABLE group_actors
	ADD COLUMN merged_into_actor_uuid UUID;

ALTER TABLE group_actors
	ADD CONSTRAINT group_actors_merged_into_fk
	FOREIGN KEY (group_uuid, merged_into_actor_uuid)
		REFERENCES group_actors(group_uuid, actor_uuid);

ALTER TABLE group_actors
	ADD CONSTRAINT group_actors_not_self_merged_chk
	CHECK (merged_into_actor_uuid IS NULL OR merged_into_actor_uuid <> actor_uuid);

CREATE INDEX group_actors_merged_into_idx
ON group_actors (group_uuid, merged_into_actor_uuid)
WHERE merged_into_actor_uuid IS NOT NULL;

ALTER TABLE expenses
	ADD COLUMN created_by_device_id TEXT;

ALTER TABLE expense_splits
	ADD COLUMN device_id TEXT;

ALTER TABLE payments
	ADD COLUMN created_by_device_id TEXT;

-- Existing projections were all produced by ledger events. Preserve the
-- device that recorded the first winning upsert as the creator provenance.
WITH first_expense_events AS (
	SELECT DISTINCT ON (group_uuid, entity_uuid)
		group_uuid, entity_uuid, device_id
	FROM ledger_events
	WHERE entity_type = 'expense'
		AND event_type IN ('expense.upsert', 'expense.created')
	ORDER BY group_uuid, entity_uuid, event_created_at, event_uuid
)
UPDATE expenses AS expense
SET created_by_device_id = event.device_id
FROM first_expense_events AS event
WHERE event.group_uuid = expense.group_uuid
	AND event.entity_uuid = expense.expense_uuid;

WITH first_payment_events AS (
	SELECT DISTINCT ON (group_uuid, entity_uuid)
		group_uuid, entity_uuid, device_id
	FROM ledger_events
	WHERE entity_type = 'payment'
		AND event_type IN ('payment.upsert', 'payment.created')
	ORDER BY group_uuid, entity_uuid, event_created_at, event_uuid
)
UPDATE payments AS payment
SET created_by_device_id = event.device_id
FROM first_payment_events AS event
WHERE event.group_uuid = payment.group_uuid
	AND event.entity_uuid = payment.payment_uuid;

-- Split rows are the current snapshot of the winning expense payload. The
-- most recent winning upsert's device is the provenance for each current row;
-- the complete historical actor/device pair remains in ledger_events.payload.
WITH current_expense_events AS (
	SELECT DISTINCT ON (group_uuid, entity_uuid)
		group_uuid, entity_uuid, device_id
	FROM ledger_events
	WHERE entity_type = 'expense'
		AND event_type IN ('expense.upsert', 'expense.created')
	ORDER BY group_uuid, entity_uuid, event_created_at DESC, event_uuid DESC
)
UPDATE expense_splits AS split
SET device_id = event.device_id
FROM current_expense_events AS event
WHERE event.group_uuid = split.group_uuid
	AND event.entity_uuid = split.expense_uuid;

ALTER TABLE expenses
	ALTER COLUMN created_by_device_id SET NOT NULL;

ALTER TABLE expenses
	ADD CONSTRAINT expenses_created_by_device_fk
	FOREIGN KEY (created_by_device_id)
		REFERENCES devices(device_id);

ALTER TABLE expense_splits
	ALTER COLUMN device_id SET NOT NULL;

ALTER TABLE expense_splits
	ADD CONSTRAINT expense_splits_device_fk
	FOREIGN KEY (device_id)
		REFERENCES devices(device_id);

ALTER TABLE payments
	ALTER COLUMN created_by_device_id SET NOT NULL;

ALTER TABLE payments
	ADD CONSTRAINT payments_created_by_device_fk
	FOREIGN KEY (created_by_device_id)
		REFERENCES devices(device_id);

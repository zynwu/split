ALTER TABLE ledger_events
	ADD COLUMN event_created_at TIMESTAMPTZ;

-- Events written before this field existed have no client-side creation time;
-- use their server receipt time as the only available historical value.
UPDATE ledger_events
SET event_created_at = recorded_at
WHERE event_created_at IS NULL;

ALTER TABLE ledger_events
	ALTER COLUMN event_created_at SET DEFAULT CURRENT_TIMESTAMP,
	ALTER COLUMN event_created_at SET NOT NULL;

-- Keep existing projections internally consistent with their winning event.
UPDATE expenses AS e
SET created_at = first_event.event_created_at,
	updated_at = e.updated_at
FROM (
	SELECT group_uuid,
		entity_uuid,
		MIN(event_created_at) AS event_created_at
	FROM ledger_events
	WHERE entity_type = 'expense'
	GROUP BY group_uuid, entity_uuid
) AS first_event
WHERE e.group_uuid = first_event.group_uuid
	AND e.expense_uuid = first_event.entity_uuid;

UPDATE expenses AS e
SET updated_at = winning_event.event_created_at
FROM ledger_events AS winning_event
WHERE winning_event.group_uuid = e.group_uuid
	AND winning_event.sequence = e.latest_event_sequence;

CREATE INDEX ledger_events_group_entity_creation_idx
ON ledger_events (group_uuid, entity_type, entity_uuid, event_created_at, event_uuid);

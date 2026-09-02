ALTER TABLE groups
	ADD COLUMN latest_event_sequence BIGINT NOT NULL DEFAULT 0;

ALTER TABLE groups
	ADD CONSTRAINT groups_latest_event_sequence_nonnegative_chk
	CHECK (latest_event_sequence >= 0);

CREATE TABLE ledger_events (
	event_uuid UUID PRIMARY KEY,
	group_uuid UUID NOT NULL REFERENCES groups(uuid) ON DELETE CASCADE,
	sequence BIGINT NOT NULL CHECK (sequence > 0),
	entity_type TEXT NOT NULL CHECK (char_length(entity_type) BETWEEN 1 AND 64),
	entity_uuid UUID NOT NULL,
	event_type TEXT NOT NULL CHECK (char_length(event_type) BETWEEN 1 AND 64),
	actor_uuid UUID NOT NULL,
	device_id TEXT NOT NULL REFERENCES devices(device_id),
	client_sequence BIGINT NOT NULL CHECK (client_sequence >= 0),
	base_sequence BIGINT NOT NULL DEFAULT 0 CHECK (base_sequence >= 0),
	had_conflict BOOLEAN NOT NULL DEFAULT FALSE,
	payload_version INTEGER NOT NULL DEFAULT 1 CHECK (payload_version > 0),
	payload_hash BYTEA NOT NULL,
	payload JSONB NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
	recorded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
	UNIQUE (group_uuid, sequence),
	UNIQUE (device_id, client_sequence),
	FOREIGN KEY (group_uuid, actor_uuid)
		REFERENCES group_actors(group_uuid, actor_uuid)
);

CREATE INDEX ledger_events_group_entity_sequence_idx
ON ledger_events (group_uuid, entity_type, entity_uuid, sequence);

CREATE TABLE expenses (
	expense_uuid UUID PRIMARY KEY,
	group_uuid UUID NOT NULL,
	created_by_actor_uuid UUID NOT NULL,
	payer_actor_uuid UUID NOT NULL,
	name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 255),
	description TEXT NOT NULL DEFAULT '' CHECK (char_length(description) <= 4000),
	currency_code TEXT NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
	total_minor_units BIGINT NOT NULL CHECK (total_minor_units > 0),
	split_method TEXT NOT NULL CHECK (char_length(split_method) BETWEEN 1 AND 64),
	split_config JSONB NOT NULL DEFAULT '{}'::jsonb
		CHECK (jsonb_typeof(split_config) = 'object'),
	occurred_at TIMESTAMPTZ NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
	updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
	latest_event_sequence BIGINT NOT NULL CHECK (latest_event_sequence > 0),
	voided_at TIMESTAMPTZ,
	UNIQUE (group_uuid, expense_uuid),
	FOREIGN KEY (group_uuid, created_by_actor_uuid)
		REFERENCES group_actors(group_uuid, actor_uuid),
	FOREIGN KEY (group_uuid, payer_actor_uuid)
		REFERENCES group_actors(group_uuid, actor_uuid)
);

CREATE INDEX expenses_group_updated_idx
ON expenses (group_uuid, updated_at, expense_uuid);

CREATE INDEX expenses_group_active_idx
ON expenses (group_uuid, occurred_at, expense_uuid)
WHERE voided_at IS NULL;

CREATE TABLE expense_splits (
	group_uuid UUID NOT NULL,
	expense_uuid UUID NOT NULL,
	actor_uuid UUID NOT NULL,
	amount_minor_units BIGINT NOT NULL CHECK (amount_minor_units >= 0),
	PRIMARY KEY (expense_uuid, actor_uuid),
	FOREIGN KEY (group_uuid, expense_uuid)
		REFERENCES expenses(group_uuid, expense_uuid) ON DELETE CASCADE,
	FOREIGN KEY (group_uuid, actor_uuid)
		REFERENCES group_actors(group_uuid, actor_uuid)
);

CREATE INDEX expense_splits_group_expense_idx
ON expense_splits (group_uuid, expense_uuid);

CREATE TABLE payments (
	payment_uuid UUID PRIMARY KEY,
	group_uuid UUID NOT NULL,
	created_by_actor_uuid UUID NOT NULL,
	from_actor_uuid UUID NOT NULL,
	to_actor_uuid UUID NOT NULL,
	currency_code TEXT NOT NULL CHECK (currency_code ~ '^[A-Z]{3}$'),
	amount_minor_units BIGINT NOT NULL CHECK (amount_minor_units > 0),
	occurred_at TIMESTAMPTZ NOT NULL,
	created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
	updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
	latest_event_sequence BIGINT NOT NULL CHECK (latest_event_sequence > 0),
	voided_at TIMESTAMPTZ,
	UNIQUE (group_uuid, payment_uuid),
	CHECK (from_actor_uuid <> to_actor_uuid),
	FOREIGN KEY (group_uuid, created_by_actor_uuid)
		REFERENCES group_actors(group_uuid, actor_uuid),
	FOREIGN KEY (group_uuid, from_actor_uuid)
		REFERENCES group_actors(group_uuid, actor_uuid),
	FOREIGN KEY (group_uuid, to_actor_uuid)
		REFERENCES group_actors(group_uuid, actor_uuid)
);

CREATE INDEX payments_group_occurred_idx
ON payments (group_uuid, occurred_at, payment_uuid);

CREATE INDEX payments_group_active_idx
ON payments (group_uuid, occurred_at, payment_uuid)
WHERE voided_at IS NULL;

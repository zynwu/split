CREATE TABLE IF NOT EXISTS groups (
	uuid UUID PRIMARY KEY,
	name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 255),
	creation_date TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS group_actors (
	actor_uuid UUID PRIMARY KEY,
	group_uuid UUID NOT NULL REFERENCES groups(uuid) ON DELETE CASCADE,
	display_name TEXT,
	created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
	archived_at TIMESTAMPTZ,
	UNIQUE (group_uuid, actor_uuid)
);

CREATE TABLE IF NOT EXISTS devices (
	device_id TEXT PRIMARY KEY,
	first_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
	last_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS actor_device_bindings (
	binding_uuid UUID PRIMARY KEY,
	group_uuid UUID NOT NULL,
	actor_uuid UUID NOT NULL,
	device_id TEXT NOT NULL REFERENCES devices(device_id),
	bound_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
	unbound_at TIMESTAMPTZ,
	unbound_reason TEXT,
	FOREIGN KEY (group_uuid, actor_uuid)
		REFERENCES group_actors(group_uuid, actor_uuid),
	CHECK (unbound_at IS NULL OR unbound_at > bound_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS actor_device_bindings_active_device_idx
ON actor_device_bindings (group_uuid, device_id)
WHERE unbound_at IS NULL;

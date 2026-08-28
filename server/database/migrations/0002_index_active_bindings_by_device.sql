CREATE INDEX IF NOT EXISTS actor_device_bindings_active_device_lookup_idx
ON actor_device_bindings (device_id, group_uuid)
WHERE unbound_at IS NULL;

ALTER TABLE devices
	ADD COLUMN IF NOT EXISTS auth_token_hash BYTEA;

CREATE UNIQUE INDEX IF NOT EXISTS devices_auth_token_hash_idx
ON devices (auth_token_hash)
WHERE auth_token_hash IS NOT NULL;

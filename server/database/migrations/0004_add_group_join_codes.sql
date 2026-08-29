ALTER TABLE groups
	ADD COLUMN IF NOT EXISTS join_code TEXT;

DO $$
DECLARE
	group_row RECORD;
	candidate TEXT;
	random_bytes BYTEA;
	position_index INTEGER;
	alphabet CONSTANT TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ';
BEGIN
	FOR group_row IN
		SELECT uuid
		FROM groups
		WHERE join_code IS NULL
		ORDER BY uuid
	LOOP
		LOOP
			random_bytes := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
			candidate := '';

			FOR position_index IN 0..5 LOOP
				candidate := candidate || substr(
					alphabet,
					(get_byte(random_bytes, position_index) % length(alphabet)) + 1,
					1
				);
			END LOOP;

			EXIT WHEN NOT EXISTS (
				SELECT 1
				FROM groups AS existing_group
				WHERE existing_group.join_code = candidate
			);
		END LOOP;

		UPDATE groups
		SET join_code = candidate
		WHERE uuid = group_row.uuid;
	END LOOP;
END $$;

ALTER TABLE groups
	ALTER COLUMN join_code SET NOT NULL;

ALTER TABLE groups
	ADD CONSTRAINT groups_join_code_format_chk
	CHECK (join_code ~ '^[A-Z]{6}$');

CREATE UNIQUE INDEX IF NOT EXISTS groups_join_code_idx
ON groups (join_code);

ALTER TABLE groups
	ADD COLUMN latest_metadata_event_sequence BIGINT NOT NULL DEFAULT 0;

ALTER TABLE groups
	ADD CONSTRAINT groups_latest_metadata_event_sequence_nonnegative_chk
	CHECK (latest_metadata_event_sequence >= 0);

ALTER TABLE group_actors
	ADD COLUMN latest_metadata_event_sequence BIGINT NOT NULL DEFAULT 0;

ALTER TABLE group_actors
	ADD CONSTRAINT group_actors_latest_metadata_event_sequence_nonnegative_chk
	CHECK (latest_metadata_event_sequence >= 0);

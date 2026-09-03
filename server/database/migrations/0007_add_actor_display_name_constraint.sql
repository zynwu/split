ALTER TABLE group_actors
	ADD CONSTRAINT group_actors_display_name_length_chk
	CHECK (display_name IS NULL OR char_length(display_name) BETWEEN 1 AND 255);

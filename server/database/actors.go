package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
)

var ErrInvalidDisplayName = errors.New("invalid actor display name")

// NormalizeDisplayName trims a display name and enforces the same bounds used
// by the group_actors.display_name database constraint.
func NormalizeDisplayName(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("%w: name must not be empty", ErrInvalidDisplayName)
	}
	if len([]rune(value)) > 255 {
		return "", fmt.Errorf("%w: name must be at most 255 characters", ErrInvalidDisplayName)
	}
	return value, nil
}

// UpdateActorDisplayName changes an active actor's name within one group.
// Group members are trusted to rename active actors, matching the current
// group trust model and leaving room for future actor-commandeering flows.
func (database *Database) UpdateActorDisplayName(ctx context.Context, groupUUID, actorUUID, deviceID, displayName string) (GroupActor, error) {
	groupUUID, err := normalizeUUID(groupUUID, "group_uuid")
	if err != nil {
		return GroupActor{}, err
	}
	actorUUID, err = normalizeUUID(actorUUID, "actor_uuid")
	if err != nil {
		return GroupActor{}, err
	}
	displayName, err = NormalizeDisplayName(displayName)
	if err != nil {
		return GroupActor{}, err
	}

	tx, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return GroupActor{}, fmt.Errorf("begin actor name update transaction: %w", err)
	}
	defer tx.Rollback()

	var groupExists bool
	if err := tx.QueryRowContext(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM groups
			WHERE uuid = $1
		)`, groupUUID).Scan(&groupExists); err != nil {
		return GroupActor{}, fmt.Errorf("check actor name update group: %w", err)
	}
	if !groupExists {
		return GroupActor{}, ErrGroupNotFound
	}

	member, err := activeGroupMembershipTx(ctx, tx, groupUUID, deviceID)
	if err != nil {
		return GroupActor{}, fmt.Errorf("check actor name update membership: %w", err)
	}
	if !member {
		return GroupActor{}, ErrGroupMembershipDenied
	}

	var actor GroupActor
	err = tx.QueryRowContext(ctx, `
		UPDATE group_actors
		SET display_name = $3
		WHERE group_uuid = $1
			AND actor_uuid = $2
			AND archived_at IS NULL
		RETURNING actor_uuid, display_name`, groupUUID, actorUUID, displayName).Scan(
		&actor.ActorUUID,
		&actor.DisplayName,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return GroupActor{}, ErrActorNotFound
	}
	if err != nil {
		return GroupActor{}, fmt.Errorf("update actor display name: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return GroupActor{}, fmt.Errorf("commit actor name update: %w", err)
	}

	return actor, nil
}

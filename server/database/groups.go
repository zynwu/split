package database

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/google/uuid"
)

var (
	ErrGroupNotFound    = errors.New("group not found")
	ErrInvalidGroupName = errors.New("invalid group name")
)

const (
	joinCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ"
	joinCodeLength   = 6
)

func (database *Database) CreateGroup(ctx context.Context, name, displayName, deviceID string) (GroupMembership, error) {
	name, err := NormalizeGroupName(name)
	if err != nil {
		return GroupMembership{}, err
	}

	displayName, err = NormalizeDisplayName(displayName)
	if err != nil {
		return GroupMembership{}, err
	}

	const maxJoinCodeAttempts = 5

	for attempt := 0; attempt < maxJoinCodeAttempts; attempt++ {
		membership, retry, err := database.createGroupAttempt(ctx, name, displayName, deviceID)
		if err != nil {
			return GroupMembership{}, err
		}
		if !retry {
			return membership, nil
		}
	}

	return GroupMembership{}, fmt.Errorf("generate a unique group join code after %d attempts", maxJoinCodeAttempts)
}

func (database *Database) createGroupAttempt(ctx context.Context, name, displayName, deviceID string) (GroupMembership, bool, error) {
	groupUUID, err := uuid.NewRandom()
	if err != nil {
		return GroupMembership{}, false, fmt.Errorf("generate group uuid: %w", err)
	}
	actorUUID, err := uuid.NewRandom()
	if err != nil {
		return GroupMembership{}, false, fmt.Errorf("generate actor uuid: %w", err)
	}
	bindingUUID, err := uuid.NewRandom()
	if err != nil {
		return GroupMembership{}, false, fmt.Errorf("generate binding uuid: %w", err)
	}
	joinCode, err := generateJoinCode()
	if err != nil {
		return GroupMembership{}, false, err
	}

	tx, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return GroupMembership{}, false, fmt.Errorf("begin group creation transaction: %w", err)
	}
	defer tx.Rollback()

	const groupQuery = `
		INSERT INTO groups (uuid, name, join_code)
		VALUES ($1, $2, $3)
		ON CONFLICT (join_code) DO NOTHING
		RETURNING uuid, name, creation_date, join_code, latest_event_sequence,
			latest_metadata_event_sequence`

	var group Group
	err = tx.QueryRowContext(ctx, groupQuery, groupUUID.String(), name, joinCode).Scan(
		&group.UUID,
		&group.Name,
		&group.CreationDate,
		&group.JoinCode,
		&group.LatestEventSequence,
		&group.LatestMetadataEventSequence,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return GroupMembership{}, true, nil
	}
	if err != nil {
		return GroupMembership{}, false, fmt.Errorf("insert group: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO group_actors (actor_uuid, group_uuid, display_name)
		VALUES ($1, $2, $3)`, actorUUID.String(), groupUUID.String(), displayName); err != nil {
		return GroupMembership{}, false, fmt.Errorf("insert group actor: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO actor_device_bindings (binding_uuid, group_uuid, actor_uuid, device_id)
		VALUES ($1, $2, $3, $4)`, bindingUUID.String(), groupUUID.String(), actorUUID.String(), deviceID); err != nil {
		return GroupMembership{}, false, fmt.Errorf("bind device to group actor: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return GroupMembership{}, false, fmt.Errorf("commit group creation transaction: %w", err)
	}

	return GroupMembership{
		Group:     group,
		ActorUUID: actorUUID.String(),
	}, false, nil
}

func (database *Database) ListGroupsForDevice(ctx context.Context, deviceID string) ([]GroupWithActors, error) {
	const query = `
		SELECT g.uuid, g.name, g.creation_date, g.join_code,
			g.latest_event_sequence,
			g.latest_metadata_event_sequence,
			current_binding.actor_uuid,
			a.actor_uuid, COALESCE(a.display_name, ''),
			a.latest_metadata_event_sequence
		FROM actor_device_bindings AS current_binding
		JOIN groups AS g
			ON g.uuid = current_binding.group_uuid
		JOIN group_actors AS current_actor
			ON current_actor.group_uuid = current_binding.group_uuid
			AND current_actor.actor_uuid = current_binding.actor_uuid
			AND current_actor.archived_at IS NULL
		JOIN group_actors AS a
			ON a.group_uuid = current_binding.group_uuid
			AND a.archived_at IS NULL
		WHERE current_binding.device_id = $1
			AND current_binding.unbound_at IS NULL
		ORDER BY g.creation_date, g.uuid, a.created_at, a.actor_uuid`

	rows, err := database.db.QueryContext(ctx, query, deviceID)
	if err != nil {
		return nil, fmt.Errorf("query groups for device: %w", err)
	}
	defer rows.Close()

	groups := make([]GroupWithActors, 0)
	for rows.Next() {
		var group Group
		var currentActorUUID string
		var actor GroupActor
		if err := rows.Scan(
			&group.UUID,
			&group.Name,
			&group.CreationDate,
			&group.JoinCode,
			&group.LatestEventSequence,
			&group.LatestMetadataEventSequence,
			&currentActorUUID,
			&actor.ActorUUID,
			&actor.DisplayName,
			&actor.LatestMetadataEventSequence,
		); err != nil {
			return nil, fmt.Errorf("scan group membership: %w", err)
		}

		if len(groups) == 0 || groups[len(groups)-1].UUID != group.UUID {
			groups = append(groups, GroupWithActors{
				Group:     group,
				ActorUUID: currentActorUUID,
				Actors:    make([]GroupActor, 0, 1),
			})
		}
		groups[len(groups)-1].Actors = append(groups[len(groups)-1].Actors, actor)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate group memberships: %w", err)
	}

	return groups, nil
}

// NormalizeGroupName trims a group name and enforces the same bounds used by
// the groups.name database constraint.
func NormalizeGroupName(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("%w: name must not be empty", ErrInvalidGroupName)
	}
	if len([]rune(value)) > 255 {
		return "", fmt.Errorf("%w: name must be at most 255 characters", ErrInvalidGroupName)
	}
	return value, nil
}

func (database *Database) JoinGroup(ctx context.Context, deviceID, joinCode, displayName string) (GroupMembership, error) {
	displayName, err := NormalizeDisplayName(displayName)
	if err != nil {
		return GroupMembership{}, err
	}

	groupTransaction, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return GroupMembership{}, fmt.Errorf("begin group join transaction: %w", err)
	}
	defer groupTransaction.Rollback()

	// Lock the group row so two simultaneous joins by the same device cannot
	// both create a new actor before seeing the other's binding.
	var group Group
	err = groupTransaction.QueryRowContext(ctx, `
		SELECT uuid, name, creation_date, join_code, latest_event_sequence,
			latest_metadata_event_sequence
		FROM groups
		WHERE join_code = $1
		FOR UPDATE`, joinCode).Scan(
		&group.UUID,
		&group.Name,
		&group.CreationDate,
		&group.JoinCode,
		&group.LatestEventSequence,
		&group.LatestMetadataEventSequence,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return GroupMembership{}, ErrGroupNotFound
	}
	if err != nil {
		return GroupMembership{}, fmt.Errorf("find group by join code: %w", err)
	}

	var existingActorUUID string
	var existingDisplayName sql.NullString
	err = groupTransaction.QueryRowContext(ctx, `
		SELECT binding.actor_uuid, actor.display_name
		FROM actor_device_bindings AS binding
		JOIN group_actors AS actor
			ON actor.group_uuid = binding.group_uuid
			AND actor.actor_uuid = binding.actor_uuid
		WHERE binding.group_uuid = $1
			AND binding.device_id = $2
			AND binding.unbound_at IS NULL
		FOR UPDATE`, group.UUID, deviceID).Scan(&existingActorUUID, &existingDisplayName)
	if err == nil {
		if !existingDisplayName.Valid || existingDisplayName.String == "" {
			if _, err := groupTransaction.ExecContext(ctx, `
				UPDATE group_actors
				SET display_name = $3
				WHERE group_uuid = $1 AND actor_uuid = $2`, group.UUID, existingActorUUID, displayName); err != nil {
				return GroupMembership{}, fmt.Errorf("set existing actor display name: %w", err)
			}
		}
		if err := groupTransaction.Commit(); err != nil {
			return GroupMembership{}, fmt.Errorf("commit existing group membership: %w", err)
		}
		return GroupMembership{
			Group:     group,
			ActorUUID: existingActorUUID,
		}, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return GroupMembership{}, fmt.Errorf("check existing group membership: %w", err)
	}

	actorUUID, err := uuid.NewRandom()
	if err != nil {
		return GroupMembership{}, fmt.Errorf("generate joining actor uuid: %w", err)
	}
	bindingUUID, err := uuid.NewRandom()
	if err != nil {
		return GroupMembership{}, fmt.Errorf("generate joining binding uuid: %w", err)
	}

	if _, err := groupTransaction.ExecContext(ctx, `
		INSERT INTO group_actors (actor_uuid, group_uuid, display_name)
		VALUES ($1, $2, $3)`, actorUUID.String(), group.UUID, displayName); err != nil {
		return GroupMembership{}, fmt.Errorf("insert joining group actor: %w", err)
	}

	if _, err := groupTransaction.ExecContext(ctx, `
		INSERT INTO actor_device_bindings (binding_uuid, group_uuid, actor_uuid, device_id)
		VALUES ($1, $2, $3, $4)`, bindingUUID.String(), group.UUID, actorUUID.String(), deviceID); err != nil {
		return GroupMembership{}, fmt.Errorf("bind joining device to group actor: %w", err)
	}

	if err := groupTransaction.Commit(); err != nil {
		return GroupMembership{}, fmt.Errorf("commit group join transaction: %w", err)
	}

	return GroupMembership{
		Group:     group,
		ActorUUID: actorUUID.String(),
	}, nil
}

func generateJoinCode() (string, error) {
	code := make([]byte, joinCodeLength)
	alphabetLength := big.NewInt(int64(len(joinCodeAlphabet)))

	for index := range code {
		position, err := rand.Int(rand.Reader, alphabetLength)
		if err != nil {
			return "", fmt.Errorf("generate group join code: %w", err)
		}
		code[index] = joinCodeAlphabet[position.Int64()]
	}

	return string(code), nil
}

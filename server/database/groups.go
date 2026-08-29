package database

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"math/big"

	"github.com/google/uuid"
)

var ErrGroupNotFound = errors.New("group not found")

const (
	joinCodeAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ"
	joinCodeLength   = 6
)

func (database *Database) CreateGroup(ctx context.Context, name, deviceID string) (GroupMembership, error) {
	const maxJoinCodeAttempts = 5

	for attempt := 0; attempt < maxJoinCodeAttempts; attempt++ {
		membership, retry, err := database.createGroupAttempt(ctx, name, deviceID)
		if err != nil {
			return GroupMembership{}, err
		}
		if !retry {
			return membership, nil
		}
	}

	return GroupMembership{}, fmt.Errorf("generate a unique group join code after %d attempts", maxJoinCodeAttempts)
}

func (database *Database) createGroupAttempt(ctx context.Context, name, deviceID string) (GroupMembership, bool, error) {
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
		RETURNING uuid, name, creation_date, join_code`

	var group Group
	err = tx.QueryRowContext(ctx, groupQuery, groupUUID.String(), name, joinCode).Scan(
		&group.UUID,
		&group.Name,
		&group.CreationDate,
		&group.JoinCode,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return GroupMembership{}, true, nil
	}
	if err != nil {
		return GroupMembership{}, false, fmt.Errorf("insert group: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO group_actors (actor_uuid, group_uuid)
		VALUES ($1, $2)`, actorUUID.String(), groupUUID.String()); err != nil {
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

func (database *Database) ListGroupsForDevice(ctx context.Context, deviceID string) ([]GroupMembership, error) {
	const query = `
		SELECT g.uuid, g.name, g.creation_date, g.join_code, b.actor_uuid
		FROM actor_device_bindings AS b
		JOIN groups AS g
			ON g.uuid = b.group_uuid
		JOIN group_actors AS a
			ON a.group_uuid = b.group_uuid
			AND a.actor_uuid = b.actor_uuid
		WHERE b.device_id = $1
			AND b.unbound_at IS NULL
			AND a.archived_at IS NULL
		ORDER BY g.creation_date, g.uuid`

	rows, err := database.db.QueryContext(ctx, query, deviceID)
	if err != nil {
		return nil, fmt.Errorf("query groups for device: %w", err)
	}
	defer rows.Close()

	groups := make([]GroupMembership, 0)
	for rows.Next() {
		var membership GroupMembership
		if err := rows.Scan(
			&membership.UUID,
			&membership.Name,
			&membership.CreationDate,
			&membership.JoinCode,
			&membership.ActorUUID,
		); err != nil {
			return nil, fmt.Errorf("scan group membership: %w", err)
		}
		groups = append(groups, membership)
	}

	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate group memberships: %w", err)
	}

	return groups, nil
}

func (database *Database) JoinGroup(ctx context.Context, deviceID, joinCode string) (GroupMembership, error) {
	groupTransaction, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return GroupMembership{}, fmt.Errorf("begin group join transaction: %w", err)
	}
	defer groupTransaction.Rollback()

	// Lock the group row so two simultaneous joins by the same device cannot
	// both create a new actor before seeing the other's binding.
	var group Group
	err = groupTransaction.QueryRowContext(ctx, `
		SELECT uuid, name, creation_date, join_code
		FROM groups
		WHERE join_code = $1
		FOR UPDATE`, joinCode).Scan(
		&group.UUID,
		&group.Name,
		&group.CreationDate,
		&group.JoinCode,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return GroupMembership{}, ErrGroupNotFound
	}
	if err != nil {
		return GroupMembership{}, fmt.Errorf("find group by join code: %w", err)
	}

	var existingActorUUID string
	err = groupTransaction.QueryRowContext(ctx, `
		SELECT actor_uuid
		FROM actor_device_bindings
		WHERE group_uuid = $1
			AND device_id = $2
			AND unbound_at IS NULL
		FOR UPDATE`, group.UUID, deviceID).Scan(&existingActorUUID)
	if err == nil {
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
		INSERT INTO group_actors (actor_uuid, group_uuid)
		VALUES ($1, $2)`, actorUUID.String(), group.UUID); err != nil {
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

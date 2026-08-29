package database

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/google/uuid"
	_ "github.com/jackc/pgx/v5/stdlib"
)

type Database struct {
	db *sql.DB
}

type Group struct {
	UUID         string    `json:"uuid"`
	Name         string    `json:"name"`
	CreationDate time.Time `json:"creation_date"`
}

type GroupMembership struct {
	Group
	ActorUUID string `json:"actor_uuid"`
}

func Open(ctx context.Context, databaseURL string) (*Database, error) {
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		return nil, fmt.Errorf("open postgres connection: %w", err)
	}

	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(30 * time.Minute)

	database := &Database{db: db}
	if err := database.db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}

	if err := database.runMigrations(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}

	return database, nil
}

func (database *Database) Close() error {
	return database.db.Close()
}

func (database *Database) Ping(ctx context.Context) error {
	return database.db.PingContext(ctx)
}

func (database *Database) CreateGroup(ctx context.Context, name, deviceID string) (GroupMembership, error) {
	groupUUID, err := uuid.NewRandom()
	if err != nil {
		return GroupMembership{}, fmt.Errorf("generate group uuid: %w", err)
	}
	actorUUID, err := uuid.NewRandom()
	if err != nil {
		return GroupMembership{}, fmt.Errorf("generate actor uuid: %w", err)
	}
	bindingUUID, err := uuid.NewRandom()
	if err != nil {
		return GroupMembership{}, fmt.Errorf("generate binding uuid: %w", err)
	}

	tx, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return GroupMembership{}, fmt.Errorf("begin group creation transaction: %w", err)
	}
	defer tx.Rollback()

	const groupQuery = `
		INSERT INTO groups (uuid, name)
		VALUES ($1, $2)
		RETURNING uuid, name, creation_date`

	var group Group
	if err := tx.QueryRowContext(ctx, groupQuery, groupUUID.String(), name).Scan(
		&group.UUID,
		&group.Name,
		&group.CreationDate,
	); err != nil {
		return GroupMembership{}, fmt.Errorf("insert group: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO group_actors (actor_uuid, group_uuid)
		VALUES ($1, $2)`, actorUUID.String(), groupUUID.String()); err != nil {
		return GroupMembership{}, fmt.Errorf("insert group actor: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO actor_device_bindings (binding_uuid, group_uuid, actor_uuid, device_id)
		VALUES ($1, $2, $3, $4)`, bindingUUID.String(), groupUUID.String(), actorUUID.String(), deviceID); err != nil {
		return GroupMembership{}, fmt.Errorf("bind device to group actor: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return GroupMembership{}, fmt.Errorf("commit group creation transaction: %w", err)
	}

	return GroupMembership{
		Group:     group,
		ActorUUID: actorUUID.String(),
	}, nil
}

func (database *Database) ListGroupsForDevice(ctx context.Context, deviceID string) ([]GroupMembership, error) {
	const query = `
		SELECT g.uuid, g.name, g.creation_date, b.actor_uuid
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

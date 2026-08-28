package main

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

func openDatabase(ctx context.Context, databaseURL string) (*Database, error) {
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

	if err := database.ensureSchema(ctx); err != nil {
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

func (database *Database) ensureSchema(ctx context.Context) error {
	tx, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin schema transaction: %w", err)
	}
	defer tx.Rollback()

	if _, err := tx.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS groups (
			uuid UUID PRIMARY KEY,
			name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 255),
			creation_date TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`); err != nil {
		return fmt.Errorf("create groups table: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS group_actors (
			actor_uuid UUID PRIMARY KEY,
			group_uuid UUID NOT NULL REFERENCES groups(uuid) ON DELETE CASCADE,
			display_name TEXT,
			created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
			archived_at TIMESTAMPTZ,
			UNIQUE (group_uuid, actor_uuid)
		)`); err != nil {
		return fmt.Errorf("create group actors table: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS devices (
			device_id TEXT PRIMARY KEY,
			first_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
			last_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`); err != nil {
		return fmt.Errorf("create devices table: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
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
		)`); err != nil {
		return fmt.Errorf("create actor device bindings table: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		CREATE UNIQUE INDEX IF NOT EXISTS actor_device_bindings_active_device_idx
		ON actor_device_bindings (group_uuid, device_id)
		WHERE unbound_at IS NULL`); err != nil {
		return fmt.Errorf("index active actor device bindings: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit schema transaction: %w", err)
	}
	return nil
}

func (database *Database) CreateGroup(ctx context.Context, name string) (Group, error) {
	groupUUID, err := uuid.NewRandom()
	if err != nil {
		return Group{}, fmt.Errorf("generate group uuid: %w", err)
	}

	const query = `
		INSERT INTO groups (uuid, name)
		VALUES ($1, $2)
		RETURNING uuid, name, creation_date`

	var group Group
	if err := database.db.QueryRowContext(ctx, query, groupUUID.String(), name).Scan(
		&group.UUID,
		&group.Name,
		&group.CreationDate,
	); err != nil {
		return Group{}, fmt.Errorf("insert group: %w", err)
	}

	return group, nil
}

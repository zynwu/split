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

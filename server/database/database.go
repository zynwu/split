package database

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

type Database struct {
	db *sql.DB
}

type Group struct {
	UUID         string    `json:"uuid"`
	Name         string    `json:"name"`
	CreationDate time.Time `json:"creation_date"`
	JoinCode     string    `json:"join_code"`
}

type GroupActor struct {
	ActorUUID   string `json:"actor_uuid"`
	DisplayName string `json:"display_name"`
}

type GroupMembership struct {
	Group
	ActorUUID string `json:"actor_uuid"`
}

type GroupWithActors struct {
	Group
	ActorUUID string       `json:"actor_uuid"`
	Actors    []GroupActor `json:"actors"`
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

package main

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
	ID        int64     `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
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
	const query = `
		CREATE TABLE IF NOT EXISTS groups (
			id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
			name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 255),
			created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`

	if _, err := database.db.ExecContext(ctx, query); err != nil {
		return fmt.Errorf("create groups table: %w", err)
	}
	return nil
}

func (database *Database) CreateGroup(ctx context.Context, name string) (Group, error) {
	const query = `
		INSERT INTO groups (name)
		VALUES ($1)
		RETURNING id, name, created_at`

	var group Group
	if err := database.db.QueryRowContext(ctx, query, name).Scan(
		&group.ID,
		&group.Name,
		&group.CreatedAt,
	); err != nil {
		return Group{}, fmt.Errorf("insert group: %w", err)
	}

	return group, nil
}

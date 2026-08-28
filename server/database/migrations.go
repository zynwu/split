package database

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"embed"
	"fmt"
	"io/fs"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// The migration files are compiled into the API binary, so the same migrations
// run whether the server is started locally or from its Docker image.
//
//go:embed migrations/*.sql
var migrationFiles embed.FS

const schemaMigrationLockKey int64 = 834727193

type migration struct {
	version  int64
	name     string
	path     string
	sql      string
	checksum string
}

func (database *Database) runMigrations(ctx context.Context) error {
	migrations, err := loadMigrations()
	if err != nil {
		return fmt.Errorf("load migrations: %w", err)
	}

	for _, migration := range migrations {
		if err := database.applyMigration(ctx, migration); err != nil {
			return fmt.Errorf("apply migration %s: %w", migration.path, err)
		}
	}

	return nil
}

func loadMigrations() ([]migration, error) {
	entries, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		return nil, err
	}

	filenamePattern := regexp.MustCompile(`^([0-9]+)_([a-z0-9_]+)\.sql$`)
	migrations := make([]migration, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}

		matches := filenamePattern.FindStringSubmatch(entry.Name())
		if matches == nil {
			return nil, fmt.Errorf("invalid migration filename %q; use NNNN_description.sql", entry.Name())
		}

		version, err := strconv.ParseInt(matches[1], 10, 64)
		if err != nil || version <= 0 {
			return nil, fmt.Errorf("invalid migration version in %q", entry.Name())
		}

		path := "migrations/" + entry.Name()
		contents, err := fs.ReadFile(migrationFiles, path)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", path, err)
		}

		sqlText := strings.TrimSpace(string(contents))
		if sqlText == "" {
			return nil, fmt.Errorf("migration %s is empty", path)
		}

		checksum := sha256.Sum256(contents)
		migrations = append(migrations, migration{
			version:  version,
			name:     entry.Name(),
			path:     path,
			sql:      sqlText,
			checksum: fmt.Sprintf("%x", checksum),
		})
	}

	sort.Slice(migrations, func(i, j int) bool {
		return migrations[i].version < migrations[j].version
	})

	for index := 1; index < len(migrations); index++ {
		if migrations[index-1].version == migrations[index].version {
			return nil, fmt.Errorf("duplicate migration version %d", migrations[index].version)
		}
	}

	return migrations, nil
}

func (database *Database) applyMigration(ctx context.Context, migration migration) error {
	tx, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin transaction: %w", err)
	}
	defer tx.Rollback()

	// Serialize startup migrations if more than one API instance starts at the
	// same time. The lock is held until this transaction commits or rolls back.
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock($1)`, schemaMigrationLockKey); err != nil {
		return fmt.Errorf("acquire migration lock: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version BIGINT PRIMARY KEY,
			name TEXT NOT NULL,
			checksum TEXT NOT NULL,
			applied_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
		)`); err != nil {
		return fmt.Errorf("create schema migrations table: %w", err)
	}

	var appliedName, appliedChecksum string
	err = tx.QueryRowContext(ctx, `
		SELECT name, checksum
		FROM schema_migrations
		WHERE version = $1`, migration.version).Scan(&appliedName, &appliedChecksum)
	switch err {
	case nil:
		if appliedName != migration.name || appliedChecksum != migration.checksum {
			return fmt.Errorf(
				"migration version %d was already applied as %s and does not match %s; restore the original file or create a new migration",
				migration.version,
				appliedName,
				migration.name,
			)
		}
		return tx.Commit()
	case sql.ErrNoRows:
		// This migration has not run yet.
	default:
		return fmt.Errorf("check migration history: %w", err)
	}

	if _, err := tx.ExecContext(ctx, migration.sql); err != nil {
		return fmt.Errorf("execute SQL: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO schema_migrations (version, name, checksum)
		VALUES ($1, $2, $3)`, migration.version, migration.name, migration.checksum); err != nil {
		return fmt.Errorf("record migration: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit transaction: %w", err)
	}

	return nil
}

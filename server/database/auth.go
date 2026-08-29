package database

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"

	"github.com/google/uuid"
)

var ErrInvalidAuthToken = errors.New("invalid auth token")

type DeviceRegistration struct {
	DeviceID  string
	AuthToken string
}

func (database *Database) RegisterDevice(ctx context.Context) (DeviceRegistration, error) {
	deviceUUID, err := uuid.NewRandom()
	if err != nil {
		return DeviceRegistration{}, fmt.Errorf("generate device uuid: %w", err)
	}

	rawToken := make([]byte, 32)
	if _, err := rand.Read(rawToken); err != nil {
		return DeviceRegistration{}, fmt.Errorf("generate device auth token: %w", err)
	}

	authToken := base64.RawURLEncoding.EncodeToString(rawToken)
	authTokenHash := sha256.Sum256([]byte(authToken))
	if _, err := database.db.ExecContext(ctx, `
		INSERT INTO devices (device_id, auth_token_hash)
		VALUES ($1, $2)`, deviceUUID.String(), authTokenHash[:]); err != nil {
		return DeviceRegistration{}, fmt.Errorf("insert device: %w", err)
	}

	return DeviceRegistration{
		DeviceID:  deviceUUID.String(),
		AuthToken: authToken,
	}, nil
}

func (database *Database) AuthenticateDevice(ctx context.Context, authToken string) (string, error) {
	if authToken == "" {
		return "", ErrInvalidAuthToken
	}

	authTokenHash := sha256.Sum256([]byte(authToken))
	var deviceID string
	err := database.db.QueryRowContext(ctx, `
		UPDATE devices
		SET last_seen_at = CURRENT_TIMESTAMP
		WHERE auth_token_hash = $1
		RETURNING device_id`, authTokenHash[:]).Scan(&deviceID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrInvalidAuthToken
	}
	if err != nil {
		return "", fmt.Errorf("authenticate device: %w", err)
	}

	return deviceID, nil
}

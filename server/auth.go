package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strings"

	"server/database"
)

type registerResponse struct {
	DeviceID  string `json:"device_id"`
	AuthToken string `json:"auth_token"`
	TokenType string `json:"token_type"`
}

type deviceResponse struct {
	DeviceID string `json:"device_id"`
}

func registerHandler(database *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		registration, err := database.RegisterDevice(request.Context())
		if err != nil {
			log.Printf("registering device failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "could not register device",
			})
			return
		}

		writeJSON(w, http.StatusCreated, registerResponse{
			DeviceID:  registration.DeviceID,
			AuthToken: registration.AuthToken,
			TokenType: "Bearer",
		})
	}
}

func deviceHandler(w http.ResponseWriter, request *http.Request) {
	deviceID, ok := deviceIDFromContext(request.Context())
	if !ok {
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": "authenticated device identity is missing",
		})
		return
	}

	writeJSON(w, http.StatusOK, deviceResponse{DeviceID: deviceID})
}

type deviceIDContextKey struct{}

func requireDeviceAuth(db *database.Database, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		authToken, ok := bearerToken(request.Header.Get("Authorization"))
		if !ok {
			writeUnauthorized(w)
			return
		}

		deviceID, err := db.AuthenticateDevice(request.Context(), authToken)
		if err != nil {
			if errors.Is(err, database.ErrInvalidAuthToken) {
				writeUnauthorized(w)
				return
			}

			log.Printf("authenticating device failed: %v", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{
				"error": "authentication service unavailable",
			})
			return
		}

		ctx := context.WithValue(request.Context(), deviceIDContextKey{}, deviceID)
		next.ServeHTTP(w, request.WithContext(ctx))
	})
}

func bearerToken(header string) (string, bool) {
	parts := strings.Fields(header)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") || len(parts[1]) > 1024 {
		return "", false
	}

	return parts[1], true
}

func writeUnauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	writeJSON(w, http.StatusUnauthorized, map[string]string{
		"error": "valid bearer authentication is required",
	})
}

func deviceIDFromContext(ctx context.Context) (string, bool) {
	deviceID, ok := ctx.Value(deviceIDContextKey{}).(string)
	return deviceID, ok
}

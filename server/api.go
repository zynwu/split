package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"server/database"
)

type createGroupRequest struct {
	Name string `json:"name"`
}

type joinGroupRequest struct {
	JoinCode string `json:"join_code"`
}

func rootHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{
		"message": "split api is running",
	})
}

func healthHandler(database *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		ctx, cancel := context.WithTimeout(request.Context(), 2*time.Second)
		defer cancel()

		if err := database.Ping(ctx); err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{
				"status": "unavailable",
			})
			return
		}

		writeJSON(w, http.StatusOK, map[string]string{
			"status": "ok",
		})
	}
}

func listGroupsHandler(database *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		deviceID, ok := deviceIDFromContext(request.Context())
		if !ok {
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "authenticated device identity is missing",
			})
			return
		}

		groups, err := database.ListGroupsForDevice(request.Context(), deviceID)
		if err != nil {
			log.Printf("listing groups failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "could not list groups",
			})
			return
		}

		writeJSON(w, http.StatusOK, map[string]any{
			"groups": groups,
		})
	}
}

func joinGroupHandler(db *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		var payload joinGroupRequest
		decoder := json.NewDecoder(io.LimitReader(request.Body, 1<<20))
		if err := decoder.Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "request body must be valid JSON with a join_code",
			})
			return
		}

		joinCode, ok := normalizeJoinCode(payload.JoinCode)
		if !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "join_code must be six letters",
			})
			return
		}

		deviceID, ok := deviceIDFromContext(request.Context())
		if !ok {
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "authenticated device identity is missing",
			})
			return
		}

		group, err := db.JoinGroup(request.Context(), deviceID, joinCode)
		if err != nil {
			if errors.Is(err, database.ErrGroupNotFound) {
				writeJSON(w, http.StatusNotFound, map[string]string{
					"error": "group not found",
				})
				return
			}

			log.Printf("joining group failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "could not join group",
			})
			return
		}

		writeJSON(w, http.StatusOK, group)
	}
}

func normalizeJoinCode(value string) (string, bool) {
	code := strings.ToUpper(strings.TrimSpace(value))
	if len(code) != 6 {
		return "", false
	}

	for _, character := range code {
		if !strings.ContainsRune("ABCDEFGHJKLMNPQRSTUVWXYZ", character) {
			return "", false
		}
	}

	return code, true
}

func createGroupHandler(database *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		var payload createGroupRequest
		decoder := json.NewDecoder(io.LimitReader(request.Body, 1<<20))
		if err := decoder.Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "request body must be valid JSON with a name",
			})
			return
		}

		name := strings.TrimSpace(payload.Name)
		if name == "" || len([]rune(name)) > 255 {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "name must be between 1 and 255 characters",
			})
			return
		}

		deviceID, ok := deviceIDFromContext(request.Context())
		if !ok {
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "authenticated device identity is missing",
			})
			return
		}

		group, err := database.CreateGroup(request.Context(), name, deviceID)
		if err != nil {
			log.Printf("creating group failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "could not create group",
			})
			return
		}

		writeJSON(w, http.StatusCreated, group)
	}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("writing JSON response failed: %v", err)
	}
}

package main

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"

	"server/database"

	"github.com/google/uuid"
)

type updateActorDisplayNameRequest struct {
	DisplayName string `json:"display_name"`
}

func updateActorDisplayNameHandler(db *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		groupUUID, ok := groupUUIDFromPath(request)
		if !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "group_uuid must be a valid UUID",
			})
			return
		}

		actorUUID := request.PathValue("actor_uuid")
		if _, err := uuid.Parse(actorUUID); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "actor_uuid must be a valid UUID",
			})
			return
		}

		var payload updateActorDisplayNameRequest
		decoder := json.NewDecoder(io.LimitReader(request.Body, 1<<20))
		if err := decoder.Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "request body must be valid JSON with a display_name",
			})
			return
		}
		if err := ensureRequestBodyEnded(decoder); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "request body must contain exactly one JSON object",
			})
			return
		}

		displayName, err := database.NormalizeDisplayName(payload.DisplayName)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": err.Error(),
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

		actor, err := db.UpdateActorDisplayName(request.Context(), groupUUID, actorUUID, deviceID, displayName)
		if err != nil {
			switch {
			case errors.Is(err, database.ErrGroupNotFound), errors.Is(err, database.ErrGroupMembershipDenied), errors.Is(err, database.ErrActorNotFound):
				writeJSON(w, http.StatusNotFound, map[string]string{
					"error": "group or actor not found",
				})
			case errors.Is(err, database.ErrInvalidDisplayName):
				writeJSON(w, http.StatusBadRequest, map[string]string{
					"error": err.Error(),
				})
			default:
				log.Printf("updating actor display name failed: %v", err)
				writeJSON(w, http.StatusInternalServerError, map[string]string{
					"error": "could not update actor display name",
				})
			}
			return
		}

		writeJSON(w, http.StatusOK, actor)
	}
}

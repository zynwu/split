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

		event, err := metadataEventInput(
			request,
			groupUUID,
			"actor",
			actorUUID,
			"actor.display_name_updated",
			database.ActorDisplayNameEventPayload{DisplayName: displayName},
		)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}

		deviceID, ok := deviceIDFromContext(request.Context())
		if !ok {
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "authenticated device identity is missing",
			})
			return
		}

		result, err := db.AppendLedgerEvent(request.Context(), deviceID, event)
		if err != nil {
			switch {
			case errors.Is(err, database.ErrInvalidExpensePayload):
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			case errors.Is(err, database.ErrGroupNotFound), errors.Is(err, database.ErrGroupMembershipDenied), errors.Is(err, database.ErrActorNotFound):
				writeJSON(w, http.StatusNotFound, map[string]string{
					"error": "group or actor not found",
				})
			default:
				log.Printf("updating actor display name failed: %v", err)
				writeJSON(w, http.StatusInternalServerError, map[string]string{
					"error": "could not update actor display name",
				})
			}
			return
		}
		if result.Actor == nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "actor metadata result is missing",
			})
			return
		}

		writeJSON(w, http.StatusOK, result.Actor)
	}
}

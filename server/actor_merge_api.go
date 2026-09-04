package main

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"time"

	"server/database"

	"github.com/google/uuid"
)

type commandeerActorRequest struct {
	EventUUID      string    `json:"event_uuid"`
	EventCreatedAt time.Time `json:"event_created_at"`
	ClientSequence int64     `json:"client_sequence"`
}

func commandeerActorHandler(db *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		groupUUID, ok := groupUUIDFromPath(request)
		if !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "group_uuid must be a valid UUID",
			})
			return
		}

		targetActorUUID := request.PathValue("actor_uuid")
		if _, err := uuid.Parse(targetActorUUID); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "actor_uuid must be a valid UUID",
			})
			return
		}

		var payload commandeerActorRequest
		decoder := json.NewDecoder(io.LimitReader(request.Body, 1<<20))
		if err := decoder.Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "request body must be valid JSON with event_uuid, event_created_at, and client_sequence",
			})
			return
		}
		if err := ensureRequestBodyEnded(decoder); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "request body must contain exactly one JSON object",
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

		result, err := db.CommandeerActor(
			request.Context(),
			groupUUID,
			targetActorUUID,
			deviceID,
			database.CommandeerActorInput{
				EventUUID:      payload.EventUUID,
				EventCreatedAt: payload.EventCreatedAt,
				ClientSequence: payload.ClientSequence,
			},
		)
		if err != nil {
			switch {
			case errors.Is(err, database.ErrInvalidActorMergeRequest):
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			case errors.Is(err, database.ErrGroupNotFound), errors.Is(err, database.ErrGroupMembershipDenied), errors.Is(err, database.ErrActorNotFound):
				writeJSON(w, http.StatusNotFound, map[string]string{
					"error": "group or actor not found",
				})
			case errors.Is(err, database.ErrActorDeviceMismatch):
				writeJSON(w, http.StatusForbidden, map[string]string{
					"error": "authenticated device is not bound to an active actor in this group",
				})
			case errors.Is(err, database.ErrActorMergeConflict), errors.Is(err, database.ErrLedgerEventConflict), errors.Is(err, database.ErrClientSequenceConflict):
				writeJSON(w, http.StatusConflict, map[string]string{
					"error": err.Error(),
				})
			default:
				log.Printf("commandeering actor failed: %v", err)
				writeJSON(w, http.StatusInternalServerError, map[string]string{
					"error": "could not commandeer actor",
				})
			}
			return
		}

		status := http.StatusCreated
		if result.Replayed {
			status = http.StatusOK
		}
		writeJSON(w, status, result)
	}
}

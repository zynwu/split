package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strconv"
	"time"

	"server/database"

	"github.com/google/uuid"
)

type ledgerEventRequest struct {
	EventUUID      string          `json:"event_uuid"`
	EntityType     string          `json:"entity_type"`
	EntityUUID     string          `json:"entity_uuid"`
	EventType      string          `json:"event_type"`
	ActorUUID      string          `json:"actor_uuid"`
	EventCreatedAt time.Time       `json:"event_created_at"`
	ClientSequence int64           `json:"client_sequence"`
	BaseSequence   int64           `json:"base_sequence"`
	PayloadVersion int             `json:"payload_version"`
	Payload        json.RawMessage `json:"payload"`
}

func appendLedgerEventHandler(db *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		groupUUID, ok := groupUUIDFromPath(request)
		if !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "group_uuid must be a valid UUID",
			})
			return
		}

		var payload ledgerEventRequest
		decoder := json.NewDecoder(io.LimitReader(request.Body, 1<<20))
		if err := decoder.Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "request body must be valid JSON with a ledger event",
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

		result, err := db.AppendLedgerEvent(request.Context(), deviceID, database.LedgerEventInput{
			EventUUID:      payload.EventUUID,
			GroupUUID:      groupUUID,
			EntityType:     payload.EntityType,
			EntityUUID:     payload.EntityUUID,
			EventType:      payload.EventType,
			ActorUUID:      payload.ActorUUID,
			EventCreatedAt: payload.EventCreatedAt,
			ClientSequence: payload.ClientSequence,
			BaseSequence:   payload.BaseSequence,
			PayloadVersion: payload.PayloadVersion,
			Payload:        payload.Payload,
		})
		if err != nil {
			writeLedgerEventError(w, err)
			return
		}

		status := http.StatusCreated
		if result.Replayed {
			status = http.StatusOK
		}
		writeJSON(w, status, result)
	}
}

func listExpensesHandler(db *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		groupUUID, ok := groupUUIDFromPath(request)
		if !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "group_uuid must be a valid UUID",
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

		expenses, err := db.ListExpensesForDevice(request.Context(), groupUUID, deviceID)
		if err != nil {
			if writeGroupAccessError(w, err) {
				return
			}
			log.Printf("listing expenses failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "could not list expenses",
			})
			return
		}

		writeJSON(w, http.StatusOK, map[string]any{
			"expenses": expenses,
		})
	}
}

func listLedgerEventsHandler(db *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		groupUUID, ok := groupUUIDFromPath(request)
		if !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "group_uuid must be a valid UUID",
			})
			return
		}

		after, err := queryInt64(request, "after", 0)
		if err != nil || after < 0 {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "after must be a non-negative integer",
			})
			return
		}
		limit, err := queryInt64(request, "limit", 100)
		if err != nil || limit < 1 || limit > 500 {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "limit must be between 1 and 500",
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

		page, err := db.ListLedgerEventsForDevice(request.Context(), groupUUID, deviceID, after, limit)
		if err != nil {
			if writeGroupAccessError(w, err) {
				return
			}
			log.Printf("listing ledger events failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "could not list ledger events",
			})
			return
		}

		writeJSON(w, http.StatusOK, page)
	}
}

func groupUUIDFromPath(request *http.Request) (string, bool) {
	parsed, err := uuid.Parse(request.PathValue("group_uuid"))
	if err != nil {
		return "", false
	}
	return parsed.String(), true
}

func ensureRequestBodyEnded(decoder *json.Decoder) error {
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		if err == nil {
			return fmt.Errorf("multiple JSON values")
		}
		return err
	}
	return nil
}

func queryInt64(request *http.Request, key string, fallback int64) (int64, error) {
	value := request.URL.Query().Get(key)
	if value == "" {
		return fallback, nil
	}
	return strconv.ParseInt(value, 10, 64)
}

func writeLedgerEventError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, database.ErrGroupNotFound), errors.Is(err, database.ErrGroupMembershipDenied), errors.Is(err, database.ErrActorNotFound), errors.Is(err, database.ErrExpenseNotFound):
		writeJSON(w, http.StatusNotFound, map[string]string{
			"error": "group or actor not found",
		})
	case errors.Is(err, database.ErrLedgerEventConflict), errors.Is(err, database.ErrClientSequenceConflict):
		writeJSON(w, http.StatusConflict, map[string]string{
			"error": "ledger event conflicts with an existing event",
		})
	case errors.Is(err, database.ErrInvalidExpensePayload), errors.Is(err, database.ErrUnsupportedEvent):
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": err.Error(),
		})
	default:
		log.Printf("appending ledger event failed: %v", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": "could not append ledger event",
		})
	}
}

func writeGroupAccessError(w http.ResponseWriter, err error) bool {
	if !errors.Is(err, database.ErrGroupMembershipDenied) && !errors.Is(err, database.ErrGroupNotFound) {
		return false
	}
	writeJSON(w, http.StatusNotFound, map[string]string{
		"error": "group not found",
	})
	return true
}

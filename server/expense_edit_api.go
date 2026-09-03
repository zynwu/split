package main

import (
	"encoding/json"
	"io"
	"net/http"
	"time"

	"server/database"

	"github.com/google/uuid"
)

// expenseEditRequest keeps the event metadata at the top level while nesting
// the complete replacement expense payload. This makes PUT retryable without
// creating a second mutation path outside the ledger.
type expenseEditRequest struct {
	EventUUID      string                       `json:"event_uuid"`
	ActorUUID      string                       `json:"actor_uuid"`
	EventCreatedAt time.Time                    `json:"event_created_at"`
	ClientSequence int64                        `json:"client_sequence"`
	BaseSequence   int64                        `json:"base_sequence"`
	PayloadVersion int                          `json:"payload_version"`
	Payload        database.ExpenseEventPayload `json:"payload"`
}

func updateExpenseHandler(db *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		groupUUID, ok := groupUUIDFromPath(request)
		if !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "group_uuid must be a valid UUID",
			})
			return
		}

		expenseUUID, err := uuid.Parse(request.PathValue("expense_uuid"))
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "expense_uuid must be a valid UUID",
			})
			return
		}

		var payload expenseEditRequest
		decoder := json.NewDecoder(io.LimitReader(request.Body, 1<<20))
		if err := decoder.Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "request body must be valid JSON with an expense edit",
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

		encodedPayload, err := json.Marshal(payload.Payload)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "expense payload must be valid JSON",
			})
			return
		}

		result, err := db.AppendLedgerEvent(request.Context(), deviceID, database.LedgerEventInput{
			EventUUID:      payload.EventUUID,
			GroupUUID:      groupUUID,
			EntityType:     "expense",
			EntityUUID:     expenseUUID.String(),
			EventType:      "expense.updated",
			ActorUUID:      payload.ActorUUID,
			EventCreatedAt: payload.EventCreatedAt,
			ClientSequence: payload.ClientSequence,
			BaseSequence:   payload.BaseSequence,
			PayloadVersion: payload.PayloadVersion,
			Payload:        encodedPayload,
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

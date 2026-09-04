package main

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"

	"server/database"
)

type updateGroupNameRequest struct {
	Name string `json:"name"`
}

func updateGroupNameHandler(db *database.Database) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		groupUUID, ok := groupUUIDFromPath(request)
		if !ok {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "group_uuid must be a valid UUID",
			})
			return
		}

		var payload updateGroupNameRequest
		decoder := json.NewDecoder(io.LimitReader(request.Body, 1<<20))
		if err := decoder.Decode(&payload); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "request body must be valid JSON with a name",
			})
			return
		}
		if err := ensureRequestBodyEnded(decoder); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": "request body must contain exactly one JSON object",
			})
			return
		}

		name, err := database.NormalizeGroupName(payload.Name)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{
				"error": err.Error(),
			})
			return
		}

		event, err := metadataEventInput(
			request,
			groupUUID,
			"group",
			groupUUID,
			"group.name_updated",
			database.GroupNameEventPayload{Name: name},
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
			if errors.Is(err, database.ErrInvalidExpensePayload) {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
				return
			}
			if writeGroupAccessError(w, err) {
				return
			}
			log.Printf("updating group name failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "could not update group name",
			})
			return
		}
		if result.Group == nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "group metadata result is missing",
			})
			return
		}

		writeJSON(w, http.StatusOK, result.Group)
	}
}

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

		deviceID, ok := deviceIDFromContext(request.Context())
		if !ok {
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "authenticated device identity is missing",
			})
			return
		}

		group, err := db.UpdateGroupName(request.Context(), groupUUID, deviceID, name)
		if err != nil {
			switch {
			case errors.Is(err, database.ErrGroupNotFound), errors.Is(err, database.ErrGroupMembershipDenied):
				writeJSON(w, http.StatusNotFound, map[string]string{
					"error": "group not found",
				})
			case errors.Is(err, database.ErrInvalidGroupName):
				writeJSON(w, http.StatusBadRequest, map[string]string{
					"error": err.Error(),
				})
			default:
				log.Printf("updating group name failed: %v", err)
				writeJSON(w, http.StatusInternalServerError, map[string]string{
					"error": "could not update group name",
				})
			}
			return
		}

		writeJSON(w, http.StatusOK, group)
	}
}

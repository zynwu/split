package main

import (
	"log"
	"net/http"

	"server/database"
)

func listPaymentsHandler(db *database.Database) http.HandlerFunc {
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

		payments, err := db.ListPaymentsForDevice(request.Context(), groupUUID, deviceID)
		if err != nil {
			if writeGroupAccessError(w, err) {
				return
			}
			log.Printf("listing payments failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "could not list payments",
			})
			return
		}

		writeJSON(w, http.StatusOK, map[string]any{
			"payments": payments,
		})
	}
}

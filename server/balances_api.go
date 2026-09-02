package main

import (
	"log"
	"net/http"

	"server/database"
)

func listGroupBalancesHandler(db *database.Database) http.HandlerFunc {
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

		balances, err := db.GetGroupBalancesForDevice(request.Context(), groupUUID, deviceID)
		if err != nil {
			if writeGroupAccessError(w, err) {
				return
			}
			log.Printf("listing group balances failed: %v", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{
				"error": "could not calculate group balances",
			})
			return
		}

		writeJSON(w, http.StatusOK, balances)
	}
}

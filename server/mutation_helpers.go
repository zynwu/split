package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"server/database"

	"github.com/google/uuid"
)

// metadataEventInput adapts the legacy PATCH endpoints to the same ledger
// path used by the offline outbox. Idempotency-Key is a UUID because the
// ledger uses event_uuid as its durable replay key. When it is omitted, the
// request remains compatible with older clients but each request is a new
// mutation.
func metadataEventInput(
	request *http.Request,
	groupUUID string,
	entityType string,
	entityUUID string,
	eventType string,
	payload any,
) (database.LedgerEventInput, error) {
	eventUUID := strings.TrimSpace(request.Header.Get("Idempotency-Key"))
	if eventUUID == "" {
		eventUUID = uuid.New().String()
	} else if _, err := uuid.Parse(eventUUID); err != nil {
		return database.LedgerEventInput{}, fmt.Errorf("Idempotency-Key must be a valid UUID")
	} else {
		eventUUID = uuid.MustParse(eventUUID).String()
	}

	encodedPayload, err := json.Marshal(payload)
	if err != nil {
		return database.LedgerEventInput{}, fmt.Errorf("encode metadata event payload: %w", err)
	}

	return database.LedgerEventInput{
		EventUUID:          eventUUID,
		GroupUUID:          groupUUID,
		EntityType:         entityType,
		EntityUUID:         entityUUID,
		EventType:          eventType,
		EventCreatedAt:     time.Time{},
		ClientSequence:     0,
		BaseSequence:       0,
		PayloadVersion:     1,
		Payload:            encodedPayload,
		AutoActorUUID:      true,
		AutoEventCreatedAt: true,
		AutoClientSequence: true,
		AutoBaseSequence:   true,
	}, nil
}

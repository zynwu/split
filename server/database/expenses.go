package database

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
)

var (
	ErrGroupMembershipDenied  = errors.New("device is not a member of the group")
	ErrActorNotFound          = errors.New("actor not found in group")
	ErrActorDeviceMismatch    = errors.New("event actor is not bound to the authenticated device")
	ErrLedgerEventConflict    = errors.New("ledger event conflicts with an existing event")
	ErrClientSequenceConflict = errors.New("client sequence conflicts with an existing event")
	ErrUnsupportedEvent       = errors.New("unsupported ledger event")
	ErrInvalidExpensePayload  = errors.New("invalid expense payload")
	ErrExpenseNotFound        = errors.New("expense not found")
)

type ExpenseSplit struct {
	ActorUUID        string `json:"actor_uuid"`
	AmountMinorUnits int64  `json:"amount_minor_units"`
}

type Expense struct {
	UUID                string          `json:"uuid"`
	GroupUUID           string          `json:"group_uuid"`
	CreatedByActorUUID  string          `json:"created_by_actor_uuid"`
	PayerActorUUID      string          `json:"payer_actor_uuid"`
	Name                string          `json:"name"`
	Description         string          `json:"description"`
	CurrencyCode        string          `json:"currency_code"`
	TotalMinorUnits     int64           `json:"total_minor_units"`
	SplitMethod         string          `json:"split_method"`
	SplitConfig         json.RawMessage `json:"split_config"`
	OccurredAt          time.Time       `json:"occurred_at"`
	CreatedAt           time.Time       `json:"created_at"`
	UpdatedAt           time.Time       `json:"updated_at"`
	LatestEventSequence int64           `json:"version"`
	VoidedAt            *time.Time      `json:"voided_at,omitempty"`
	Splits              []ExpenseSplit  `json:"splits"`
}

type ExpenseEventPayload struct {
	Name            string          `json:"name"`
	Description     string          `json:"description"`
	CurrencyCode    string          `json:"currency_code"`
	TotalMinorUnits int64           `json:"total_minor_units"`
	PayerActorUUID  string          `json:"payer_actor_uuid"`
	SplitMethod     string          `json:"split_method"`
	SplitConfig     json.RawMessage `json:"split_config"`
	OccurredAt      time.Time       `json:"occurred_at"`
	Splits          []ExpenseSplit  `json:"splits"`
}

type GroupNameEventPayload struct {
	Name string `json:"name"`
}

type ActorDisplayNameEventPayload struct {
	DisplayName string `json:"display_name"`
}

type LedgerEventInput struct {
	EventUUID          string
	GroupUUID          string
	EntityType         string
	EntityUUID         string
	EventType          string
	ActorUUID          string
	EventCreatedAt     time.Time
	ClientSequence     int64
	BaseSequence       int64
	PayloadVersion     int
	Payload            json.RawMessage
	AutoActorUUID      bool
	AutoEventCreatedAt bool
	AutoClientSequence bool
	AutoBaseSequence   bool
}

type LedgerEvent struct {
	EventUUID      string          `json:"event_uuid"`
	GroupUUID      string          `json:"group_uuid"`
	Sequence       int64           `json:"sequence"`
	EntityType     string          `json:"entity_type"`
	EntityUUID     string          `json:"entity_uuid"`
	EventType      string          `json:"event_type"`
	ActorUUID      string          `json:"actor_uuid"`
	EventCreatedAt time.Time       `json:"event_created_at"`
	DeviceID       string          `json:"device_id"`
	ClientSequence int64           `json:"client_sequence"`
	BaseSequence   int64           `json:"base_sequence"`
	HadConflict    bool            `json:"had_conflict"`
	PayloadVersion int             `json:"payload_version"`
	Payload        json.RawMessage `json:"payload"`
	RecordedAt     time.Time       `json:"recorded_at"`
	PayloadHash    []byte          `json:"-"`
}

type AppendLedgerEventResult struct {
	Event    LedgerEvent `json:"event"`
	Expense  *Expense    `json:"expense,omitempty"`
	Payment  *Payment    `json:"payment,omitempty"`
	Group    *Group      `json:"group,omitempty"`
	Actor    *GroupActor `json:"actor,omitempty"`
	Applied  bool        `json:"applied"`
	Conflict bool        `json:"conflict"`
	Replayed bool        `json:"replayed"`
}

type LedgerEventPage struct {
	Events     []LedgerEvent `json:"events"`
	NextCursor int64         `json:"next_cursor"`
	HasMore    bool          `json:"has_more"`
}

type sqlQueryer interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

type normalizedLedgerEvent struct {
	input                   LedgerEventInput
	expensePayload          *ExpenseEventPayload
	paymentPayload          *PaymentEventPayload
	groupNamePayload        *GroupNameEventPayload
	actorDisplayNamePayload *ActorDisplayNameEventPayload
}

func (database *Database) AppendLedgerEvent(ctx context.Context, deviceID string, input LedgerEventInput) (AppendLedgerEventResult, error) {
	normalized, err := normalizeLedgerEvent(input)
	if err != nil {
		return AppendLedgerEventResult{}, err
	}

	eventHash := sha256.Sum256(normalized.input.Payload)
	tx, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("begin ledger event transaction: %w", err)
	}
	defer tx.Rollback()

	var currentGroupSequence int64
	var group Group
	err = tx.QueryRowContext(ctx, `
		SELECT uuid, name, creation_date, join_code, latest_event_sequence,
			latest_metadata_event_sequence
		FROM groups
		WHERE uuid = $1
		FOR UPDATE`, normalized.input.GroupUUID).Scan(
		&group.UUID,
		&group.Name,
		&group.CreationDate,
		&group.JoinCode,
		&group.LatestEventSequence,
		&group.LatestMetadataEventSequence,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return AppendLedgerEventResult{}, ErrGroupNotFound
	}
	if err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("lock group for ledger event: %w", err)
	}
	currentGroupSequence = group.LatestEventSequence
	if normalized.input.AutoActorUUID {
		normalized.input.ActorUUID, err = activeActorUUIDForDeviceTx(ctx, tx, normalized.input.GroupUUID, deviceID)
		if err != nil {
			return AppendLedgerEventResult{}, err
		}
	}
	if normalized.input.AutoEventCreatedAt {
		normalized.input.EventCreatedAt = time.Now().UTC().Truncate(time.Microsecond)
	}

	member, err := activeGroupMembershipTx(ctx, tx, normalized.input.GroupUUID, deviceID)
	if err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("check group membership: %w", err)
	}
	if !member {
		return AppendLedgerEventResult{}, ErrGroupMembershipDenied
	}

	actorExists, err := activeActorTx(ctx, tx, normalized.input.GroupUUID, normalized.input.ActorUUID)
	if err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("check event actor: %w", err)
	}
	if !actorExists {
		return AppendLedgerEventResult{}, ErrActorNotFound
	}

	actorBound, err := activeActorDeviceBindingTx(ctx, tx, normalized.input.GroupUUID, normalized.input.ActorUUID, deviceID)
	if err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("check event actor device binding: %w", err)
	}
	if !actorBound {
		return AppendLedgerEventResult{}, ErrActorDeviceMismatch
	}

	existingEvent, err := findLedgerEventByUUIDTx(ctx, tx, normalized.input.EventUUID)
	if err == nil {
		if normalized.input.AutoActorUUID {
			normalized.input.ActorUUID = existingEvent.ActorUUID
		}
		if normalized.input.AutoEventCreatedAt {
			normalized.input.EventCreatedAt = existingEvent.EventCreatedAt
		}
		if normalized.input.AutoClientSequence {
			normalized.input.ClientSequence = existingEvent.ClientSequence
		}
		if normalized.input.AutoBaseSequence {
			normalized.input.BaseSequence = existingEvent.BaseSequence
		}
		if !ledgerEventsEqual(existingEvent, normalized.input, deviceID, eventHash[:]) {
			return AppendLedgerEventResult{}, ErrLedgerEventConflict
		}
		return replayLedgerEventTx(ctx, tx, existingEvent)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return AppendLedgerEventResult{}, fmt.Errorf("check duplicate ledger event: %w", err)
	}

	if normalized.input.AutoClientSequence {
		normalized.input.ClientSequence, err = nextClientSequenceTx(ctx, tx, deviceID)
		if err != nil {
			return AppendLedgerEventResult{}, err
		}
	}

	existingSequenceEvent, err := findLedgerEventByClientSequenceTx(ctx, tx, deviceID, normalized.input.ClientSequence)
	if err == nil {
		return AppendLedgerEventResult{}, fmt.Errorf("%w: %s", ErrClientSequenceConflict, existingSequenceEvent.EventUUID)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return AppendLedgerEventResult{}, fmt.Errorf("check client sequence: %w", err)
	}

	currentSequence := int64(0)
	currentEvent := ledgerEventVersion{}
	currentExpenseExists := false
	var currentExpense Expense

	switch normalized.input.EntityType {
	case "expense":
		currentExpense, err = loadExpenseTx(ctx, tx, normalized.input.GroupUUID, normalized.input.EntityUUID)
		if err != nil && !errors.Is(err, ErrExpenseNotFound) {
			return AppendLedgerEventResult{}, err
		}
		currentExpenseExists = err == nil
		if currentExpenseExists {
			currentSequence = currentExpense.LatestEventSequence
		}
		if normalized.expensePayload != nil {
			if err := validateExpenseActorsTx(ctx, tx, normalized.input.GroupUUID, normalized.expensePayload); err != nil {
				return AppendLedgerEventResult{}, err
			}
		}
		if normalized.input.EventType == "expense.updated" && !currentExpenseExists {
			return AppendLedgerEventResult{}, ErrExpenseNotFound
		}
		if (normalized.input.EventType == "expense.voided" || normalized.input.EventType == "expense.deleted") && !currentExpenseExists {
			return AppendLedgerEventResult{}, ErrExpenseNotFound
		}
	case "payment":
		currentPayment, paymentErr := loadPaymentTx(ctx, tx, normalized.input.GroupUUID, normalized.input.EntityUUID)
		currentPaymentExists := paymentErr == nil
		if paymentErr != nil && !errors.Is(paymentErr, ErrPaymentNotFound) {
			return AppendLedgerEventResult{}, paymentErr
		}
		if currentPaymentExists {
			currentSequence = currentPayment.LatestEventSequence
		}
		if normalized.paymentPayload != nil {
			if err := validatePaymentActorsTx(ctx, tx, normalized.input.GroupUUID, normalized.paymentPayload); err != nil {
				return AppendLedgerEventResult{}, err
			}
		}
		if normalized.input.EventType == "payment.updated" && !currentPaymentExists {
			return AppendLedgerEventResult{}, ErrPaymentNotFound
		}
		if (normalized.input.EventType == "payment.voided" || normalized.input.EventType == "payment.deleted") && !currentPaymentExists {
			return AppendLedgerEventResult{}, ErrPaymentNotFound
		}
	case "group":
		currentSequence = group.LatestMetadataEventSequence
	case "actor":
		if normalized.input.EntityUUID == "" {
			return AppendLedgerEventResult{}, ErrActorNotFound
		}
		actor, actorErr := loadActorTx(ctx, tx, normalized.input.GroupUUID, normalized.input.EntityUUID)
		if actorErr != nil {
			return AppendLedgerEventResult{}, actorErr
		}
		currentSequence = actor.LatestMetadataEventSequence
	}

	if currentSequence > 0 {
		currentEvent, err = findLedgerEventVersionBySequenceTx(ctx, tx, normalized.input.GroupUUID, currentSequence)
		if err != nil {
			return AppendLedgerEventResult{}, fmt.Errorf("load current entity event: %w", err)
		}
	}
	if normalized.input.AutoBaseSequence {
		normalized.input.BaseSequence = currentSequence
	}

	winningEvent := currentSequence == 0 || eventVersionWins(
		normalized.input.EventCreatedAt,
		normalized.input.EventUUID,
		currentEvent.EventCreatedAt,
		currentEvent.EventUUID,
	)
	hadConflict := normalized.input.BaseSequence != currentSequence || (currentSequence > 0 && !winningEvent)
	nextSequence := currentGroupSequence + 1
	recordedAt := time.Now().UTC()

	var event LedgerEvent
	inserted, err := insertLedgerEventTx(ctx, tx, normalized.input, deviceID, nextSequence, hadConflict, eventHash[:], recordedAt, &event)
	if err != nil {
		return AppendLedgerEventResult{}, err
	}
	if !inserted {
		existingEvent, lookupErr := findLedgerEventByUUIDTx(ctx, tx, normalized.input.EventUUID)
		if lookupErr == nil {
			if normalized.input.AutoActorUUID {
				normalized.input.ActorUUID = existingEvent.ActorUUID
			}
			if normalized.input.AutoEventCreatedAt {
				normalized.input.EventCreatedAt = existingEvent.EventCreatedAt
			}
			if normalized.input.AutoClientSequence {
				normalized.input.ClientSequence = existingEvent.ClientSequence
			}
			if normalized.input.AutoBaseSequence {
				normalized.input.BaseSequence = existingEvent.BaseSequence
			}
			if !ledgerEventsEqual(existingEvent, normalized.input, deviceID, eventHash[:]) {
				return AppendLedgerEventResult{}, ErrLedgerEventConflict
			}
			return replayLedgerEventTx(ctx, tx, existingEvent)
		}
		if !errors.Is(lookupErr, sql.ErrNoRows) {
			return AppendLedgerEventResult{}, fmt.Errorf("check concurrent ledger event: %w", lookupErr)
		}

		existingSequenceEvent, lookupErr := findLedgerEventByClientSequenceTx(ctx, tx, deviceID, normalized.input.ClientSequence)
		if lookupErr == nil {
			return AppendLedgerEventResult{}, fmt.Errorf("%w: %s", ErrClientSequenceConflict, existingSequenceEvent.EventUUID)
		}
		if !errors.Is(lookupErr, sql.ErrNoRows) {
			return AppendLedgerEventResult{}, fmt.Errorf("check concurrent client sequence: %w", lookupErr)
		}
		return AppendLedgerEventResult{}, fmt.Errorf("insert ledger event was skipped without a duplicate")
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE groups
		SET latest_event_sequence = $2
		WHERE uuid = $1`, normalized.input.GroupUUID, nextSequence); err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("advance group ledger sequence: %w", err)
	}

	result := AppendLedgerEventResult{
		Event:    event,
		Applied:  winningEvent,
		Conflict: hadConflict,
	}
	switch normalized.input.EntityType {
	case "expense":
		switch normalized.input.EventType {
		case "expense.upsert", "expense.created", "expense.updated":
			if winningEvent {
				if err := applyExpenseUpsertTx(ctx, tx, event, *normalized.expensePayload); err != nil {
					return AppendLedgerEventResult{}, err
				}
			}
		case "expense.voided", "expense.deleted":
			if winningEvent {
				if err := applyExpenseVoidedTx(ctx, tx, event); err != nil {
					return AppendLedgerEventResult{}, err
				}
			}
		}
		current, err := loadExpenseTx(ctx, tx, normalized.input.GroupUUID, normalized.input.EntityUUID)
		if err != nil {
			return AppendLedgerEventResult{}, err
		}
		result.Expense = &current
	case "payment":
		switch normalized.input.EventType {
		case "payment.upsert", "payment.created", "payment.updated":
			if winningEvent {
				if err := applyPaymentUpsertTx(ctx, tx, event, *normalized.paymentPayload); err != nil {
					return AppendLedgerEventResult{}, err
				}
			}
		case "payment.voided", "payment.deleted":
			if winningEvent {
				if err := applyPaymentVoidedTx(ctx, tx, event); err != nil {
					return AppendLedgerEventResult{}, err
				}
			}
		}
		current, err := loadPaymentTx(ctx, tx, normalized.input.GroupUUID, normalized.input.EntityUUID)
		if err != nil {
			return AppendLedgerEventResult{}, err
		}
		result.Payment = &current
	case "group":
		if winningEvent {
			if err := applyGroupNameTx(ctx, tx, event, *normalized.groupNamePayload); err != nil {
				return AppendLedgerEventResult{}, err
			}
		}
		current, err := loadGroupTx(ctx, tx, normalized.input.GroupUUID)
		if err != nil {
			return AppendLedgerEventResult{}, err
		}
		result.Group = &current
	case "actor":
		if winningEvent {
			if err := applyActorDisplayNameTx(ctx, tx, event, *normalized.actorDisplayNamePayload); err != nil {
				return AppendLedgerEventResult{}, err
			}
		}
		current, err := loadActorTx(ctx, tx, normalized.input.GroupUUID, normalized.input.EntityUUID)
		if err != nil {
			return AppendLedgerEventResult{}, err
		}
		result.Actor = &current
	}

	if err := tx.Commit(); err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("commit ledger event transaction: %w", err)
	}

	return result, nil
}

func insertLedgerEventTx(
	ctx context.Context,
	tx *sql.Tx,
	input LedgerEventInput,
	deviceID string,
	sequence int64,
	hadConflict bool,
	payloadHash []byte,
	recordedAt time.Time,
	event *LedgerEvent,
) (bool, error) {
	err := scanLedgerEvent(tx.QueryRowContext(ctx, `
		INSERT INTO ledger_events (
			event_uuid, group_uuid, sequence, entity_type, entity_uuid,
			event_type, actor_uuid, device_id, client_sequence, base_sequence,
			event_created_at, had_conflict, payload_version, payload_hash, payload, recorded_at
		)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
		ON CONFLICT DO NOTHING
		RETURNING event_uuid, group_uuid, sequence, entity_type, entity_uuid,
			event_type, actor_uuid, device_id, client_sequence, base_sequence,
			event_created_at, had_conflict, payload_version, payload_hash, payload, recorded_at`,
		input.EventUUID,
		input.GroupUUID,
		sequence,
		input.EntityType,
		input.EntityUUID,
		input.EventType,
		input.ActorUUID,
		deviceID,
		input.ClientSequence,
		input.BaseSequence,
		input.EventCreatedAt,
		hadConflict,
		input.PayloadVersion,
		payloadHash,
		input.Payload,
		recordedAt,
	), event)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("insert ledger event: %w", err)
	}
	event.PayloadHash = append([]byte(nil), payloadHash...)
	return true, nil
}

func replayLedgerEventTx(ctx context.Context, tx *sql.Tx, event LedgerEvent) (AppendLedgerEventResult, error) {
	result := AppendLedgerEventResult{
		Event:    event,
		Conflict: event.HadConflict,
		Replayed: true,
	}

	switch event.EntityType {
	case "expense":
		expense, err := loadExpenseTx(ctx, tx, event.GroupUUID, event.EntityUUID)
		if err != nil {
			return AppendLedgerEventResult{}, err
		}
		result.Expense = &expense
		result.Applied = expense.LatestEventSequence == event.Sequence
	case "payment":
		payment, err := loadPaymentTx(ctx, tx, event.GroupUUID, event.EntityUUID)
		if err != nil {
			return AppendLedgerEventResult{}, err
		}
		result.Payment = &payment
		result.Applied = payment.LatestEventSequence == event.Sequence
	case "group":
		group, err := loadGroupTx(ctx, tx, event.GroupUUID)
		if err != nil {
			return AppendLedgerEventResult{}, err
		}
		result.Group = &group
		result.Applied = group.LatestMetadataEventSequence == event.Sequence
	case "actor":
		actor, err := loadActorTx(ctx, tx, event.GroupUUID, event.EntityUUID)
		if err != nil {
			return AppendLedgerEventResult{}, err
		}
		result.Actor = &actor
		result.Applied = actor.LatestMetadataEventSequence == event.Sequence
	}

	return result, nil
}

func (database *Database) ListExpensesForDevice(ctx context.Context, groupUUID, deviceID string) ([]Expense, error) {
	groupUUID, err := normalizeUUID(groupUUID, "group_uuid")
	if err != nil {
		return nil, err
	}

	member, err := activeGroupMembership(ctx, database.db, groupUUID, deviceID)
	if err != nil {
		return nil, fmt.Errorf("check group membership: %w", err)
	}
	if !member {
		return nil, ErrGroupMembershipDenied
	}

	const query = `
		SELECT e.expense_uuid, e.group_uuid, e.created_by_actor_uuid,
			e.payer_actor_uuid, e.name, e.description, e.currency_code,
			e.total_minor_units, e.split_method, e.split_config,
			e.occurred_at, e.created_at, e.updated_at,
			e.latest_event_sequence, e.voided_at,
			COALESCE(
				jsonb_agg(
					jsonb_build_object(
						'actor_uuid', s.actor_uuid,
						'amount_minor_units', s.amount_minor_units
					)
					ORDER BY s.actor_uuid
				) FILTER (WHERE s.actor_uuid IS NOT NULL),
				'[]'::jsonb
			) AS splits
		FROM expenses AS e
		LEFT JOIN expense_splits AS s
			ON s.group_uuid = e.group_uuid
			AND s.expense_uuid = e.expense_uuid
		WHERE e.group_uuid = $1
		GROUP BY e.expense_uuid, e.group_uuid, e.created_by_actor_uuid,
			e.payer_actor_uuid, e.name, e.description, e.currency_code,
			e.total_minor_units, e.split_method, e.split_config,
			e.occurred_at, e.created_at, e.updated_at,
			e.latest_event_sequence, e.voided_at
		ORDER BY e.occurred_at, e.expense_uuid`

	rows, err := database.db.QueryContext(ctx, query, groupUUID)
	if err != nil {
		return nil, fmt.Errorf("query expenses: %w", err)
	}
	defer rows.Close()

	expenses := make([]Expense, 0)
	for rows.Next() {
		var expense Expense
		var splitConfig, splitJSON []byte
		var voidedAt sql.NullTime
		if err := rows.Scan(
			&expense.UUID,
			&expense.GroupUUID,
			&expense.CreatedByActorUUID,
			&expense.PayerActorUUID,
			&expense.Name,
			&expense.Description,
			&expense.CurrencyCode,
			&expense.TotalMinorUnits,
			&expense.SplitMethod,
			&splitConfig,
			&expense.OccurredAt,
			&expense.CreatedAt,
			&expense.UpdatedAt,
			&expense.LatestEventSequence,
			&voidedAt,
			&splitJSON,
		); err != nil {
			return nil, fmt.Errorf("scan expense: %w", err)
		}

		expense.SplitConfig = append(json.RawMessage(nil), splitConfig...)
		expense.Splits = make([]ExpenseSplit, 0)
		if err := json.Unmarshal(splitJSON, &expense.Splits); err != nil {
			return nil, fmt.Errorf("decode expense splits: %w", err)
		}
		if voidedAt.Valid {
			expense.VoidedAt = &voidedAt.Time
		}
		expenses = append(expenses, expense)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate expenses: %w", err)
	}

	return expenses, nil
}

func (database *Database) ListLedgerEventsForDevice(ctx context.Context, groupUUID, deviceID string, after, limit int64) (LedgerEventPage, error) {
	groupUUID, err := normalizeUUID(groupUUID, "group_uuid")
	if err != nil {
		return LedgerEventPage{}, err
	}
	if after < 0 {
		return LedgerEventPage{}, fmt.Errorf("after cursor must be non-negative")
	}
	if limit < 1 || limit > 500 {
		return LedgerEventPage{}, fmt.Errorf("limit must be between 1 and 500")
	}

	tx, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return LedgerEventPage{}, fmt.Errorf("begin ledger event read transaction: %w", err)
	}
	defer tx.Rollback()

	member, err := activeGroupMembershipTx(ctx, tx, groupUUID, deviceID)
	if err != nil {
		return LedgerEventPage{}, fmt.Errorf("check group membership: %w", err)
	}
	if !member {
		return LedgerEventPage{}, ErrGroupMembershipDenied
	}

	var watermark int64
	if err := tx.QueryRowContext(ctx, `
		SELECT latest_event_sequence
		FROM groups
		WHERE uuid = $1`, groupUUID).Scan(&watermark); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return LedgerEventPage{}, ErrGroupNotFound
		}
		return LedgerEventPage{}, fmt.Errorf("read group ledger cursor: %w", err)
	}

	rows, err := tx.QueryContext(ctx, `
		SELECT event_uuid, group_uuid, sequence, entity_type, entity_uuid,
			event_type, actor_uuid, device_id, client_sequence, base_sequence,
			event_created_at, had_conflict, payload_version, payload_hash, payload, recorded_at
		FROM ledger_events
		WHERE group_uuid = $1
			AND sequence > $2
		ORDER BY sequence
		LIMIT $3`, groupUUID, after, limit+1)
	if err != nil {
		return LedgerEventPage{}, fmt.Errorf("query ledger events: %w", err)
	}
	defer rows.Close()

	events := make([]LedgerEvent, 0)
	for rows.Next() {
		var event LedgerEvent
		if err := scanLedgerEvent(rows, &event); err != nil {
			return LedgerEventPage{}, fmt.Errorf("scan ledger event: %w", err)
		}
		events = append(events, event)
	}
	if err := rows.Err(); err != nil {
		return LedgerEventPage{}, fmt.Errorf("iterate ledger events: %w", err)
	}

	hasMore := int64(len(events)) > limit
	if hasMore {
		events = events[:limit]
	}
	nextCursor := after
	if len(events) > 0 {
		nextCursor = events[len(events)-1].Sequence
	} else if watermark > nextCursor {
		nextCursor = watermark
	}

	if err := tx.Commit(); err != nil {
		return LedgerEventPage{}, fmt.Errorf("commit ledger event read transaction: %w", err)
	}

	return LedgerEventPage{
		Events:     events,
		NextCursor: nextCursor,
		HasMore:    hasMore,
	}, nil
}

func normalizeLedgerEvent(input LedgerEventInput) (normalizedLedgerEvent, error) {
	var err error
	input.EventUUID, err = normalizeUUID(input.EventUUID, "event_uuid")
	if err != nil {
		return normalizedLedgerEvent{}, fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
	}
	input.GroupUUID, err = normalizeUUID(input.GroupUUID, "group_uuid")
	if err != nil {
		return normalizedLedgerEvent{}, fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
	}
	input.EntityUUID, err = normalizeUUID(input.EntityUUID, "entity_uuid")
	if err != nil {
		return normalizedLedgerEvent{}, fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
	}
	if !(input.AutoActorUUID && strings.TrimSpace(input.ActorUUID) == "") {
		input.ActorUUID, err = normalizeUUID(input.ActorUUID, "actor_uuid")
		if err != nil {
			return normalizedLedgerEvent{}, fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
		}
	}
	if input.EventCreatedAt.IsZero() && !input.AutoEventCreatedAt {
		return normalizedLedgerEvent{}, fmt.Errorf("%w: event_created_at is required", ErrInvalidExpensePayload)
	}
	if !input.EventCreatedAt.IsZero() {
		input.EventCreatedAt = input.EventCreatedAt.UTC().Truncate(time.Microsecond)
	}
	input.EntityType = strings.ToLower(strings.TrimSpace(input.EntityType))
	if input.EntityType != "expense" && input.EntityType != "payment" && input.EntityType != "group" && input.EntityType != "actor" {
		return normalizedLedgerEvent{}, fmt.Errorf("%w: entity_type %q", ErrUnsupportedEvent, input.EntityType)
	}
	input.EventType = strings.ToLower(strings.TrimSpace(input.EventType))
	if input.EventType == "" {
		return normalizedLedgerEvent{}, fmt.Errorf("%w: event_type is required", ErrInvalidExpensePayload)
	}
	if input.ClientSequence < 0 {
		return normalizedLedgerEvent{}, fmt.Errorf("%w: client_sequence must be non-negative", ErrInvalidExpensePayload)
	}
	if input.BaseSequence < 0 {
		return normalizedLedgerEvent{}, fmt.Errorf("%w: base_sequence must be non-negative", ErrInvalidExpensePayload)
	}
	if input.PayloadVersion == 0 {
		input.PayloadVersion = 1
	}
	if input.PayloadVersion != 1 {
		return normalizedLedgerEvent{}, fmt.Errorf("%w: payload_version %d", ErrUnsupportedEvent, input.PayloadVersion)
	}

	normalized := normalizedLedgerEvent{input: input}
	switch input.EntityType {
	case "expense":
		switch input.EventType {
		case "expense.upsert", "expense.created", "expense.updated":
			if len(input.Payload) == 0 {
				return normalizedLedgerEvent{}, fmt.Errorf("%w: payload is required", ErrInvalidExpensePayload)
			}
			var payload ExpenseEventPayload
			if err := json.Unmarshal(input.Payload, &payload); err != nil {
				return normalizedLedgerEvent{}, fmt.Errorf("%w: decode payload: %v", ErrInvalidExpensePayload, err)
			}
			if err := normalizeExpensePayload(&payload); err != nil {
				return normalizedLedgerEvent{}, err
			}
			canonicalPayload, err := json.Marshal(payload)
			if err != nil {
				return normalizedLedgerEvent{}, fmt.Errorf("%w: encode payload: %v", ErrInvalidExpensePayload, err)
			}
			normalized.input.Payload = canonicalPayload
			normalized.expensePayload = &payload
		case "expense.voided", "expense.deleted":
			if len(input.Payload) > 0 {
				var object map[string]json.RawMessage
				if err := json.Unmarshal(input.Payload, &object); err != nil || object == nil {
					return normalizedLedgerEvent{}, fmt.Errorf("%w: void event payload must be a JSON object", ErrInvalidExpensePayload)
				}
			}
			normalized.input.Payload = json.RawMessage(`{}`)
		default:
			return normalizedLedgerEvent{}, fmt.Errorf("%w: event_type %q", ErrUnsupportedEvent, input.EventType)
		}
	case "payment":
		switch input.EventType {
		case "payment.upsert", "payment.created", "payment.updated":
			if len(input.Payload) == 0 {
				return normalizedLedgerEvent{}, fmt.Errorf("%w: payload is required", ErrInvalidExpensePayload)
			}
			var payload PaymentEventPayload
			if err := json.Unmarshal(input.Payload, &payload); err != nil {
				return normalizedLedgerEvent{}, fmt.Errorf("%w: decode payment payload: %v", ErrInvalidExpensePayload, err)
			}
			if err := normalizePaymentPayload(&payload); err != nil {
				return normalizedLedgerEvent{}, err
			}
			canonicalPayload, err := json.Marshal(payload)
			if err != nil {
				return normalizedLedgerEvent{}, fmt.Errorf("%w: encode payment payload: %v", ErrInvalidExpensePayload, err)
			}
			normalized.input.Payload = canonicalPayload
			normalized.paymentPayload = &payload
		case "payment.voided", "payment.deleted":
			if len(input.Payload) > 0 {
				var object map[string]json.RawMessage
				if err := json.Unmarshal(input.Payload, &object); err != nil || object == nil {
					return normalizedLedgerEvent{}, fmt.Errorf("%w: void event payload must be a JSON object", ErrInvalidExpensePayload)
				}
			}
			normalized.input.Payload = json.RawMessage(`{}`)
		default:
			return normalizedLedgerEvent{}, fmt.Errorf("%w: event_type %q", ErrUnsupportedEvent, input.EventType)
		}
	case "group":
		if input.EntityUUID != input.GroupUUID {
			return normalizedLedgerEvent{}, fmt.Errorf("%w: group metadata entity_uuid must equal group_uuid", ErrInvalidExpensePayload)
		}
		if input.EventType != "group.name_updated" {
			return normalizedLedgerEvent{}, fmt.Errorf("%w: event_type %q", ErrUnsupportedEvent, input.EventType)
		}
		var payload GroupNameEventPayload
		if err := json.Unmarshal(input.Payload, &payload); err != nil {
			return normalizedLedgerEvent{}, fmt.Errorf("%w: decode group metadata payload: %v", ErrInvalidExpensePayload, err)
		}
		payload.Name, err = NormalizeGroupName(payload.Name)
		if err != nil {
			return normalizedLedgerEvent{}, fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
		}
		canonicalPayload, err := json.Marshal(payload)
		if err != nil {
			return normalizedLedgerEvent{}, fmt.Errorf("%w: encode group metadata payload: %v", ErrInvalidExpensePayload, err)
		}
		normalized.input.Payload = canonicalPayload
		normalized.groupNamePayload = &payload
	case "actor":
		if input.EventType != "actor.display_name_updated" {
			return normalizedLedgerEvent{}, fmt.Errorf("%w: event_type %q", ErrUnsupportedEvent, input.EventType)
		}
		var payload ActorDisplayNameEventPayload
		if err := json.Unmarshal(input.Payload, &payload); err != nil {
			return normalizedLedgerEvent{}, fmt.Errorf("%w: decode actor metadata payload: %v", ErrInvalidExpensePayload, err)
		}
		payload.DisplayName, err = NormalizeDisplayName(payload.DisplayName)
		if err != nil {
			return normalizedLedgerEvent{}, fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
		}
		canonicalPayload, err := json.Marshal(payload)
		if err != nil {
			return normalizedLedgerEvent{}, fmt.Errorf("%w: encode actor metadata payload: %v", ErrInvalidExpensePayload, err)
		}
		normalized.input.Payload = canonicalPayload
		normalized.actorDisplayNamePayload = &payload
	}

	return normalized, nil
}

func normalizeExpensePayload(payload *ExpenseEventPayload) error {
	payload.Name = strings.TrimSpace(payload.Name)
	if payload.Name == "" || len([]rune(payload.Name)) > 255 {
		return fmt.Errorf("%w: name must be between 1 and 255 characters", ErrInvalidExpensePayload)
	}
	payload.Description = strings.TrimSpace(payload.Description)
	if len([]rune(payload.Description)) > 4000 {
		return fmt.Errorf("%w: description must be at most 4000 characters", ErrInvalidExpensePayload)
	}
	payload.CurrencyCode = strings.ToUpper(strings.TrimSpace(payload.CurrencyCode))
	if len(payload.CurrencyCode) != 3 || !isASCIILetters(payload.CurrencyCode) {
		return fmt.Errorf("%w: currency_code must be three letters", ErrInvalidExpensePayload)
	}
	if payload.TotalMinorUnits <= 0 {
		return fmt.Errorf("%w: total_minor_units must be positive", ErrInvalidExpensePayload)
	}
	payload.PayerActorUUID, _ = normalizeUUID(payload.PayerActorUUID, "payer_actor_uuid")
	if payload.PayerActorUUID == "" {
		return fmt.Errorf("%w: payer_actor_uuid must be a valid UUID", ErrInvalidExpensePayload)
	}
	payload.SplitMethod = strings.ToLower(strings.TrimSpace(payload.SplitMethod))
	if payload.SplitMethod != "equal" && payload.SplitMethod != "manual" {
		return fmt.Errorf("%w: split_method must be equal or manual", ErrInvalidExpensePayload)
	}

	if len(payload.SplitConfig) == 0 || string(payload.SplitConfig) == "null" {
		payload.SplitConfig = json.RawMessage(`{}`)
	} else {
		var config map[string]json.RawMessage
		if err := json.Unmarshal(payload.SplitConfig, &config); err != nil || config == nil {
			return fmt.Errorf("%w: split_config must be a JSON object", ErrInvalidExpensePayload)
		}
		canonicalConfig, err := json.Marshal(config)
		if err != nil {
			return fmt.Errorf("%w: encode split_config: %v", ErrInvalidExpensePayload, err)
		}
		payload.SplitConfig = canonicalConfig
	}

	if payload.OccurredAt.IsZero() {
		payload.OccurredAt = time.Now().UTC()
	} else {
		payload.OccurredAt = payload.OccurredAt.UTC()
	}
	if len(payload.Splits) == 0 {
		return fmt.Errorf("%w: at least one split is required", ErrInvalidExpensePayload)
	}

	seenActors := make(map[string]struct{}, len(payload.Splits))
	for index := range payload.Splits {
		actorUUID, err := normalizeUUID(payload.Splits[index].ActorUUID, "splits.actor_uuid")
		if err != nil {
			return fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
		}
		if _, exists := seenActors[actorUUID]; exists {
			return fmt.Errorf("%w: duplicate split actor %s", ErrInvalidExpensePayload, actorUUID)
		}
		seenActors[actorUUID] = struct{}{}
		payload.Splits[index].ActorUUID = actorUUID
		if payload.SplitMethod == "manual" && payload.Splits[index].AmountMinorUnits < 0 {
			return fmt.Errorf("%w: split amounts must be non-negative", ErrInvalidExpensePayload)
		}
	}

	if payload.SplitMethod == "equal" {
		sort.Slice(payload.Splits, func(i, j int) bool {
			return payload.Splits[i].ActorUUID < payload.Splits[j].ActorUUID
		})
		count := int64(len(payload.Splits))
		baseAmount := payload.TotalMinorUnits / count
		remainder := payload.TotalMinorUnits % count
		for index := range payload.Splits {
			payload.Splits[index].AmountMinorUnits = baseAmount
			if int64(index) < remainder {
				payload.Splits[index].AmountMinorUnits++
			}
		}
	} else {
		sort.Slice(payload.Splits, func(i, j int) bool {
			return payload.Splits[i].ActorUUID < payload.Splits[j].ActorUUID
		})
		var total int64
		for _, split := range payload.Splits {
			if split.AmountMinorUnits > payload.TotalMinorUnits-total {
				return fmt.Errorf("%w: split amounts exceed total", ErrInvalidExpensePayload)
			}
			total += split.AmountMinorUnits
		}
		if total != payload.TotalMinorUnits {
			return fmt.Errorf("%w: split amounts must equal total_minor_units", ErrInvalidExpensePayload)
		}
	}

	return nil
}

func validateExpenseActorsTx(ctx context.Context, tx *sql.Tx, groupUUID string, payload *ExpenseEventPayload) error {
	actors := make([]string, 0, len(payload.Splits)+1)
	actors = append(actors, payload.PayerActorUUID)
	for _, split := range payload.Splits {
		actors = append(actors, split.ActorUUID)
	}

	seen := make(map[string]struct{}, len(actors))
	for _, actorUUID := range actors {
		if _, exists := seen[actorUUID]; exists {
			continue
		}
		seen[actorUUID] = struct{}{}
		active, err := activeActorTx(ctx, tx, groupUUID, actorUUID)
		if err != nil {
			return fmt.Errorf("check expense actor: %w", err)
		}
		if !active {
			return fmt.Errorf("%w: %s", ErrActorNotFound, actorUUID)
		}
	}
	return nil
}

func applyGroupNameTx(ctx context.Context, tx *sql.Tx, event LedgerEvent, payload GroupNameEventPayload) error {
	result, err := tx.ExecContext(ctx, `
		UPDATE groups
		SET name = $2,
			latest_metadata_event_sequence = $3
		WHERE uuid = $1`, event.EntityUUID, payload.Name, event.Sequence)
	if err != nil {
		return fmt.Errorf("update group metadata projection: %w", err)
	}
	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("check group metadata projection: %w", err)
	}
	if rowsAffected == 0 {
		return ErrGroupNotFound
	}
	return nil
}

func applyActorDisplayNameTx(ctx context.Context, tx *sql.Tx, event LedgerEvent, payload ActorDisplayNameEventPayload) error {
	result, err := tx.ExecContext(ctx, `
		UPDATE group_actors
		SET display_name = $3,
			latest_metadata_event_sequence = $4
		WHERE group_uuid = $1
			AND actor_uuid = $2
			AND archived_at IS NULL`, event.GroupUUID, event.EntityUUID, payload.DisplayName, event.Sequence)
	if err != nil {
		return fmt.Errorf("update actor metadata projection: %w", err)
	}
	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("check actor metadata projection: %w", err)
	}
	if rowsAffected == 0 {
		return ErrActorNotFound
	}
	return nil
}

func applyExpenseUpsertTx(ctx context.Context, tx *sql.Tx, event LedgerEvent, payload ExpenseEventPayload) error {
	_, err := loadExpenseTx(ctx, tx, event.GroupUUID, event.EntityUUID)
	if err != nil && !errors.Is(err, ErrExpenseNotFound) {
		return err
	}

	if errors.Is(err, ErrExpenseNotFound) {
		_, err = tx.ExecContext(ctx, `
			INSERT INTO expenses (
				expense_uuid, group_uuid, created_by_actor_uuid, payer_actor_uuid,
				name, description, currency_code, total_minor_units, split_method,
				split_config, occurred_at, created_at, updated_at,
				latest_event_sequence, voided_at
			)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $12, $13, NULL)`,
			event.EntityUUID,
			event.GroupUUID,
			event.ActorUUID,
			payload.PayerActorUUID,
			payload.Name,
			payload.Description,
			payload.CurrencyCode,
			payload.TotalMinorUnits,
			payload.SplitMethod,
			payload.SplitConfig,
			payload.OccurredAt,
			event.EventCreatedAt,
			event.Sequence,
		)
		if err != nil {
			return fmt.Errorf("insert expense projection: %w", err)
		}
	} else {
		_, err = tx.ExecContext(ctx, `
			UPDATE expenses
			SET payer_actor_uuid = $3,
				name = $4,
				description = $5,
				currency_code = $6,
				total_minor_units = $7,
				split_method = $8,
				split_config = $9,
				occurred_at = $10,
				updated_at = $11,
				latest_event_sequence = $12,
				voided_at = NULL
			WHERE expense_uuid = $1 AND group_uuid = $2`,
			event.EntityUUID,
			event.GroupUUID,
			payload.PayerActorUUID,
			payload.Name,
			payload.Description,
			payload.CurrencyCode,
			payload.TotalMinorUnits,
			payload.SplitMethod,
			payload.SplitConfig,
			payload.OccurredAt,
			event.EventCreatedAt,
			event.Sequence,
		)
		if err != nil {
			return fmt.Errorf("update expense projection: %w", err)
		}
	}

	if _, err := tx.ExecContext(ctx, `
		DELETE FROM expense_splits
		WHERE expense_uuid = $1 AND group_uuid = $2`, event.EntityUUID, event.GroupUUID); err != nil {
		return fmt.Errorf("replace expense splits: %w", err)
	}
	for _, split := range payload.Splits {
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO expense_splits (group_uuid, expense_uuid, actor_uuid, amount_minor_units)
			VALUES ($1, $2, $3, $4)`, event.GroupUUID, event.EntityUUID, split.ActorUUID, split.AmountMinorUnits); err != nil {
			return fmt.Errorf("insert expense split: %w", err)
		}
	}

	return nil
}

func applyExpenseVoidedTx(ctx context.Context, tx *sql.Tx, event LedgerEvent) error {
	result, err := tx.ExecContext(ctx, `
		UPDATE expenses
		SET updated_at = $3,
			latest_event_sequence = $4,
			voided_at = $3
		WHERE expense_uuid = $1 AND group_uuid = $2`, event.EntityUUID, event.GroupUUID, event.EventCreatedAt, event.Sequence)
	if err != nil {
		return fmt.Errorf("void expense projection: %w", err)
	}
	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("check voided expense projection: %w", err)
	}
	if rowsAffected == 0 {
		return ErrExpenseNotFound
	}
	return nil
}

func loadGroupTx(ctx context.Context, tx *sql.Tx, groupUUID string) (Group, error) {
	var group Group
	err := tx.QueryRowContext(ctx, `
		SELECT uuid, name, creation_date, join_code, latest_event_sequence,
			latest_metadata_event_sequence
		FROM groups
		WHERE uuid = $1`, groupUUID).Scan(
		&group.UUID,
		&group.Name,
		&group.CreationDate,
		&group.JoinCode,
		&group.LatestEventSequence,
		&group.LatestMetadataEventSequence,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return Group{}, ErrGroupNotFound
	}
	if err != nil {
		return Group{}, fmt.Errorf("load group: %w", err)
	}
	return group, nil
}

func loadActorTx(ctx context.Context, tx *sql.Tx, groupUUID, actorUUID string) (GroupActor, error) {
	var actor GroupActor
	err := tx.QueryRowContext(ctx, `
		SELECT actor_uuid, COALESCE(display_name, ''), latest_metadata_event_sequence
		FROM group_actors
		WHERE group_uuid = $1
			AND actor_uuid = $2
			AND archived_at IS NULL`, groupUUID, actorUUID).Scan(
		&actor.ActorUUID,
		&actor.DisplayName,
		&actor.LatestMetadataEventSequence,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return GroupActor{}, ErrActorNotFound
	}
	if err != nil {
		return GroupActor{}, fmt.Errorf("load actor: %w", err)
	}
	return actor, nil
}

func loadExpenseTx(ctx context.Context, tx *sql.Tx, groupUUID, expenseUUID string) (Expense, error) {
	return loadExpense(ctx, tx, groupUUID, expenseUUID)
}

func loadExpense(ctx context.Context, queryer sqlQueryer, groupUUID, expenseUUID string) (Expense, error) {
	var expense Expense
	var splitConfig []byte
	var voidedAt sql.NullTime
	err := queryer.QueryRowContext(ctx, `
		SELECT expense_uuid, group_uuid, created_by_actor_uuid, payer_actor_uuid,
			name, description, currency_code, total_minor_units, split_method,
			split_config, occurred_at, created_at, updated_at,
			latest_event_sequence, voided_at
		FROM expenses
		WHERE group_uuid = $1 AND expense_uuid = $2`, groupUUID, expenseUUID).Scan(
		&expense.UUID,
		&expense.GroupUUID,
		&expense.CreatedByActorUUID,
		&expense.PayerActorUUID,
		&expense.Name,
		&expense.Description,
		&expense.CurrencyCode,
		&expense.TotalMinorUnits,
		&expense.SplitMethod,
		&splitConfig,
		&expense.OccurredAt,
		&expense.CreatedAt,
		&expense.UpdatedAt,
		&expense.LatestEventSequence,
		&voidedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return Expense{}, ErrExpenseNotFound
	}
	if err != nil {
		return Expense{}, fmt.Errorf("load expense: %w", err)
	}

	expense.SplitConfig = append(json.RawMessage(nil), splitConfig...)
	expense.Splits = make([]ExpenseSplit, 0)
	rows, err := queryer.QueryContext(ctx, `
		SELECT actor_uuid, amount_minor_units
		FROM expense_splits
		WHERE group_uuid = $1 AND expense_uuid = $2
		ORDER BY actor_uuid`, groupUUID, expenseUUID)
	if err != nil {
		return Expense{}, fmt.Errorf("load expense splits: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var split ExpenseSplit
		if err := rows.Scan(&split.ActorUUID, &split.AmountMinorUnits); err != nil {
			return Expense{}, fmt.Errorf("scan expense split: %w", err)
		}
		expense.Splits = append(expense.Splits, split)
	}
	if err := rows.Err(); err != nil {
		return Expense{}, fmt.Errorf("iterate expense splits: %w", err)
	}
	if voidedAt.Valid {
		expense.VoidedAt = &voidedAt.Time
	}
	return expense, nil
}

func activeGroupMembership(ctx context.Context, queryer sqlQueryer, groupUUID, deviceID string) (bool, error) {
	var exists bool
	err := queryer.QueryRowContext(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM actor_device_bindings
			WHERE group_uuid = $1
				AND device_id = $2
				AND unbound_at IS NULL
		)`, groupUUID, deviceID).Scan(&exists)
	return exists, err
}

func activeGroupMembershipTx(ctx context.Context, tx *sql.Tx, groupUUID, deviceID string) (bool, error) {
	return activeGroupMembership(ctx, tx, groupUUID, deviceID)
}

func activeActorTx(ctx context.Context, tx *sql.Tx, groupUUID, actorUUID string) (bool, error) {
	var exists bool
	err := tx.QueryRowContext(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM group_actors
			WHERE group_uuid = $1
				AND actor_uuid = $2
				AND archived_at IS NULL
		)`, groupUUID, actorUUID).Scan(&exists)
	return exists, err
}

func activeActorDeviceBindingTx(ctx context.Context, tx *sql.Tx, groupUUID, actorUUID, deviceID string) (bool, error) {
	var exists bool
	err := tx.QueryRowContext(ctx, `
		SELECT EXISTS (
			SELECT 1
			FROM actor_device_bindings AS binding
			JOIN group_actors AS actor
				ON actor.group_uuid = binding.group_uuid
				AND actor.actor_uuid = binding.actor_uuid
			WHERE binding.group_uuid = $1
				AND binding.actor_uuid = $2
				AND binding.device_id = $3
				AND binding.unbound_at IS NULL
				AND actor.archived_at IS NULL
		)`, groupUUID, actorUUID, deviceID).Scan(&exists)
	return exists, err
}

func activeActorUUIDForDeviceTx(ctx context.Context, tx *sql.Tx, groupUUID, deviceID string) (string, error) {
	var actorUUID string
	err := tx.QueryRowContext(ctx, `
		SELECT binding.actor_uuid
		FROM actor_device_bindings AS binding
		JOIN group_actors AS actor
			ON actor.group_uuid = binding.group_uuid
			AND actor.actor_uuid = binding.actor_uuid
		WHERE binding.group_uuid = $1
			AND binding.device_id = $2
			AND binding.unbound_at IS NULL
			AND actor.archived_at IS NULL`, groupUUID, deviceID).Scan(&actorUUID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrActorNotFound
	}
	if err != nil {
		return "", fmt.Errorf("load active actor for device: %w", err)
	}
	return actorUUID, nil
}

func nextClientSequenceTx(ctx context.Context, tx *sql.Tx, deviceID string) (int64, error) {
	var lockedDeviceID string
	if err := tx.QueryRowContext(ctx, `
		SELECT device_id
		FROM devices
		WHERE device_id = $1
		FOR UPDATE`, deviceID).Scan(&lockedDeviceID); err != nil {
		return 0, fmt.Errorf("lock device for client sequence: %w", err)
	}

	var nextSequence int64
	if err := tx.QueryRowContext(ctx, `
		SELECT COALESCE(MAX(client_sequence), -1) + 1
		FROM ledger_events
		WHERE device_id = $1`, lockedDeviceID).Scan(&nextSequence); err != nil {
		return 0, fmt.Errorf("allocate client sequence: %w", err)
	}
	return nextSequence, nil
}

func findLedgerEventByUUIDTx(ctx context.Context, tx *sql.Tx, eventUUID string) (LedgerEvent, error) {
	var event LedgerEvent
	err := scanLedgerEvent(tx.QueryRowContext(ctx, `
		SELECT event_uuid, group_uuid, sequence, entity_type, entity_uuid,
			event_type, actor_uuid, device_id, client_sequence, base_sequence,
			event_created_at, had_conflict, payload_version, payload_hash, payload, recorded_at
		FROM ledger_events
		WHERE event_uuid = $1`, eventUUID), &event)
	return event, err
}

func findLedgerEventByClientSequenceTx(ctx context.Context, tx *sql.Tx, deviceID string, clientSequence int64) (LedgerEvent, error) {
	var event LedgerEvent
	err := scanLedgerEvent(tx.QueryRowContext(ctx, `
		SELECT event_uuid, group_uuid, sequence, entity_type, entity_uuid,
			event_type, actor_uuid, device_id, client_sequence, base_sequence,
			event_created_at, had_conflict, payload_version, payload_hash, payload, recorded_at
		FROM ledger_events
		WHERE device_id = $1 AND client_sequence = $2`, deviceID, clientSequence), &event)
	return event, err
}

type ledgerEventVersion struct {
	EventUUID      string
	EventCreatedAt time.Time
}

func findLedgerEventVersionBySequenceTx(ctx context.Context, tx *sql.Tx, groupUUID string, sequence int64) (ledgerEventVersion, error) {
	var version ledgerEventVersion
	err := tx.QueryRowContext(ctx, `
		SELECT event_uuid, event_created_at
		FROM ledger_events
		WHERE group_uuid = $1 AND sequence = $2`, groupUUID, sequence).Scan(
		&version.EventUUID,
		&version.EventCreatedAt,
	)
	return version, err
}

type rowScanner interface {
	Scan(...any) error
}

func scanLedgerEvent(scanner rowScanner, event *LedgerEvent) error {
	var payload []byte
	err := scanner.Scan(
		&event.EventUUID,
		&event.GroupUUID,
		&event.Sequence,
		&event.EntityType,
		&event.EntityUUID,
		&event.EventType,
		&event.ActorUUID,
		&event.DeviceID,
		&event.ClientSequence,
		&event.BaseSequence,
		&event.EventCreatedAt,
		&event.HadConflict,
		&event.PayloadVersion,
		&event.PayloadHash,
		&payload,
		&event.RecordedAt,
	)
	if err != nil {
		return err
	}
	event.Payload = append(json.RawMessage(nil), payload...)
	return nil
}

func ledgerEventsEqual(existing LedgerEvent, input LedgerEventInput, deviceID string, payloadHash []byte) bool {
	return existing.EventUUID == input.EventUUID &&
		existing.GroupUUID == input.GroupUUID &&
		existing.EntityType == input.EntityType &&
		existing.EntityUUID == input.EntityUUID &&
		existing.EventType == input.EventType &&
		existing.ActorUUID == input.ActorUUID &&
		existing.DeviceID == deviceID &&
		existing.EventCreatedAt.Equal(input.EventCreatedAt) &&
		existing.ClientSequence == input.ClientSequence &&
		existing.BaseSequence == input.BaseSequence &&
		existing.PayloadVersion == input.PayloadVersion &&
		bytes.Equal(existing.PayloadHash, payloadHash)
}

func eventVersionWins(incomingTime time.Time, incomingUUID string, currentTime time.Time, currentUUID string) bool {
	if incomingTime.After(currentTime) {
		return true
	}
	if incomingTime.Before(currentTime) {
		return false
	}
	return incomingUUID > currentUUID
}

func expenseOrNil(expense Expense, err error) *Expense {
	if err != nil {
		return nil
	}
	return &expense
}

func normalizeUUID(value, field string) (string, error) {
	parsed, err := uuid.Parse(strings.TrimSpace(value))
	if err != nil {
		return "", fmt.Errorf("%s must be a valid UUID", field)
	}
	return parsed.String(), nil
}

func isASCIILetters(value string) bool {
	for _, character := range value {
		if (character < 'A' || character > 'Z') && (character < 'a' || character > 'z') {
			return false
		}
	}
	return true
}

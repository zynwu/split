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

type LedgerEventInput struct {
	EventUUID      string
	GroupUUID      string
	EntityType     string
	EntityUUID     string
	EventType      string
	ActorUUID      string
	EventCreatedAt time.Time
	ClientSequence int64
	BaseSequence   int64
	PayloadVersion int
	Payload        json.RawMessage
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

func (database *Database) AppendLedgerEvent(ctx context.Context, deviceID string, input LedgerEventInput) (AppendLedgerEventResult, error) {
	normalized, payload, err := normalizeLedgerEvent(input)
	if err != nil {
		return AppendLedgerEventResult{}, err
	}

	eventHash := sha256.Sum256(normalized.Payload)
	tx, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("begin ledger event transaction: %w", err)
	}
	defer tx.Rollback()

	var currentGroupSequence int64
	err = tx.QueryRowContext(ctx, `
		SELECT latest_event_sequence
		FROM groups
		WHERE uuid = $1
		FOR UPDATE`, normalized.GroupUUID).Scan(&currentGroupSequence)
	if errors.Is(err, sql.ErrNoRows) {
		return AppendLedgerEventResult{}, ErrGroupNotFound
	}
	if err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("lock group for ledger event: %w", err)
	}

	member, err := activeGroupMembershipTx(ctx, tx, normalized.GroupUUID, deviceID)
	if err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("check group membership: %w", err)
	}
	if !member {
		return AppendLedgerEventResult{}, ErrGroupMembershipDenied
	}

	actorExists, err := activeActorTx(ctx, tx, normalized.GroupUUID, normalized.ActorUUID)
	if err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("check event actor: %w", err)
	}
	if !actorExists {
		return AppendLedgerEventResult{}, ErrActorNotFound
	}

	actorBound, err := activeActorDeviceBindingTx(ctx, tx, normalized.GroupUUID, normalized.ActorUUID, deviceID)
	if err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("check event actor device binding: %w", err)
	}
	if !actorBound {
		return AppendLedgerEventResult{}, ErrActorDeviceMismatch
	}

	existingEvent, err := findLedgerEventByUUIDTx(ctx, tx, normalized.EventUUID)
	if err == nil {
		if !ledgerEventsEqual(existingEvent, normalized, deviceID, eventHash[:]) {
			return AppendLedgerEventResult{}, ErrLedgerEventConflict
		}

		expense, expenseErr := loadExpenseTx(ctx, tx, normalized.GroupUUID, normalized.EntityUUID)
		if expenseErr != nil && !errors.Is(expenseErr, ErrExpenseNotFound) {
			return AppendLedgerEventResult{}, expenseErr
		}
		return AppendLedgerEventResult{
			Event:    existingEvent,
			Expense:  expenseOrNil(expense, expenseErr),
			Applied:  expenseErr == nil && expense.LatestEventSequence == existingEvent.Sequence,
			Conflict: existingEvent.HadConflict,
			Replayed: true,
		}, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return AppendLedgerEventResult{}, fmt.Errorf("check duplicate ledger event: %w", err)
	}

	existingSequenceEvent, err := findLedgerEventByClientSequenceTx(ctx, tx, deviceID, normalized.ClientSequence)
	if err == nil {
		return AppendLedgerEventResult{}, fmt.Errorf("%w: %s", ErrClientSequenceConflict, existingSequenceEvent.EventUUID)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return AppendLedgerEventResult{}, fmt.Errorf("check client sequence: %w", err)
	}

	var currentExpense Expense
	currentExpense, err = loadExpenseTx(ctx, tx, normalized.GroupUUID, normalized.EntityUUID)
	if err != nil && !errors.Is(err, ErrExpenseNotFound) {
		return AppendLedgerEventResult{}, err
	}
	currentExpenseExists := err == nil
	currentExpenseSequence := int64(0)
	currentExpenseEvent := ledgerEventVersion{}
	if currentExpenseExists {
		currentExpenseSequence = currentExpense.LatestEventSequence
		currentExpenseEvent, err = findLedgerEventVersionBySequenceTx(ctx, tx, normalized.GroupUUID, currentExpenseSequence)
		if err != nil {
			return AppendLedgerEventResult{}, fmt.Errorf("load current expense event: %w", err)
		}
	}

	if payload != nil {
		if err := validateExpenseActorsTx(ctx, tx, normalized.GroupUUID, payload); err != nil {
			return AppendLedgerEventResult{}, err
		}
	}
	if normalized.EventType == "expense.updated" && !currentExpenseExists {
		return AppendLedgerEventResult{}, ErrExpenseNotFound
	}
	if (normalized.EventType == "expense.voided" || normalized.EventType == "expense.deleted") && !currentExpenseExists {
		return AppendLedgerEventResult{}, ErrExpenseNotFound
	}

	winningEvent := !currentExpenseExists || eventVersionWins(
		normalized.EventCreatedAt,
		normalized.EventUUID,
		currentExpenseEvent.EventCreatedAt,
		currentExpenseEvent.EventUUID,
	)
	hadConflict := normalized.BaseSequence != currentExpenseSequence || (currentExpenseExists && !winningEvent)
	nextSequence := currentGroupSequence + 1
	recordedAt := time.Now().UTC()

	var event LedgerEvent
	err = tx.QueryRowContext(ctx, `
		INSERT INTO ledger_events (
			event_uuid, group_uuid, sequence, entity_type, entity_uuid,
				event_type, actor_uuid, device_id, client_sequence, base_sequence,
				event_created_at, had_conflict, payload_version, payload_hash, payload, recorded_at
			)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
			RETURNING event_uuid, group_uuid, sequence, entity_type, entity_uuid,
				event_type, actor_uuid, device_id, client_sequence, base_sequence,
				event_created_at, had_conflict, payload_version, payload_hash, payload, recorded_at`,
		normalized.EventUUID,
		normalized.GroupUUID,
		nextSequence,
		normalized.EntityType,
		normalized.EntityUUID,
		normalized.EventType,
		normalized.ActorUUID,
		deviceID,
		normalized.ClientSequence,
		normalized.BaseSequence,
		normalized.EventCreatedAt,
		hadConflict,
		normalized.PayloadVersion,
		eventHash[:],
		normalized.Payload,
		recordedAt,
	).Scan(
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
		&event.Payload,
		&event.RecordedAt,
	)
	if err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("insert ledger event: %w", err)
	}
	event.PayloadHash = append([]byte(nil), eventHash[:]...)

	if _, err := tx.ExecContext(ctx, `
		UPDATE groups
		SET latest_event_sequence = $2
		WHERE uuid = $1`, normalized.GroupUUID, nextSequence); err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("advance group ledger sequence: %w", err)
	}

	var expense *Expense
	switch normalized.EventType {
	case "expense.upsert", "expense.created", "expense.updated":
		if winningEvent {
			if err := applyExpenseUpsertTx(ctx, tx, event, *payload); err != nil {
				return AppendLedgerEventResult{}, err
			}
		}
	case "expense.voided", "expense.deleted":
		if winningEvent {
			if err := applyExpenseVoidedTx(ctx, tx, event); err != nil {
				return AppendLedgerEventResult{}, err
			}
		}
	default:
		return AppendLedgerEventResult{}, fmt.Errorf("%w: %s", ErrUnsupportedEvent, normalized.EventType)
	}

	current, err := loadExpenseTx(ctx, tx, normalized.GroupUUID, normalized.EntityUUID)
	if err != nil {
		return AppendLedgerEventResult{}, err
	}
	expense = &current

	if err := tx.Commit(); err != nil {
		return AppendLedgerEventResult{}, fmt.Errorf("commit ledger event transaction: %w", err)
	}

	return AppendLedgerEventResult{
		Event:    event,
		Expense:  expense,
		Applied:  winningEvent,
		Conflict: hadConflict,
	}, nil
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

func normalizeLedgerEvent(input LedgerEventInput) (LedgerEventInput, *ExpenseEventPayload, error) {
	var err error
	input.EventUUID, err = normalizeUUID(input.EventUUID, "event_uuid")
	if err != nil {
		return LedgerEventInput{}, nil, fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
	}
	input.GroupUUID, err = normalizeUUID(input.GroupUUID, "group_uuid")
	if err != nil {
		return LedgerEventInput{}, nil, fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
	}
	input.EntityUUID, err = normalizeUUID(input.EntityUUID, "entity_uuid")
	if err != nil {
		return LedgerEventInput{}, nil, fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
	}
	input.ActorUUID, err = normalizeUUID(input.ActorUUID, "actor_uuid")
	if err != nil {
		return LedgerEventInput{}, nil, fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
	}
	if input.EventCreatedAt.IsZero() {
		return LedgerEventInput{}, nil, fmt.Errorf("%w: event_created_at is required", ErrInvalidExpensePayload)
	}
	input.EventCreatedAt = input.EventCreatedAt.UTC().Truncate(time.Microsecond)
	input.EntityType = strings.ToLower(strings.TrimSpace(input.EntityType))
	if input.EntityType != "expense" {
		return LedgerEventInput{}, nil, fmt.Errorf("%w: entity_type %q", ErrUnsupportedEvent, input.EntityType)
	}
	input.EventType = strings.ToLower(strings.TrimSpace(input.EventType))
	if input.EventType == "" {
		return LedgerEventInput{}, nil, fmt.Errorf("%w: event_type is required", ErrInvalidExpensePayload)
	}
	if input.ClientSequence < 0 {
		return LedgerEventInput{}, nil, fmt.Errorf("%w: client_sequence must be non-negative", ErrInvalidExpensePayload)
	}
	if input.BaseSequence < 0 {
		return LedgerEventInput{}, nil, fmt.Errorf("%w: base_sequence must be non-negative", ErrInvalidExpensePayload)
	}
	if input.PayloadVersion == 0 {
		input.PayloadVersion = 1
	}
	if input.PayloadVersion != 1 {
		return LedgerEventInput{}, nil, fmt.Errorf("%w: payload_version %d", ErrUnsupportedEvent, input.PayloadVersion)
	}

	switch input.EventType {
	case "expense.upsert", "expense.created", "expense.updated":
		if len(input.Payload) == 0 {
			return LedgerEventInput{}, nil, fmt.Errorf("%w: payload is required", ErrInvalidExpensePayload)
		}
		var payload ExpenseEventPayload
		if err := json.Unmarshal(input.Payload, &payload); err != nil {
			return LedgerEventInput{}, nil, fmt.Errorf("%w: decode payload: %v", ErrInvalidExpensePayload, err)
		}
		if err := normalizeExpensePayload(&payload); err != nil {
			return LedgerEventInput{}, nil, err
		}
		canonicalPayload, err := json.Marshal(payload)
		if err != nil {
			return LedgerEventInput{}, nil, fmt.Errorf("%w: encode payload: %v", ErrInvalidExpensePayload, err)
		}
		input.Payload = canonicalPayload
		return input, &payload, nil
	case "expense.voided", "expense.deleted":
		if len(input.Payload) > 0 {
			var object map[string]json.RawMessage
			if err := json.Unmarshal(input.Payload, &object); err != nil || object == nil {
				return LedgerEventInput{}, nil, fmt.Errorf("%w: void event payload must be a JSON object", ErrInvalidExpensePayload)
			}
		}
		input.Payload = json.RawMessage(`{}`)
		return input, nil, nil
	default:
		return LedgerEventInput{}, nil, fmt.Errorf("%w: event_type %q", ErrUnsupportedEvent, input.EventType)
	}
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

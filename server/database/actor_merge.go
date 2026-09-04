package database

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
)

var (
	ErrInvalidActorMergeRequest = errors.New("invalid actor merge request")
	ErrActorMergeConflict       = errors.New("actor merge conflicts with current group state")
)

// CommandeerActorInput contains the client-owned event identity for an actor
// merge. The source actor is intentionally not supplied by the caller; it is
// derived from the authenticated device's current active binding.
type CommandeerActorInput struct {
	EventUUID      string
	EventCreatedAt time.Time
	ClientSequence int64
}

// CommandeerActorResult is returned after the source actor has been redirected
// into the target actor. The merge event is retained in the group's ledger.
type CommandeerActorResult struct {
	Event           LedgerEvent `json:"event"`
	GroupUUID       string      `json:"group_uuid"`
	SourceActorUUID string      `json:"source_actor_uuid"`
	TargetActorUUID string      `json:"target_actor_uuid"`
	TargetActor     GroupActor  `json:"target_actor"`
	Applied         bool        `json:"applied"`
	Conflict        bool        `json:"conflict"`
	Replayed        bool        `json:"replayed"`
}

type actorCommandeeringEventPayload struct {
	SourceActorUUID string `json:"source_actor_uuid"`
	TargetActorUUID string `json:"target_actor_uuid"`
}

type actorBindingForMerge struct {
	BindingUUID string
	DeviceID    string
	BoundAt     time.Time
}

type paymentActorReferences struct {
	PaymentUUID        string
	CreatedByActorUUID string
	FromActorUUID      string
	ToActorUUID        string
}

// CommandeerActor merges the actor currently represented by deviceID into the
// active target actor in one serialized transaction. All source bindings are
// closed and recreated for the target, so every device that represented the
// source remains authorized as the target. Expense/payment projections are
// redirected, while their original actor/device details remain in the ledger.
func (database *Database) CommandeerActor(
	ctx context.Context,
	groupUUID string,
	targetActorUUID string,
	deviceID string,
	input CommandeerActorInput,
) (CommandeerActorResult, error) {
	var err error
	groupUUID, err = normalizeUUID(groupUUID, "group_uuid")
	if err != nil {
		return CommandeerActorResult{}, fmt.Errorf("%w: %v", ErrInvalidActorMergeRequest, err)
	}
	targetActorUUID, err = normalizeUUID(targetActorUUID, "actor_uuid")
	if err != nil {
		return CommandeerActorResult{}, fmt.Errorf("%w: %v", ErrInvalidActorMergeRequest, err)
	}
	input.EventUUID, err = normalizeUUID(input.EventUUID, "event_uuid")
	if err != nil {
		return CommandeerActorResult{}, fmt.Errorf("%w: %v", ErrInvalidActorMergeRequest, err)
	}
	if input.EventCreatedAt.IsZero() {
		return CommandeerActorResult{}, fmt.Errorf("%w: event_created_at is required", ErrInvalidActorMergeRequest)
	}
	input.EventCreatedAt = input.EventCreatedAt.UTC().Truncate(time.Microsecond)
	if input.ClientSequence < 0 {
		return CommandeerActorResult{}, fmt.Errorf("%w: client_sequence must be non-negative", ErrInvalidActorMergeRequest)
	}
	if strings.TrimSpace(deviceID) == "" {
		return CommandeerActorResult{}, fmt.Errorf("%w: device_id is required", ErrInvalidActorMergeRequest)
	}

	tx, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return CommandeerActorResult{}, fmt.Errorf("begin actor merge transaction: %w", err)
	}
	defer tx.Rollback()

	group, err := lockGroupForActorMergeTx(ctx, tx, groupUUID)
	if err != nil {
		return CommandeerActorResult{}, err
	}

	member, err := activeGroupMembershipTx(ctx, tx, groupUUID, deviceID)
	if err != nil {
		return CommandeerActorResult{}, fmt.Errorf("check actor merge membership: %w", err)
	}
	if !member {
		return CommandeerActorResult{}, ErrGroupMembershipDenied
	}

	// Check the replay key before resolving the current source actor. A retry
	// happens after the device has already been rebound to the target, so its
	// current actor is intentionally different from the original source.
	existingEvent, err := findLedgerEventByUUIDTx(ctx, tx, input.EventUUID)
	if err == nil {
		result, replayErr := replayActorCommandeeringTx(
			ctx,
			tx,
			existingEvent,
			groupUUID,
			targetActorUUID,
			deviceID,
			input,
		)
		if replayErr != nil {
			return CommandeerActorResult{}, replayErr
		}
		return result, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return CommandeerActorResult{}, fmt.Errorf("check duplicate actor merge event: %w", err)
	}

	if err := lockDeviceForActorMergeTx(ctx, tx, deviceID); err != nil {
		return CommandeerActorResult{}, err
	}
	existingSequenceEvent, err := findLedgerEventByClientSequenceTx(ctx, tx, deviceID, input.ClientSequence)
	if err == nil {
		return CommandeerActorResult{}, fmt.Errorf("%w: %s", ErrClientSequenceConflict, existingSequenceEvent.EventUUID)
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return CommandeerActorResult{}, fmt.Errorf("check actor merge client sequence: %w", err)
	}

	sourceActorUUID, err := currentActorForDeviceForUpdateTx(ctx, tx, groupUUID, deviceID)
	if err != nil {
		return CommandeerActorResult{}, err
	}
	if sourceActorUUID == targetActorUUID {
		return CommandeerActorResult{}, fmt.Errorf("%w: device is already acting as the target actor", ErrActorMergeConflict)
	}

	var targetActor GroupActor
	var targetArchivedAt sql.NullTime
	var targetMergedInto sql.NullString
	err = tx.QueryRowContext(ctx, `
		SELECT actor_uuid, COALESCE(display_name, ''),
			latest_metadata_event_sequence, archived_at, merged_into_actor_uuid
		FROM group_actors
		WHERE group_uuid = $1 AND actor_uuid = $2
		FOR UPDATE`, groupUUID, targetActorUUID).Scan(
		&targetActor.ActorUUID,
		&targetActor.DisplayName,
		&targetActor.LatestMetadataEventSequence,
		&targetArchivedAt,
		&targetMergedInto,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return CommandeerActorResult{}, ErrActorNotFound
	}
	if err != nil {
		return CommandeerActorResult{}, fmt.Errorf("load actor merge target: %w", err)
	}
	if targetArchivedAt.Valid || targetMergedInto.Valid {
		return CommandeerActorResult{}, fmt.Errorf("%w: target actor is no longer active", ErrActorMergeConflict)
	}

	bindingRows, err := tx.QueryContext(ctx, `
		SELECT binding_uuid, device_id, bound_at
		FROM actor_device_bindings
		WHERE group_uuid = $1
			AND actor_uuid = $2
			AND unbound_at IS NULL
		ORDER BY binding_uuid
		FOR UPDATE`, groupUUID, sourceActorUUID)
	if err != nil {
		return CommandeerActorResult{}, fmt.Errorf("load actor bindings to merge: %w", err)
	}
	bindings := make([]actorBindingForMerge, 0)
	for bindingRows.Next() {
		var binding actorBindingForMerge
		if err := bindingRows.Scan(&binding.BindingUUID, &binding.DeviceID, &binding.BoundAt); err != nil {
			bindingRows.Close()
			return CommandeerActorResult{}, fmt.Errorf("scan actor binding to merge: %w", err)
		}
		bindings = append(bindings, binding)
	}
	if err := bindingRows.Err(); err != nil {
		bindingRows.Close()
		return CommandeerActorResult{}, fmt.Errorf("iterate actor bindings to merge: %w", err)
	}
	if err := bindingRows.Close(); err != nil {
		return CommandeerActorResult{}, fmt.Errorf("close actor bindings to merge: %w", err)
	}
	if len(bindings) == 0 {
		return CommandeerActorResult{}, ErrActorDeviceMismatch
	}

	payloadBytes, err := json.Marshal(actorCommandeeringEventPayload{
		SourceActorUUID: sourceActorUUID,
		TargetActorUUID: targetActorUUID,
	})
	if err != nil {
		return CommandeerActorResult{}, fmt.Errorf("encode actor merge event: %w", err)
	}
	payloadHash := sha256.Sum256(payloadBytes)
	recordedAt := time.Now().UTC().Truncate(time.Microsecond)
	operationAt := recordedAt
	for _, binding := range bindings {
		if !operationAt.After(binding.BoundAt) {
			operationAt = binding.BoundAt.Add(time.Microsecond)
		}
	}

	eventInput := LedgerEventInput{
		EventUUID:      input.EventUUID,
		GroupUUID:      groupUUID,
		EntityType:     "actor",
		EntityUUID:     targetActorUUID,
		EventType:      "actor.commandeered",
		ActorUUID:      sourceActorUUID,
		EventCreatedAt: input.EventCreatedAt,
		ClientSequence: input.ClientSequence,
		BaseSequence:   group.LatestEventSequence,
		PayloadVersion: 1,
		Payload:        payloadBytes,
	}

	var event LedgerEvent
	inserted, err := insertLedgerEventTx(
		ctx,
		tx,
		eventInput,
		deviceID,
		group.LatestEventSequence+1,
		false,
		payloadHash[:],
		nil,
		recordedAt,
		&event,
	)
	if err != nil {
		return CommandeerActorResult{}, err
	}
	if !inserted {
		// The group lock normally makes this impossible for the same group, but
		// retain the same idempotency behavior if a unique key raced elsewhere.
		existingEvent, lookupErr := findLedgerEventByUUIDTx(ctx, tx, input.EventUUID)
		if lookupErr == nil {
			return replayActorCommandeeringTx(ctx, tx, existingEvent, groupUUID, targetActorUUID, deviceID, input)
		}
		if !errors.Is(lookupErr, sql.ErrNoRows) {
			return CommandeerActorResult{}, fmt.Errorf("check concurrent actor merge event: %w", lookupErr)
		}
		return CommandeerActorResult{}, fmt.Errorf("%w: actor merge event was not inserted", ErrLedgerEventConflict)
	}

	if err := redirectExpenseActorsTx(ctx, tx, groupUUID, sourceActorUUID, targetActorUUID); err != nil {
		return CommandeerActorResult{}, err
	}
	if err := redirectPaymentActorsTx(ctx, tx, groupUUID, sourceActorUUID, targetActorUUID, operationAt); err != nil {
		return CommandeerActorResult{}, err
	}

	for _, binding := range bindings {
		unboundAt := operationAt
		if !unboundAt.After(binding.BoundAt) {
			unboundAt = binding.BoundAt.Add(time.Microsecond)
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE actor_device_bindings
			SET unbound_at = $2,
				unbound_reason = 'actor_merged'
			WHERE binding_uuid = $1
				AND unbound_at IS NULL`, binding.BindingUUID, unboundAt); err != nil {
			return CommandeerActorResult{}, fmt.Errorf("close source actor binding: %w", err)
		}

		newBindingUUID, err := uuid.NewRandom()
		if err != nil {
			return CommandeerActorResult{}, fmt.Errorf("generate merged actor binding uuid: %w", err)
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO actor_device_bindings (binding_uuid, group_uuid, actor_uuid, device_id, bound_at)
			VALUES ($1, $2, $3, $4, $5)`,
			newBindingUUID.String(), groupUUID, targetActorUUID, binding.DeviceID, operationAt); err != nil {
			return CommandeerActorResult{}, fmt.Errorf("bind device to target actor: %w", err)
		}
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE group_actors
		SET archived_at = $3,
			merged_into_actor_uuid = $4
		WHERE group_uuid = $1
			AND actor_uuid = $2
			AND archived_at IS NULL`, groupUUID, sourceActorUUID, operationAt, targetActorUUID); err != nil {
		return CommandeerActorResult{}, fmt.Errorf("archive merged actor: %w", err)
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE groups
		SET latest_event_sequence = $2
		WHERE uuid = $1`, groupUUID, event.Sequence); err != nil {
		return CommandeerActorResult{}, fmt.Errorf("advance group sequence for actor merge: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return CommandeerActorResult{}, fmt.Errorf("commit actor merge transaction: %w", err)
	}

	return CommandeerActorResult{
		Event:           event,
		GroupUUID:       groupUUID,
		SourceActorUUID: sourceActorUUID,
		TargetActorUUID: targetActorUUID,
		TargetActor:     targetActor,
		Applied:         true,
	}, nil
}

func lockGroupForActorMergeTx(ctx context.Context, tx *sql.Tx, groupUUID string) (Group, error) {
	var group Group
	err := tx.QueryRowContext(ctx, `
		SELECT uuid, name, creation_date, join_code, latest_event_sequence,
			latest_metadata_event_sequence
		FROM groups
		WHERE uuid = $1
		FOR UPDATE`, groupUUID).Scan(
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
		return Group{}, fmt.Errorf("lock group for actor merge: %w", err)
	}
	return group, nil
}

func lockDeviceForActorMergeTx(ctx context.Context, tx *sql.Tx, deviceID string) error {
	var lockedDeviceID string
	if err := tx.QueryRowContext(ctx, `
		SELECT device_id
		FROM devices
		WHERE device_id = $1
		FOR UPDATE`, deviceID).Scan(&lockedDeviceID); err != nil {
		return fmt.Errorf("lock device for actor merge: %w", err)
	}
	return nil
}

func currentActorForDeviceForUpdateTx(ctx context.Context, tx *sql.Tx, groupUUID, deviceID string) (string, error) {
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
			AND actor.archived_at IS NULL
		FOR UPDATE OF binding`, groupUUID, deviceID).Scan(&actorUUID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrActorNotFound
	}
	if err != nil {
		return "", fmt.Errorf("load current actor for merge: %w", err)
	}
	return actorUUID, nil
}

// resolveActorUUIDTx follows the durable merge chain to the active actor. It
// is used when an offline event was created before a device was moved to its
// surviving actor, while the original actor UUID is still preserved in the
// ledger event and payload.
func resolveActorUUIDTx(ctx context.Context, tx *sql.Tx, groupUUID, actorUUID string) (string, error) {
	currentActorUUID := actorUUID
	for range 64 {
		var archivedAt sql.NullTime
		var mergedInto sql.NullString
		err := tx.QueryRowContext(ctx, `
			SELECT archived_at, merged_into_actor_uuid
			FROM group_actors
			WHERE group_uuid = $1 AND actor_uuid = $2`, groupUUID, currentActorUUID).Scan(&archivedAt, &mergedInto)
		if errors.Is(err, sql.ErrNoRows) {
			return "", ErrActorNotFound
		}
		if err != nil {
			return "", fmt.Errorf("resolve actor merge chain: %w", err)
		}
		if !archivedAt.Valid {
			return currentActorUUID, nil
		}
		if !mergedInto.Valid {
			return "", ErrActorNotFound
		}
		currentActorUUID, err = normalizeUUID(mergedInto.String, "merged_into_actor_uuid")
		if err != nil {
			return "", fmt.Errorf("resolve actor merge chain: %w", err)
		}
	}
	return "", fmt.Errorf("%w: actor merge chain is too deep", ErrActorMergeConflict)
}

func mergedActorWasBoundToDeviceTx(ctx context.Context, tx *sql.Tx, groupUUID, actorUUID, deviceID string) (bool, error) {
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
				AND binding.unbound_at IS NOT NULL
				AND binding.unbound_reason = 'actor_merged'
				AND actor.merged_into_actor_uuid IS NOT NULL
		)`, groupUUID, actorUUID, deviceID).Scan(&exists)
	return exists, err
}

func replayActorCommandeeringTx(
	ctx context.Context,
	tx *sql.Tx,
	event LedgerEvent,
	groupUUID string,
	targetActorUUID string,
	deviceID string,
	input CommandeerActorInput,
) (CommandeerActorResult, error) {
	if event.GroupUUID != groupUUID ||
		event.EntityType != "actor" ||
		event.EntityUUID != targetActorUUID ||
		event.EventType != "actor.commandeered" ||
		event.DeviceID != deviceID ||
		!event.EventCreatedAt.Equal(input.EventCreatedAt) ||
		event.ClientSequence != input.ClientSequence ||
		event.PayloadVersion != 1 {
		return CommandeerActorResult{}, ErrLedgerEventConflict
	}

	var payload actorCommandeeringEventPayload
	if err := json.Unmarshal(event.Payload, &payload); err != nil {
		return CommandeerActorResult{}, fmt.Errorf("%w: stored actor merge payload is invalid", ErrLedgerEventConflict)
	}
	payload.SourceActorUUID, _ = normalizeUUID(payload.SourceActorUUID, "source_actor_uuid")
	payload.TargetActorUUID, _ = normalizeUUID(payload.TargetActorUUID, "target_actor_uuid")
	if payload.SourceActorUUID == "" ||
		payload.TargetActorUUID != targetActorUUID ||
		payload.SourceActorUUID == payload.TargetActorUUID ||
		event.ActorUUID != payload.SourceActorUUID {
		return CommandeerActorResult{}, ErrLedgerEventConflict
	}
	canonicalPayload, err := json.Marshal(payload)
	if err != nil {
		return CommandeerActorResult{}, fmt.Errorf("%w: encode stored actor merge payload", ErrLedgerEventConflict)
	}
	payloadHash := sha256.Sum256(canonicalPayload)
	if !bytes.Equal(event.PayloadHash, payloadHash[:]) {
		return CommandeerActorResult{}, ErrLedgerEventConflict
	}

	targetActor, err := loadActorTx(ctx, tx, groupUUID, targetActorUUID)
	if err != nil {
		return CommandeerActorResult{}, err
	}
	return CommandeerActorResult{
		Event:           event,
		GroupUUID:       groupUUID,
		SourceActorUUID: payload.SourceActorUUID,
		TargetActorUUID: targetActorUUID,
		TargetActor:     targetActor,
		Applied:         true,
		Conflict:        event.HadConflict,
		Replayed:        true,
	}, nil
}

func redirectExpenseActorsTx(ctx context.Context, tx *sql.Tx, groupUUID, sourceActorUUID, targetActorUUID string) error {
	rows, err := tx.QueryContext(ctx, `
		SELECT expense_uuid
		FROM expenses AS expense
		WHERE expense.group_uuid = $1
			AND (
				expense.created_by_actor_uuid = $2
				OR expense.payer_actor_uuid = $2
				OR EXISTS (
					SELECT 1
					FROM expense_splits AS split
					WHERE split.group_uuid = expense.group_uuid
						AND split.expense_uuid = expense.expense_uuid
						AND split.actor_uuid = $2
				)
			)
		ORDER BY expense_uuid
		FOR UPDATE OF expense`, groupUUID, sourceActorUUID)
	if err != nil {
		return fmt.Errorf("find expenses for actor merge: %w", err)
	}
	expenseUUIDs := make([]string, 0)
	for rows.Next() {
		var expenseUUID string
		if err := rows.Scan(&expenseUUID); err != nil {
			rows.Close()
			return fmt.Errorf("scan expense for actor merge: %w", err)
		}
		expenseUUIDs = append(expenseUUIDs, expenseUUID)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return fmt.Errorf("iterate expenses for actor merge: %w", err)
	}
	if err := rows.Close(); err != nil {
		return fmt.Errorf("close expenses for actor merge: %w", err)
	}

	for _, expenseUUID := range expenseUUIDs {
		if _, err := tx.ExecContext(ctx, `
			UPDATE expenses
			SET created_by_actor_uuid = CASE WHEN created_by_actor_uuid = $3 THEN $4 ELSE created_by_actor_uuid END,
				payer_actor_uuid = CASE WHEN payer_actor_uuid = $3 THEN $4 ELSE payer_actor_uuid END
			WHERE group_uuid = $1 AND expense_uuid = $2`,
			groupUUID, expenseUUID, sourceActorUUID, targetActorUUID); err != nil {
			return fmt.Errorf("redirect expense actor references: %w", err)
		}

		splitRows, err := tx.QueryContext(ctx, `
			SELECT actor_uuid, amount_minor_units, usd_amount_minor_units, device_id
			FROM expense_splits
			WHERE group_uuid = $1
				AND expense_uuid = $2
				AND actor_uuid IN ($3, $4)
			ORDER BY actor_uuid
			FOR UPDATE`, groupUUID, expenseUUID, sourceActorUUID, targetActorUUID)
		if err != nil {
			return fmt.Errorf("load expense splits for actor merge: %w", err)
		}

		var sourceSplit, targetSplit *ExpenseSplit
		for splitRows.Next() {
			var split ExpenseSplit
			if err := splitRows.Scan(
				&split.ActorUUID,
				&split.AmountMinorUnits,
				&split.USDAmountMinorUnits,
				&split.DeviceID,
			); err != nil {
				splitRows.Close()
				return fmt.Errorf("scan expense split for actor merge: %w", err)
			}
			switch split.ActorUUID {
			case sourceActorUUID:
				sourceSplit = &split
			case targetActorUUID:
				targetSplit = &split
			}
		}
		if err := splitRows.Err(); err != nil {
			splitRows.Close()
			return fmt.Errorf("iterate expense splits for actor merge: %w", err)
		}
		if err := splitRows.Close(); err != nil {
			return fmt.Errorf("close expense splits for actor merge: %w", err)
		}

		switch {
		case sourceSplit != nil && targetSplit == nil:
			if _, err := tx.ExecContext(ctx, `
				UPDATE expense_splits
				SET actor_uuid = $3
				WHERE group_uuid = $1 AND expense_uuid = $2 AND actor_uuid = $4`,
				groupUUID, expenseUUID, targetActorUUID, sourceActorUUID); err != nil {
				return fmt.Errorf("redirect expense split actor: %w", err)
			}
		case sourceSplit != nil && targetSplit != nil:
			combinedAmount, err := addInt64(sourceSplit.AmountMinorUnits, targetSplit.AmountMinorUnits)
			if err != nil {
				return fmt.Errorf("combine expense split amounts: %w", err)
			}
			combinedUSDAmount, err := addInt64(sourceSplit.USDAmountMinorUnits, targetSplit.USDAmountMinorUnits)
			if err != nil {
				return fmt.Errorf("combine USD expense split amounts: %w", err)
			}
			if _, err := tx.ExecContext(ctx, `
				UPDATE expense_splits
				SET amount_minor_units = $3,
					usd_amount_minor_units = $4
				WHERE group_uuid = $1 AND expense_uuid = $2 AND actor_uuid = $5`,
				groupUUID, expenseUUID, combinedAmount, combinedUSDAmount, targetActorUUID); err != nil {
				return fmt.Errorf("combine target expense split: %w", err)
			}
			if _, err := tx.ExecContext(ctx, `
				DELETE FROM expense_splits
				WHERE group_uuid = $1 AND expense_uuid = $2 AND actor_uuid = $3`,
				groupUUID, expenseUUID, sourceActorUUID); err != nil {
				return fmt.Errorf("remove merged expense split: %w", err)
			}
		}
	}

	return nil
}

func redirectPaymentActorsTx(ctx context.Context, tx *sql.Tx, groupUUID, sourceActorUUID, targetActorUUID string, operationAt time.Time) error {
	rows, err := tx.QueryContext(ctx, `
		SELECT payment_uuid, created_by_actor_uuid, from_actor_uuid, to_actor_uuid
		FROM payments
		WHERE group_uuid = $1
			AND (
				created_by_actor_uuid = $2
				OR from_actor_uuid = $2
				OR to_actor_uuid = $2
			)
		ORDER BY payment_uuid
		FOR UPDATE`, groupUUID, sourceActorUUID)
	if err != nil {
		return fmt.Errorf("find payments for actor merge: %w", err)
	}
	payments := make([]paymentActorReferences, 0)
	for rows.Next() {
		var payment paymentActorReferences
		if err := rows.Scan(
			&payment.PaymentUUID,
			&payment.CreatedByActorUUID,
			&payment.FromActorUUID,
			&payment.ToActorUUID,
		); err != nil {
			rows.Close()
			return fmt.Errorf("scan payment for actor merge: %w", err)
		}
		payments = append(payments, payment)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return fmt.Errorf("iterate payments for actor merge: %w", err)
	}
	if err := rows.Close(); err != nil {
		return fmt.Errorf("close payments for actor merge: %w", err)
	}

	for _, payment := range payments {
		fromActorUUID := payment.FromActorUUID
		if fromActorUUID == sourceActorUUID {
			fromActorUUID = targetActorUUID
		}
		toActorUUID := payment.ToActorUUID
		if toActorUUID == sourceActorUUID {
			toActorUUID = targetActorUUID
		}
		createdByActorUUID := payment.CreatedByActorUUID
		if createdByActorUUID == sourceActorUUID {
			createdByActorUUID = targetActorUUID
		}

		if fromActorUUID == toActorUUID {
			// A payment between the two identities has no meaning after the
			// merge. Keep its original endpoints for audit/un-merge purposes,
			// but void it so it contributes nothing to balances.
			if _, err := tx.ExecContext(ctx, `
				UPDATE payments
				SET created_by_actor_uuid = $3,
					updated_at = $4,
					voided_at = COALESCE(voided_at, $4)
				WHERE group_uuid = $1 AND payment_uuid = $2`,
				groupUUID, payment.PaymentUUID, createdByActorUUID, operationAt); err != nil {
				return fmt.Errorf("void merged self-payment: %w", err)
			}
			continue
		}

		if _, err := tx.ExecContext(ctx, `
			UPDATE payments
			SET created_by_actor_uuid = $3,
				from_actor_uuid = $4,
				to_actor_uuid = $5,
				updated_at = $6
			WHERE group_uuid = $1 AND payment_uuid = $2`,
			groupUUID,
			payment.PaymentUUID,
			createdByActorUUID,
			fromActorUUID,
			toActorUUID,
			operationAt); err != nil {
			return fmt.Errorf("redirect payment actor references: %w", err)
		}
	}

	return nil
}

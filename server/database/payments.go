package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"
)

var ErrPaymentNotFound = errors.New("payment not found")

// Payment is the current materialized state of one one-to-one settlement.
// The immutable history for the payment remains in ledger_events.
type Payment struct {
	UUID                string     `json:"uuid"`
	GroupUUID           string     `json:"group_uuid"`
	CreatedByActorUUID  string     `json:"created_by_actor_uuid"`
	CreatedByDeviceID   string     `json:"created_by_device_id"`
	FromActorUUID       string     `json:"from_actor_uuid"`
	ToActorUUID         string     `json:"to_actor_uuid"`
	CurrencyCode        string     `json:"currency_code"`
	AmountMinorUnits    int64      `json:"amount_minor_units"`
	OccurredAt          time.Time  `json:"occurred_at"`
	CreatedAt           time.Time  `json:"created_at"`
	UpdatedAt           time.Time  `json:"updated_at"`
	LatestEventSequence int64      `json:"version"`
	VoidedAt            *time.Time `json:"voided_at,omitempty"`
}

// PaymentEventPayload is the versioned payload stored in a payment ledger
// event. from_actor_uuid is the actor who paid and to_actor_uuid is the actor
// who received the payment; the top-level event actor remains the recorder.
type PaymentEventPayload struct {
	FromActorUUID    string    `json:"from_actor_uuid"`
	ToActorUUID      string    `json:"to_actor_uuid"`
	CurrencyCode     string    `json:"currency_code"`
	AmountMinorUnits int64     `json:"amount_minor_units"`
	OccurredAt       time.Time `json:"occurred_at"`
}

func normalizePaymentPayload(payload *PaymentEventPayload) error {
	var err error
	payload.FromActorUUID, err = normalizeUUID(payload.FromActorUUID, "from_actor_uuid")
	if err != nil {
		return fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
	}
	payload.ToActorUUID, err = normalizeUUID(payload.ToActorUUID, "to_actor_uuid")
	if err != nil {
		return fmt.Errorf("%w: %v", ErrInvalidExpensePayload, err)
	}
	if payload.FromActorUUID == payload.ToActorUUID {
		return fmt.Errorf("%w: from_actor_uuid and to_actor_uuid must be different", ErrInvalidExpensePayload)
	}

	payload.CurrencyCode = strings.ToUpper(strings.TrimSpace(payload.CurrencyCode))
	if len(payload.CurrencyCode) != 3 || !isASCIILetters(payload.CurrencyCode) {
		return fmt.Errorf("%w: currency_code must be three letters", ErrInvalidExpensePayload)
	}
	if payload.AmountMinorUnits <= 0 {
		return fmt.Errorf("%w: amount_minor_units must be positive", ErrInvalidExpensePayload)
	}
	if payload.OccurredAt.IsZero() {
		payload.OccurredAt = time.Now().UTC()
	} else {
		payload.OccurredAt = payload.OccurredAt.UTC()
	}
	return nil
}

func validatePaymentActorsTx(ctx context.Context, tx *sql.Tx, groupUUID string, payload *PaymentEventPayload) error {
	resolvedActors := []*string{&payload.FromActorUUID, &payload.ToActorUUID}
	for _, actorUUID := range resolvedActors {
		resolvedActorUUID, err := resolveActorUUIDTx(ctx, tx, groupUUID, *actorUUID)
		if err != nil {
			return fmt.Errorf("check payment actor: %w", err)
		}
		*actorUUID = resolvedActorUUID
	}
	if payload.FromActorUUID == payload.ToActorUUID {
		return fmt.Errorf("%w: from_actor_uuid and to_actor_uuid must be different after actor merges", ErrInvalidExpensePayload)
	}
	return nil
}

func applyPaymentUpsertTx(ctx context.Context, tx *sql.Tx, event LedgerEvent, payload PaymentEventPayload) error {
	_, err := loadPaymentTx(ctx, tx, event.GroupUUID, event.EntityUUID)
	if err != nil && !errors.Is(err, ErrPaymentNotFound) {
		return err
	}

	if errors.Is(err, ErrPaymentNotFound) {
		_, err = tx.ExecContext(ctx, `
			INSERT INTO payments (
				payment_uuid, group_uuid, created_by_actor_uuid, created_by_device_id,
				from_actor_uuid, to_actor_uuid, currency_code, amount_minor_units,
				occurred_at, created_at, updated_at, latest_event_sequence, voided_at
			)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10, $11, NULL)`,
			event.EntityUUID,
			event.GroupUUID,
			event.ActorUUID,
			event.DeviceID,
			payload.FromActorUUID,
			payload.ToActorUUID,
			payload.CurrencyCode,
			payload.AmountMinorUnits,
			payload.OccurredAt,
			event.EventCreatedAt,
			event.Sequence,
		)
		if err != nil {
			return fmt.Errorf("insert payment projection: %w", err)
		}
	} else {
		_, err = tx.ExecContext(ctx, `
			UPDATE payments
			SET from_actor_uuid = $3,
				to_actor_uuid = $4,
				currency_code = $5,
				amount_minor_units = $6,
				occurred_at = $7,
				updated_at = $8,
				latest_event_sequence = $9,
				voided_at = NULL
			WHERE payment_uuid = $1 AND group_uuid = $2`,
			event.EntityUUID,
			event.GroupUUID,
			payload.FromActorUUID,
			payload.ToActorUUID,
			payload.CurrencyCode,
			payload.AmountMinorUnits,
			payload.OccurredAt,
			event.EventCreatedAt,
			event.Sequence,
		)
		if err != nil {
			return fmt.Errorf("update payment projection: %w", err)
		}
	}

	return nil
}

func applyPaymentVoidedTx(ctx context.Context, tx *sql.Tx, event LedgerEvent) error {
	result, err := tx.ExecContext(ctx, `
		UPDATE payments
		SET updated_at = $3,
			latest_event_sequence = $4,
			voided_at = $3
		WHERE payment_uuid = $1 AND group_uuid = $2`,
		event.EntityUUID,
		event.GroupUUID,
		event.EventCreatedAt,
		event.Sequence,
	)
	if err != nil {
		return fmt.Errorf("void payment projection: %w", err)
	}
	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("check voided payment projection: %w", err)
	}
	if rowsAffected == 0 {
		return ErrPaymentNotFound
	}
	return nil
}

func loadPaymentTx(ctx context.Context, tx *sql.Tx, groupUUID, paymentUUID string) (Payment, error) {
	var payment Payment
	var voidedAt sql.NullTime
	err := tx.QueryRowContext(ctx, `
		SELECT payment_uuid, group_uuid, created_by_actor_uuid, created_by_device_id,
			from_actor_uuid, to_actor_uuid, currency_code, amount_minor_units,
			occurred_at, created_at, updated_at, latest_event_sequence, voided_at
		FROM payments
		WHERE group_uuid = $1 AND payment_uuid = $2`, groupUUID, paymentUUID).Scan(
		&payment.UUID,
		&payment.GroupUUID,
		&payment.CreatedByActorUUID,
		&payment.CreatedByDeviceID,
		&payment.FromActorUUID,
		&payment.ToActorUUID,
		&payment.CurrencyCode,
		&payment.AmountMinorUnits,
		&payment.OccurredAt,
		&payment.CreatedAt,
		&payment.UpdatedAt,
		&payment.LatestEventSequence,
		&voidedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return Payment{}, ErrPaymentNotFound
	}
	if err != nil {
		return Payment{}, fmt.Errorf("load payment: %w", err)
	}
	if voidedAt.Valid {
		payment.VoidedAt = &voidedAt.Time
	}
	return payment, nil
}

func (database *Database) ListPaymentsForDevice(ctx context.Context, groupUUID, deviceID string) ([]Payment, error) {
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

	rows, err := database.db.QueryContext(ctx, `
		SELECT payment_uuid, group_uuid, created_by_actor_uuid, created_by_device_id,
			from_actor_uuid, to_actor_uuid, currency_code, amount_minor_units,
			occurred_at, created_at, updated_at, latest_event_sequence, voided_at
		FROM payments
		WHERE group_uuid = $1
		ORDER BY occurred_at, payment_uuid`, groupUUID)
	if err != nil {
		return nil, fmt.Errorf("query payments: %w", err)
	}
	defer rows.Close()

	payments := make([]Payment, 0)
	for rows.Next() {
		var payment Payment
		var voidedAt sql.NullTime
		if err := rows.Scan(
			&payment.UUID,
			&payment.GroupUUID,
			&payment.CreatedByActorUUID,
			&payment.CreatedByDeviceID,
			&payment.FromActorUUID,
			&payment.ToActorUUID,
			&payment.CurrencyCode,
			&payment.AmountMinorUnits,
			&payment.OccurredAt,
			&payment.CreatedAt,
			&payment.UpdatedAt,
			&payment.LatestEventSequence,
			&voidedAt,
		); err != nil {
			return nil, fmt.Errorf("scan payment: %w", err)
		}
		if voidedAt.Valid {
			payment.VoidedAt = &voidedAt.Time
		}
		payments = append(payments, payment)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate payments: %w", err)
	}
	return payments, nil
}

package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
)

const defaultBalanceCurrencyCode = "USD"

var ErrBalanceOverflow = errors.New("balance exceeds supported amount")

// BalanceMember is the net balance for one actor in one currency. A positive
// value means the group owes the actor; a negative value means the actor owes
// the group.
type BalanceMember struct {
	ActorUUID     string `json:"actor_uuid"`
	DisplayName   string `json:"display_name"`
	NetMinorUnits int64  `json:"net_minor_units"`
}

type SuggestedTransfer struct {
	FromActorUUID    string `json:"from_actor_uuid"`
	ToActorUUID      string `json:"to_actor_uuid"`
	AmountMinorUnits int64  `json:"amount_minor_units"`
}

type CurrencyBalance struct {
	CurrencyCode       string              `json:"currency_code"`
	MemberBalances     []BalanceMember     `json:"member_balances"`
	SuggestedTransfers []SuggestedTransfer `json:"suggested_transfers"`
}

type GroupBalances struct {
	GroupUUID        string            `json:"group_uuid"`
	CurrentActorUUID string            `json:"current_actor_uuid"`
	AsOfSequence     int64             `json:"as_of_sequence"`
	CurrencyBalances []CurrencyBalance `json:"currency_balances"`
}

type balanceActor struct {
	UUID        string
	DisplayName string
}

type balanceSide struct {
	ActorUUID string
	Amount    int64
}

// GetGroupBalancesForDevice calculates current balances from the expense and
// payment projections. It intentionally does not persist balances: they are
// derived data and the ledger sequence makes the result reproducible for the
// client. Every monetary projection already contains its immutable USD value,
// so balances use one settlement currency and never drift when rates change.
func (database *Database) GetGroupBalancesForDevice(ctx context.Context, groupUUID, deviceID string) (GroupBalances, error) {
	groupUUID, err := normalizeUUID(groupUUID, "group_uuid")
	if err != nil {
		return GroupBalances{}, err
	}

	tx, err := database.db.BeginTx(ctx, &sql.TxOptions{
		Isolation: sql.LevelRepeatableRead,
		ReadOnly:  true,
	})
	if err != nil {
		return GroupBalances{}, fmt.Errorf("begin balance read transaction: %w", err)
	}
	defer tx.Rollback()

	var asOfSequence int64
	if err := tx.QueryRowContext(ctx, `
		SELECT latest_event_sequence
		FROM groups
		WHERE uuid = $1`, groupUUID).Scan(&asOfSequence); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return GroupBalances{}, ErrGroupNotFound
		}
		return GroupBalances{}, fmt.Errorf("read group balance sequence: %w", err)
	}

	member, err := activeGroupMembershipTx(ctx, tx, groupUUID, deviceID)
	if err != nil {
		return GroupBalances{}, fmt.Errorf("check group membership: %w", err)
	}
	if !member {
		return GroupBalances{}, ErrGroupMembershipDenied
	}

	var currentActorUUID string
	if err := tx.QueryRowContext(ctx, `
		SELECT actor_uuid
		FROM actor_device_bindings
		WHERE group_uuid = $1
			AND device_id = $2
			AND unbound_at IS NULL`, groupUUID, deviceID).Scan(&currentActorUUID); err != nil {
		return GroupBalances{}, fmt.Errorf("find current group actor: %w", err)
	}

	actors, err := loadBalanceActors(ctx, tx, groupUUID)
	if err != nil {
		return GroupBalances{}, err
	}
	if _, ok := actors[currentActorUUID]; !ok {
		actors[currentActorUUID] = balanceActor{UUID: currentActorUUID}
	}

	amounts := make(map[string]int64, len(actors))
	for actorUUID := range actors {
		amounts[actorUUID] = 0
	}

	rows, err := tx.QueryContext(ctx, `
		SELECT e.expense_uuid, e.usd_total_minor_units, e.payer_actor_uuid,
			s.actor_uuid, s.usd_amount_minor_units
		FROM expenses AS e
		LEFT JOIN expense_splits AS s
			ON s.group_uuid = e.group_uuid
			AND s.expense_uuid = e.expense_uuid
		WHERE e.group_uuid = $1
			AND e.voided_at IS NULL
		ORDER BY e.expense_uuid, s.actor_uuid`, groupUUID)
	if err != nil {
		return GroupBalances{}, fmt.Errorf("query expenses for balances: %w", err)
	}
	seenExpenses := make(map[string]struct{})
	for rows.Next() {
		var expenseUUID, payerActorUUID string
		var usdTotalMinorUnits int64
		var splitActorUUID sql.NullString
		var splitUSDAmountMinorUnits sql.NullInt64

		if err := rows.Scan(
			&expenseUUID,
			&usdTotalMinorUnits,
			&payerActorUUID,
			&splitActorUUID,
			&splitUSDAmountMinorUnits,
		); err != nil {
			return GroupBalances{}, fmt.Errorf("scan expense balance row: %w", err)
		}

		if _, seen := seenExpenses[expenseUUID]; !seen {
			if err := addBalance(amounts, payerActorUUID, usdTotalMinorUnits); err != nil {
				return GroupBalances{}, fmt.Errorf("credit expense payer: %w", err)
			}
			seenExpenses[expenseUUID] = struct{}{}
		}

		if splitActorUUID.Valid {
			if !splitUSDAmountMinorUnits.Valid {
				return GroupBalances{}, fmt.Errorf("expense %s has an invalid split amount", expenseUUID)
			}
			if err := addBalance(amounts, splitActorUUID.String, -splitUSDAmountMinorUnits.Int64); err != nil {
				return GroupBalances{}, fmt.Errorf("debit expense split: %w", err)
			}
		}
	}
	if err := rows.Err(); err != nil {
		return GroupBalances{}, fmt.Errorf("iterate expense balance rows: %w", err)
	}
	if err := rows.Close(); err != nil {
		return GroupBalances{}, fmt.Errorf("close expense balance rows: %w", err)
	}

	paymentRows, err := tx.QueryContext(ctx, `
		SELECT usd_amount_minor_units, from_actor_uuid, to_actor_uuid
		FROM payments
		WHERE group_uuid = $1
			AND voided_at IS NULL
		ORDER BY payment_uuid`, groupUUID)
	if err != nil {
		return GroupBalances{}, fmt.Errorf("query payments for balances: %w", err)
	}
	for paymentRows.Next() {
		var fromActorUUID, toActorUUID string
		var usdAmountMinorUnits int64
		if err := paymentRows.Scan(&usdAmountMinorUnits, &fromActorUUID, &toActorUUID); err != nil {
			paymentRows.Close()
			return GroupBalances{}, fmt.Errorf("scan payment balance row: %w", err)
		}

		if err := applyPaymentBalance(amounts, fromActorUUID, toActorUUID, usdAmountMinorUnits); err != nil {
			paymentRows.Close()
			return GroupBalances{}, fmt.Errorf("apply payment balance: %w", err)
		}
	}
	if err := paymentRows.Err(); err != nil {
		paymentRows.Close()
		return GroupBalances{}, fmt.Errorf("iterate payment balance rows: %w", err)
	}
	if err := paymentRows.Close(); err != nil {
		return GroupBalances{}, fmt.Errorf("close payment balance rows: %w", err)
	}

	if err := validateBalanceTotal(amounts); err != nil {
		return GroupBalances{}, fmt.Errorf("validate %s balances: %w", defaultBalanceCurrencyCode, err)
	}

	actorIDs := make([]string, 0, len(amounts))
	for actorUUID := range amounts {
		actorIDs = append(actorIDs, actorUUID)
	}
	sort.Strings(actorIDs)

	memberBalances := make([]BalanceMember, 0, len(actorIDs))
	for _, actorUUID := range actorIDs {
		memberBalances = append(memberBalances, BalanceMember{
			ActorUUID:     actorUUID,
			DisplayName:   actors[actorUUID].DisplayName,
			NetMinorUnits: amounts[actorUUID],
		})
	}

	currencyBalances := []CurrencyBalance{{
		CurrencyCode:       defaultBalanceCurrencyCode,
		MemberBalances:     memberBalances,
		SuggestedTransfers: simplifyTransfers(amounts),
	}}

	if err := tx.Commit(); err != nil {
		return GroupBalances{}, fmt.Errorf("commit balance read transaction: %w", err)
	}

	return GroupBalances{
		GroupUUID:        groupUUID,
		CurrentActorUUID: currentActorUUID,
		AsOfSequence:     asOfSequence,
		CurrencyBalances: currencyBalances,
	}, nil
}

func loadBalanceActors(ctx context.Context, tx *sql.Tx, groupUUID string) (map[string]balanceActor, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT actor_uuid, COALESCE(display_name, '')
		FROM group_actors
		WHERE group_uuid = $1
			AND archived_at IS NULL
		ORDER BY created_at, actor_uuid`, groupUUID)
	if err != nil {
		return nil, fmt.Errorf("query group actors for balances: %w", err)
	}
	defer rows.Close()

	actors := make(map[string]balanceActor)
	for rows.Next() {
		var actor balanceActor
		if err := rows.Scan(&actor.UUID, &actor.DisplayName); err != nil {
			return nil, fmt.Errorf("scan group actor for balances: %w", err)
		}
		actors[actor.UUID] = actor
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate group actors for balances: %w", err)
	}
	return actors, nil
}

func addBalance(amounts map[string]int64, actorUUID string, delta int64) error {
	current := amounts[actorUUID]
	const maxInt64 = int64(1<<63 - 1)
	const minInt64 = -1 << 63

	if delta > 0 && current > maxInt64-delta {
		return ErrBalanceOverflow
	}
	if delta < 0 && current < minInt64-delta {
		return ErrBalanceOverflow
	}
	amounts[actorUUID] = current + delta
	return nil
}

// applyPaymentBalance moves value from the recipient's claim to the sender's
// balance. A negative balance means the actor owes money, so a debtor paying a
// creditor increases the sender's balance and decreases the recipient's.
func applyPaymentBalance(amounts map[string]int64, fromActorUUID, toActorUUID string, usdAmountMinorUnits int64) error {
	if err := addBalance(amounts, fromActorUUID, usdAmountMinorUnits); err != nil {
		return fmt.Errorf("credit payment sender: %w", err)
	}
	if err := addBalance(amounts, toActorUUID, -usdAmountMinorUnits); err != nil {
		return fmt.Errorf("debit payment recipient: %w", err)
	}
	return nil
}

func validateBalanceTotal(amounts map[string]int64) error {
	var total int64
	for _, amount := range amounts {
		var err error
		total, err = addInt64(total, amount)
		if err != nil {
			return err
		}
	}
	if total != 0 {
		return fmt.Errorf("net balance total is %d instead of zero", total)
	}
	return nil
}

func addInt64(left, right int64) (int64, error) {
	const maxInt64 = int64(1<<63 - 1)
	const minInt64 = -1 << 63

	if right > 0 && left > maxInt64-right {
		return 0, ErrBalanceOverflow
	}
	if right < 0 && left < minInt64-right {
		return 0, ErrBalanceOverflow
	}
	return left + right, nil
}

func simplifyTransfers(amounts map[string]int64) []SuggestedTransfer {
	debtors := make([]balanceSide, 0)
	creditors := make([]balanceSide, 0)

	for actorUUID, amount := range amounts {
		switch {
		case amount < 0:
			// A BIGINT expense total cannot realistically produce MinInt64,
			// and balances are overflow-checked while being accumulated.
			debtors = append(debtors, balanceSide{ActorUUID: actorUUID, Amount: -amount})
		case amount > 0:
			creditors = append(creditors, balanceSide{ActorUUID: actorUUID, Amount: amount})
		}
	}

	sort.Slice(debtors, func(i, j int) bool {
		return debtors[i].ActorUUID < debtors[j].ActorUUID
	})
	sort.Slice(creditors, func(i, j int) bool {
		return creditors[i].ActorUUID < creditors[j].ActorUUID
	})

	transfers := make([]SuggestedTransfer, 0)
	debtorIndex, creditorIndex := 0, 0
	for debtorIndex < len(debtors) && creditorIndex < len(creditors) {
		amount := debtors[debtorIndex].Amount
		if creditors[creditorIndex].Amount < amount {
			amount = creditors[creditorIndex].Amount
		}

		transfers = append(transfers, SuggestedTransfer{
			FromActorUUID:    debtors[debtorIndex].ActorUUID,
			ToActorUUID:      creditors[creditorIndex].ActorUUID,
			AmountMinorUnits: amount,
		})

		debtors[debtorIndex].Amount -= amount
		creditors[creditorIndex].Amount -= amount
		if debtors[debtorIndex].Amount == 0 {
			debtorIndex++
		}
		if creditors[creditorIndex].Amount == 0 {
			creditorIndex++
		}
	}

	return transfers
}

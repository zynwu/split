package database

import "testing"

func TestApplyPaymentBalanceReducesDebt(t *testing.T) {
	tests := []struct {
		name   string
		amount int64
		want   map[string]int64
	}{
		{
			name:   "full settlement",
			amount: 12_500,
			want:   map[string]int64{"debtor": 0, "creditor": 0},
		},
		{
			name:   "partial settlement",
			amount: 4_000,
			want:   map[string]int64{"debtor": -8_500, "creditor": 8_500},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			balances := map[string]int64{"debtor": -12_500, "creditor": 12_500}
			if err := applyPaymentBalance(balances, "debtor", "creditor", test.amount); err != nil {
				t.Fatalf("applyPaymentBalance() error = %v", err)
			}

			for actorUUID, want := range test.want {
				if got := balances[actorUUID]; got != want {
					t.Errorf("balance for %s = %d, want %d", actorUUID, got, want)
				}
			}
		})
	}
}

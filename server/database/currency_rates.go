package database

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"strings"
	"time"
)

const currencyRateDateFormat = "2006-01-02"

const currencyRateRefreshLockKey int64 = 412983761

var (
	ErrCurrencyRatesNotFound       = errors.New("currency rates are not available")
	ErrCurrencyRateNotFound        = errors.New("currency rate is not available")
	ErrInvalidCurrencyCode         = errors.New("invalid currency code")
	ErrInvalidCurrencyRate         = errors.New("invalid currency rate")
	ErrCurrencyConversionOverflow  = errors.New("currency conversion exceeds supported amount")
	ErrCurrencyRateRefreshInFlight = errors.New("currency rate refresh is already in progress")
)

// CurrencyRateInput is one provider quote in a daily snapshot. Rate is kept
// as a decimal string so no floating-point conversion occurs before it reaches
// PostgreSQL's exact NUMERIC type.
type CurrencyRateInput struct {
	QuoteCurrencyCode string
	Rate              string
	ProviderRateDate  string
}

// CurrencyRate is returned by the rates API. The rate is a decimal string,
// representing how many quote-currency units equal one requested base unit.
type CurrencyRate struct {
	QuoteCurrencyCode string `json:"quote_currency_code"`
	Rate              string `json:"rate"`
}

type CurrencyRateSnapshot struct {
	SnapshotDate     string         `json:"rate_date"`
	BaseCurrencyCode string         `json:"base_currency_code"`
	Rates            []CurrencyRate `json:"rates"`
	Source           string         `json:"source"`
	FetchedAt        time.Time      `json:"fetched_at"`
}

type storedCurrencyRate struct {
	QuoteCurrencyCode string
	Rate              *big.Rat
}

// CurrencyAmountLock is the immutable conversion chosen for a monetary
// ledger event when it is accepted by the server. ExchangeRateToUSD means
// USD units per one unit of the event's native currency.
type CurrencyAmountLock struct {
	ExchangeRateToUSD   string
	USDAmountMinorUnits int64
	RateSnapshotDate    string
}

// NormalizeCurrencyCode canonicalizes an ISO-4217-style three-letter code.
// The database intentionally does not maintain a currency catalogue yet; the
// upstream provider determines which codes have available rates.
func NormalizeCurrencyCode(value string) (string, error) {
	value = strings.ToUpper(strings.TrimSpace(value))
	if len(value) != 3 || !isASCIILetters(value) {
		return "", fmt.Errorf("%w: expected three ASCII letters", ErrInvalidCurrencyCode)
	}
	return value, nil
}

func validateCurrencyRateDate(value string, field string) error {
	if _, err := time.Parse(currencyRateDateFormat, value); err != nil {
		return fmt.Errorf("%s must be YYYY-MM-DD", field)
	}
	return nil
}

func normalizeCurrencyRateInput(input CurrencyRateInput) (CurrencyRateInput, error) {
	quote, err := NormalizeCurrencyCode(input.QuoteCurrencyCode)
	if err != nil {
		return CurrencyRateInput{}, err
	}
	if err := validateCurrencyRateDate(input.ProviderRateDate, "provider_rate_date"); err != nil {
		return CurrencyRateInput{}, err
	}

	rateText := strings.TrimSpace(input.Rate)
	rate, ok := new(big.Rat).SetString(rateText)
	if !ok || rate.Sign() <= 0 {
		return CurrencyRateInput{}, fmt.Errorf("%w: rate must be a positive decimal", ErrInvalidCurrencyRate)
	}

	return CurrencyRateInput{
		QuoteCurrencyCode: quote,
		Rate:              rateText,
		ProviderRateDate:  input.ProviderRateDate,
	}, nil
}

// StoreCurrencyRateSnapshot replaces one complete daily snapshot atomically.
// A PostgreSQL advisory lock makes concurrent API instances avoid fetching and
// writing the same snapshot at the same time. The caller can retry when the
// lock is held by another instance.
func (database *Database) StoreCurrencyRateSnapshot(
	ctx context.Context,
	snapshotDate string,
	baseCurrencyCode string,
	source string,
	fetchedAt time.Time,
	rates []CurrencyRateInput,
) error {
	if err := validateCurrencyRateDate(snapshotDate, "snapshot_date"); err != nil {
		return err
	}
	baseCurrencyCode, err := NormalizeCurrencyCode(baseCurrencyCode)
	if err != nil {
		return err
	}
	source = strings.TrimSpace(source)
	if source == "" || len([]rune(source)) > 255 {
		return fmt.Errorf("source must be between 1 and 255 characters")
	}
	if fetchedAt.IsZero() {
		fetchedAt = time.Now().UTC()
	} else {
		fetchedAt = fetchedAt.UTC()
	}
	if len(rates) == 0 {
		return fmt.Errorf("%w: snapshot must contain at least one rate", ErrCurrencyRatesNotFound)
	}

	normalizedRates := make(map[string]CurrencyRateInput, len(rates)+1)
	for _, input := range rates {
		normalized, normalizeErr := normalizeCurrencyRateInput(input)
		if normalizeErr != nil {
			return normalizeErr
		}
		normalizedRate, normalizedRateOK := new(big.Rat).SetString(normalized.Rate)
		if !normalizedRateOK {
			return fmt.Errorf("%w: rate must be a positive decimal", ErrInvalidCurrencyRate)
		}
		if normalized.QuoteCurrencyCode == baseCurrencyCode {
			if normalizedRate.Cmp(big.NewRat(1, 1)) != 0 {
				return fmt.Errorf("%w: base currency rate must equal 1", ErrInvalidCurrencyRate)
			}
		}
		if existing, ok := normalizedRates[normalized.QuoteCurrencyCode]; ok {
			existingRate, existingRateOK := new(big.Rat).SetString(existing.Rate)
			if !existingRateOK || existingRate.Cmp(normalizedRate) != 0 || existing.ProviderRateDate != normalized.ProviderRateDate {
				return fmt.Errorf("%w: duplicate quote currency %s", ErrInvalidCurrencyRate, normalized.QuoteCurrencyCode)
			}
		}
		normalizedRates[normalized.QuoteCurrencyCode] = normalized
	}

	identityRate := CurrencyRateInput{
		QuoteCurrencyCode: baseCurrencyCode,
		Rate:              "1",
		ProviderRateDate:  snapshotDate,
	}
	if existing, ok := normalizedRates[baseCurrencyCode]; ok {
		identityRate = existing
	}
	normalizedRates[baseCurrencyCode] = identityRate

	quotes := make([]string, 0, len(normalizedRates))
	for quote := range normalizedRates {
		quotes = append(quotes, quote)
	}
	sort.Strings(quotes)

	tx, err := database.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin currency rate snapshot transaction: %w", err)
	}
	defer tx.Rollback()

	var acquired bool
	if err := tx.QueryRowContext(ctx, `
		SELECT pg_try_advisory_xact_lock($1)`, currencyRateRefreshLockKey).Scan(&acquired); err != nil {
		return fmt.Errorf("acquire currency rate refresh lock: %w", err)
	}
	if !acquired {
		return ErrCurrencyRateRefreshInFlight
	}

	if _, err := tx.ExecContext(ctx, `
		DELETE FROM currency_rates
		WHERE snapshot_date = $1::date
			AND base_currency_code = $2`, snapshotDate, baseCurrencyCode); err != nil {
		return fmt.Errorf("replace existing currency rate snapshot: %w", err)
	}

	for _, quote := range quotes {
		input := normalizedRates[quote]
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO currency_rates (
				snapshot_date, base_currency_code, quote_currency_code, rate,
				provider_rate_date, source, fetched_at
			)
			VALUES ($1::date, $2, $3, $4::numeric, $5::date, $6, $7)`,
			snapshotDate,
			baseCurrencyCode,
			input.QuoteCurrencyCode,
			input.Rate,
			input.ProviderRateDate,
			source,
			fetchedAt,
		); err != nil {
			return fmt.Errorf("insert %s currency rate: %w", quote, err)
		}
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit currency rate snapshot: %w", err)
	}
	return nil
}

// LatestCurrencyRateSnapshotDate returns the most recent snapshot date for a
// stored base currency. It is used by the scheduler to avoid refetching the
// same Pacific calendar day after every process restart.
func (database *Database) LatestCurrencyRateSnapshotDate(ctx context.Context, baseCurrencyCode string) (string, error) {
	baseCurrencyCode, err := NormalizeCurrencyCode(baseCurrencyCode)
	if err != nil {
		return "", err
	}

	var snapshotDate sql.NullString
	err = database.db.QueryRowContext(ctx, `
		SELECT MAX(snapshot_date)::text
		FROM currency_rates
		WHERE base_currency_code = $1`, baseCurrencyCode).Scan(&snapshotDate)
	if err != nil {
		return "", fmt.Errorf("find latest currency rate snapshot: %w", err)
	}
	if !snapshotDate.Valid || snapshotDate.String == "" {
		return "", ErrCurrencyRatesNotFound
	}
	return snapshotDate.String, nil
}

// GetCurrencyRateSnapshot returns direct rates for the configured stored base,
// or derives a requested base/quote cross-rate using exact rational arithmetic.
// The database stores one canonical base (USD by default), while callers can
// ask for CAD->EUR without requiring another provider fetch or schema change.
func (database *Database) GetCurrencyRateSnapshot(
	ctx context.Context,
	storedBaseCurrencyCode string,
	requestedBaseCurrencyCode string,
	snapshotDate string,
	quotes []string,
) (CurrencyRateSnapshot, error) {
	storedBaseCurrencyCode, err := NormalizeCurrencyCode(storedBaseCurrencyCode)
	if err != nil {
		return CurrencyRateSnapshot{}, err
	}
	if strings.TrimSpace(requestedBaseCurrencyCode) == "" {
		requestedBaseCurrencyCode = storedBaseCurrencyCode
	}
	requestedBaseCurrencyCode, err = NormalizeCurrencyCode(requestedBaseCurrencyCode)
	if err != nil {
		return CurrencyRateSnapshot{}, err
	}
	if snapshotDate != "" {
		if err := validateCurrencyRateDate(snapshotDate, "date"); err != nil {
			return CurrencyRateSnapshot{}, err
		}
	} else {
		snapshotDate, err = database.LatestCurrencyRateSnapshotDate(ctx, storedBaseCurrencyCode)
		if err != nil {
			return CurrencyRateSnapshot{}, err
		}
	}

	rows, err := database.db.QueryContext(ctx, `
		SELECT quote_currency_code, rate::text, source, fetched_at
		FROM currency_rates
		WHERE snapshot_date = $1::date
			AND base_currency_code = $2
		ORDER BY quote_currency_code`, snapshotDate, storedBaseCurrencyCode)
	if err != nil {
		return CurrencyRateSnapshot{}, fmt.Errorf("query currency rate snapshot: %w", err)
	}
	defer rows.Close()

	directRates := make(map[string]storedCurrencyRate)
	var source string
	var fetchedAt time.Time
	for rows.Next() {
		var quoteCurrencyCode, rateText, rowSource string
		var rowFetchedAt time.Time
		if err := rows.Scan(&quoteCurrencyCode, &rateText, &rowSource, &rowFetchedAt); err != nil {
			return CurrencyRateSnapshot{}, fmt.Errorf("scan currency rate: %w", err)
		}
		rate, ok := new(big.Rat).SetString(rateText)
		if !ok || rate.Sign() <= 0 {
			return CurrencyRateSnapshot{}, fmt.Errorf("stored currency rate %s is invalid", quoteCurrencyCode)
		}
		directRates[quoteCurrencyCode] = storedCurrencyRate{
			QuoteCurrencyCode: quoteCurrencyCode,
			Rate:              rate,
		}
		if source == "" {
			source = rowSource
			fetchedAt = rowFetchedAt
		}
	}
	if err := rows.Err(); err != nil {
		return CurrencyRateSnapshot{}, fmt.Errorf("iterate currency rates: %w", err)
	}
	if len(directRates) == 0 {
		return CurrencyRateSnapshot{}, ErrCurrencyRatesNotFound
	}

	baseRate, ok := directRates[requestedBaseCurrencyCode]
	if !ok {
		return CurrencyRateSnapshot{}, fmt.Errorf("%w: %s", ErrCurrencyRateNotFound, requestedBaseCurrencyCode)
	}

	requestedQuotes, err := normalizeCurrencyQuoteFilter(quotes)
	if err != nil {
		return CurrencyRateSnapshot{}, err
	}
	if len(requestedQuotes) == 0 {
		requestedQuotes = make([]string, 0, len(directRates))
		for quote := range directRates {
			requestedQuotes = append(requestedQuotes, quote)
		}
		if _, ok := directRates[requestedBaseCurrencyCode]; !ok {
			requestedQuotes = append(requestedQuotes, requestedBaseCurrencyCode)
		}
		sort.Strings(requestedQuotes)
	}

	resultRates := make([]CurrencyRate, 0, len(requestedQuotes))
	for _, quote := range requestedQuotes {
		if quote == requestedBaseCurrencyCode {
			resultRates = append(resultRates, CurrencyRate{
				QuoteCurrencyCode: quote,
				Rate:              "1",
			})
			continue
		}

		quoteRate, ok := directRates[quote]
		if !ok {
			return CurrencyRateSnapshot{}, fmt.Errorf("%w: %s", ErrCurrencyRateNotFound, quote)
		}

		convertedRate := quoteRate.Rate
		if requestedBaseCurrencyCode != storedBaseCurrencyCode {
			convertedRate = new(big.Rat).Quo(quoteRate.Rate, baseRate.Rate)
		}
		resultRates = append(resultRates, CurrencyRate{
			QuoteCurrencyCode: quote,
			Rate:              formatCurrencyRate(convertedRate),
		})
	}

	return CurrencyRateSnapshot{
		SnapshotDate:     snapshotDate,
		BaseCurrencyCode: requestedBaseCurrencyCode,
		Rates:            resultRates,
		Source:           source,
		FetchedAt:        fetchedAt,
	}, nil
}

// resolveCurrencyAmountToUSDTx resolves the latest stored USD snapshot while
// the ledger transaction is open. The provider stores quote units per USD, so
// a native-currency amount is converted with the reciprocal rate. USD itself
// is always an exact identity conversion and does not require a snapshot.
func resolveCurrencyAmountToUSDTx(
	ctx context.Context,
	tx *sql.Tx,
	currencyCode string,
	amountMinorUnits int64,
) (CurrencyAmountLock, error) {
	currencyCode, err := NormalizeCurrencyCode(currencyCode)
	if err != nil {
		return CurrencyAmountLock{}, err
	}
	if amountMinorUnits <= 0 {
		return CurrencyAmountLock{}, fmt.Errorf("%w: amount must be positive", ErrInvalidCurrencyRate)
	}
	if currencyCode == "USD" {
		return CurrencyAmountLock{
			ExchangeRateToUSD:   "1",
			USDAmountMinorUnits: amountMinorUnits,
		}, nil
	}

	var snapshotDate, providerRateText string
	err = tx.QueryRowContext(ctx, `
		WITH latest_snapshot AS (
			SELECT snapshot_date
			FROM currency_rates
			WHERE base_currency_code = 'USD'
				AND quote_currency_code = $1
			GROUP BY snapshot_date
			ORDER BY snapshot_date DESC
			LIMIT 1
		)
		SELECT rates.snapshot_date::text, rates.rate::text
		FROM currency_rates AS rates
		JOIN latest_snapshot
			ON latest_snapshot.snapshot_date = rates.snapshot_date
		WHERE rates.base_currency_code = 'USD'
			AND rates.quote_currency_code = $1`, currencyCode).Scan(&snapshotDate, &providerRateText)
	if errors.Is(err, sql.ErrNoRows) {
		return CurrencyAmountLock{}, fmt.Errorf("%w: %s", ErrCurrencyRateNotFound, currencyCode)
	}
	if err != nil {
		return CurrencyAmountLock{}, fmt.Errorf("load %s to USD rate: %w", currencyCode, err)
	}

	providerRate, ok := new(big.Rat).SetString(providerRateText)
	if !ok || providerRate.Sign() <= 0 {
		return CurrencyAmountLock{}, fmt.Errorf("%w: stored rate for %s is invalid", ErrInvalidCurrencyRate, currencyCode)
	}
	rateToUSD := new(big.Rat).Quo(big.NewRat(1, 1), providerRate)
	rateText := formatCurrencyRate(rateToUSD)
	storedRate, ok := new(big.Rat).SetString(rateText)
	if !ok {
		return CurrencyAmountLock{}, fmt.Errorf("%w: calculated rate for %s is invalid", ErrInvalidCurrencyRate, currencyCode)
	}
	usdAmountMinorUnits, err := roundCurrencyAmount(amountMinorUnits, storedRate)
	if err != nil {
		return CurrencyAmountLock{}, err
	}

	return CurrencyAmountLock{
		ExchangeRateToUSD:   rateText,
		USDAmountMinorUnits: usdAmountMinorUnits,
		RateSnapshotDate:    snapshotDate,
	}, nil
}

func roundCurrencyAmount(amountMinorUnits int64, rate *big.Rat) (int64, error) {
	if amountMinorUnits <= 0 || rate == nil || rate.Sign() <= 0 {
		return 0, fmt.Errorf("%w: amount and rate must be positive", ErrInvalidCurrencyRate)
	}

	numerator := new(big.Int).Mul(big.NewInt(amountMinorUnits), rate.Num())
	quotient, remainder := new(big.Int), new(big.Int)
	quotient.QuoRem(numerator, rate.Denom(), remainder)
	if new(big.Int).Lsh(remainder, 1).Cmp(rate.Denom()) >= 0 {
		quotient.Add(quotient, big.NewInt(1))
	}
	if !quotient.IsInt64() {
		return 0, ErrCurrencyConversionOverflow
	}
	return quotient.Int64(), nil
}

func currencyLockFromEvent(event LedgerEvent) (CurrencyAmountLock, error) {
	rateText := strings.TrimSpace(event.ExchangeRateToUSD)
	rate, ok := new(big.Rat).SetString(rateText)
	if !ok || rate.Sign() <= 0 {
		return CurrencyAmountLock{}, fmt.Errorf("%w: ledger event has an invalid exchange rate", ErrInvalidCurrencyRate)
	}
	if event.USDAmountMinorUnits < 0 {
		return CurrencyAmountLock{}, fmt.Errorf("%w: ledger event has a negative USD amount", ErrInvalidCurrencyRate)
	}
	if event.RateSnapshotDate != "" {
		if err := validateCurrencyRateDate(event.RateSnapshotDate, "rate_snapshot_date"); err != nil {
			return CurrencyAmountLock{}, err
		}
	}
	return CurrencyAmountLock{
		ExchangeRateToUSD:   rateText,
		USDAmountMinorUnits: event.USDAmountMinorUnits,
		RateSnapshotDate:    event.RateSnapshotDate,
	}, nil
}

func nullableRateSnapshotDate(value string) any {
	if value == "" {
		return nil
	}
	return value
}

// allocateLockedUSDSplits assigns the locked expense total to its native
// currency splits. The largest-remainder rule makes the result deterministic,
// preserves the exact locked total, and remains stable across retries.
func allocateLockedUSDSplits(totalMinorUnits, usdTotalMinorUnits int64, splits []ExpensePayloadSplit) ([]int64, error) {
	if totalMinorUnits <= 0 || usdTotalMinorUnits < 0 {
		return nil, fmt.Errorf("%w: invalid expense currency lock", ErrInvalidCurrencyRate)
	}

	var splitTotal int64
	for _, split := range splits {
		if split.AmountMinorUnits < 0 {
			return nil, fmt.Errorf("%w: split amount cannot be negative", ErrInvalidExpensePayload)
		}
		var err error
		splitTotal, err = addInt64(splitTotal, split.AmountMinorUnits)
		if err != nil {
			return nil, fmt.Errorf("%w: split total overflow", ErrCurrencyConversionOverflow)
		}
	}
	if splitTotal != totalMinorUnits {
		return nil, fmt.Errorf("%w: split amounts must equal total_minor_units", ErrInvalidExpensePayload)
	}

	type splitRemainder struct {
		index     int
		remainder *big.Int
	}

	denominator := big.NewInt(totalMinorUnits)
	allocated := make([]int64, len(splits))
	remainders := make([]splitRemainder, 0, len(splits))
	var floorTotal int64
	for index, split := range splits {
		numerator := new(big.Int).Mul(big.NewInt(usdTotalMinorUnits), big.NewInt(split.AmountMinorUnits))
		quotient, remainder := new(big.Int), new(big.Int)
		quotient.QuoRem(numerator, denominator, remainder)
		if !quotient.IsInt64() {
			return nil, ErrCurrencyConversionOverflow
		}
		allocated[index] = quotient.Int64()
		var err error
		floorTotal, err = addInt64(floorTotal, allocated[index])
		if err != nil {
			return nil, fmt.Errorf("%w: split allocation overflow", ErrCurrencyConversionOverflow)
		}
		remainders = append(remainders, splitRemainder{index: index, remainder: remainder})
	}

	if floorTotal > usdTotalMinorUnits {
		return nil, fmt.Errorf("%w: split allocation exceeded locked total", ErrCurrencyConversionOverflow)
	}
	remaining := usdTotalMinorUnits - floorTotal
	sort.Slice(remainders, func(i, j int) bool {
		comparison := remainders[i].remainder.Cmp(remainders[j].remainder)
		if comparison != 0 {
			return comparison > 0
		}
		return splits[remainders[i].index].ActorUUID < splits[remainders[j].index].ActorUUID
	})
	if remaining > int64(len(remainders)) {
		return nil, fmt.Errorf("%w: split allocation remainder is invalid", ErrCurrencyConversionOverflow)
	}
	for index := int64(0); index < remaining; index++ {
		splitIndex := remainders[index].index
		var err error
		allocated[splitIndex], err = addInt64(allocated[splitIndex], 1)
		if err != nil {
			return nil, fmt.Errorf("%w: split allocation overflow", ErrCurrencyConversionOverflow)
		}
	}

	return allocated, nil
}

func normalizeCurrencyQuoteFilter(quotes []string) ([]string, error) {
	if len(quotes) == 0 {
		return nil, nil
	}

	seen := make(map[string]struct{}, len(quotes))
	result := make([]string, 0, len(quotes))
	for _, quote := range quotes {
		normalized, err := NormalizeCurrencyCode(quote)
		if err != nil {
			return nil, err
		}
		if _, ok := seen[normalized]; ok {
			continue
		}
		seen[normalized] = struct{}{}
		result = append(result, normalized)
	}
	sort.Strings(result)
	return result, nil
}

func formatCurrencyRate(rate *big.Rat) string {
	formatted := rate.FloatString(18)
	formatted = strings.TrimRight(formatted, "0")
	formatted = strings.TrimRight(formatted, ".")
	if formatted == "" {
		return "0"
	}
	return formatted
}

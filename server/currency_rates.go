package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"server/database"

	_ "time/tzdata"
)

const (
	defaultCurrencyRatesBase      = "USD"
	defaultCurrencyRatesSourceURL = "https://api.frankfurter.dev/v2/rates"
	defaultCurrencyRatesSource    = "frankfurter"
	defaultCurrencyRatesTimezone  = "America/Los_Angeles"
	currencyRateDateFormat        = "2006-01-02"
)

type currencyRateService struct {
	database   *database.Database
	base       string
	source     string
	sourceURL  string
	timezone   *time.Location
	client     *http.Client
	enabled    bool
	retryDelay time.Duration
}

type frankfurterRate struct {
	Date  string      `json:"date"`
	Base  string      `json:"base"`
	Quote string      `json:"quote"`
	Rate  json.Number `json:"rate"`
}

func newCurrencyRateService(db *database.Database) (*currencyRateService, error) {
	base, err := database.NormalizeCurrencyCode(valueOrDefault(os.Getenv("CURRENCY_RATES_BASE"), defaultCurrencyRatesBase))
	if err != nil {
		return nil, fmt.Errorf("configure currency rate base: %w", err)
	}

	timezoneName := valueOrDefault(os.Getenv("CURRENCY_RATES_TIMEZONE"), defaultCurrencyRatesTimezone)
	timezone, err := time.LoadLocation(timezoneName)
	if err != nil {
		return nil, fmt.Errorf("load currency rate timezone %q: %w", timezoneName, err)
	}

	enabled := true
	if rawEnabled := strings.TrimSpace(os.Getenv("CURRENCY_RATES_ENABLED")); rawEnabled != "" {
		enabled, err = strconv.ParseBool(rawEnabled)
		if err != nil {
			return nil, fmt.Errorf("CURRENCY_RATES_ENABLED must be a boolean: %w", err)
		}
	}

	return &currencyRateService{
		database:  db,
		base:      base,
		source:    defaultCurrencyRatesSource,
		sourceURL: valueOrDefault(os.Getenv("CURRENCY_RATES_SOURCE_URL"), defaultCurrencyRatesSourceURL),
		timezone:  timezone,
		client: &http.Client{
			Timeout: 30 * time.Second,
		},
		enabled:    enabled,
		retryDelay: 15 * time.Minute,
	}, nil
}

func (service *currencyRateService) Start(ctx context.Context) {
	if !service.enabled {
		log.Printf("currency rate refresh is disabled")
		return
	}
	go service.run(ctx)
}

func (service *currencyRateService) run(ctx context.Context) {
	service.refreshUntilSuccessful(ctx)

	for {
		nextMidnight := nextCurrencyRateMidnight(time.Now(), service.timezone)
		timer := time.NewTimer(time.Until(nextMidnight))
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return
		case <-timer.C:
		}

		service.refreshUntilSuccessful(ctx)
	}
}

func (service *currencyRateService) refreshUntilSuccessful(ctx context.Context) {
	for {
		err := service.refreshIfStale(ctx)
		if err == nil || errors.Is(err, context.Canceled) {
			return
		}
		log.Printf("currency rate refresh failed: %v; retrying in %s", err, service.retryDelay)

		timer := time.NewTimer(service.retryDelay)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				<-timer.C
			}
			return
		case <-timer.C:
		}
	}
}

func (service *currencyRateService) refreshIfStale(ctx context.Context) error {
	now := time.Now()
	today := currencyRateDate(now, service.timezone)
	latestDate, err := service.database.LatestCurrencyRateSnapshotDate(ctx, service.base)
	if err == nil && latestDate == today {
		return nil
	}
	if err != nil && !errors.Is(err, database.ErrCurrencyRatesNotFound) {
		return err
	}

	rates, err := service.fetchFrankfurterRates(ctx)
	if err != nil {
		return err
	}

	if err := service.database.StoreCurrencyRateSnapshot(
		ctx,
		today,
		service.base,
		service.source,
		now.UTC(),
		rates,
	); err != nil {
		return err
	}
	log.Printf("currency rates refreshed: snapshot_date=%s base=%s quotes=%d", today, service.base, len(rates)+1)
	return nil
}

func (service *currencyRateService) fetchFrankfurterRates(ctx context.Context) ([]database.CurrencyRateInput, error) {
	endpoint, err := url.Parse(service.sourceURL)
	if err != nil {
		return nil, fmt.Errorf("parse currency rate source URL: %w", err)
	}
	query := endpoint.Query()
	query.Set("base", service.base)
	endpoint.RawQuery = query.Encode()

	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
	if err != nil {
		return nil, fmt.Errorf("create currency rate source request: %w", err)
	}
	request.Header.Set("Accept", "application/json")

	response, err := service.client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("fetch currency rates: %w", err)
	}
	defer response.Body.Close()

	if response.StatusCode < http.StatusOK || response.StatusCode >= http.StatusMultipleChoices {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 4<<10))
		return nil, fmt.Errorf("currency rate source returned %s: %s", response.Status, strings.TrimSpace(string(body)))
	}

	var payload []frankfurterRate
	decoder := json.NewDecoder(io.LimitReader(response.Body, 8<<20))
	decoder.UseNumber()
	if err := decoder.Decode(&payload); err != nil {
		return nil, fmt.Errorf("decode currency rate source response: %w", err)
	}
	if len(payload) == 0 {
		return nil, fmt.Errorf("currency rate source returned no rates")
	}

	quotes := make(map[string]database.CurrencyRateInput, len(payload))
	for _, row := range payload {
		base, baseErr := database.NormalizeCurrencyCode(row.Base)
		if baseErr != nil || base != service.base {
			return nil, fmt.Errorf("currency rate source returned unexpected base currency %q", row.Base)
		}
		quote, quoteErr := database.NormalizeCurrencyCode(row.Quote)
		if quoteErr != nil {
			return nil, fmt.Errorf("currency rate source returned invalid quote currency %q", row.Quote)
		}
		if _, dateErr := time.Parse(currencyRateDateFormat, row.Date); dateErr != nil {
			return nil, fmt.Errorf("currency rate source returned invalid rate date %q", row.Date)
		}
		rate, rateOK := new(big.Rat).SetString(row.Rate.String())
		if !rateOK || rate.Sign() <= 0 {
			return nil, fmt.Errorf("currency rate source returned invalid rate for %s", quote)
		}

		candidate := database.CurrencyRateInput{
			QuoteCurrencyCode: quote,
			Rate:              row.Rate.String(),
			ProviderRateDate:  row.Date,
		}
		if existing, ok := quotes[quote]; ok && (existing.Rate != candidate.Rate || existing.ProviderRateDate != candidate.ProviderRateDate) {
			return nil, fmt.Errorf("currency rate source returned duplicate quote %s", quote)
		}
		quotes[quote] = candidate
	}

	result := make([]database.CurrencyRateInput, 0, len(quotes))
	for _, quote := range quotes {
		result = append(result, quote)
	}
	return result, nil
}

func nextCurrencyRateMidnight(now time.Time, timezone *time.Location) time.Time {
	localNow := now.In(timezone)
	year, month, day := localNow.Date()
	return time.Date(year, month, day+1, 0, 0, 0, 0, timezone)
}

func currencyRateDate(now time.Time, timezone *time.Location) string {
	year, month, day := now.In(timezone).Date()
	return fmt.Sprintf("%04d-%02d-%02d", year, month, day)
}

func listCurrencyRatesHandler(service *currencyRateService) http.HandlerFunc {
	return func(w http.ResponseWriter, request *http.Request) {
		base := strings.TrimSpace(request.URL.Query().Get("base"))
		if base == "" {
			base = service.base
		}
		base, err := database.NormalizeCurrencyCode(base)
		if err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}

		date := strings.TrimSpace(request.URL.Query().Get("date"))
		if date != "" {
			if _, err := time.Parse(currencyRateDateFormat, date); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]string{
					"error": "date must be YYYY-MM-DD",
				})
				return
			}
		}

		var quotes []string
		if rawQuotes := strings.TrimSpace(request.URL.Query().Get("quotes")); rawQuotes != "" {
			for _, quote := range strings.Split(rawQuotes, ",") {
				quotes = append(quotes, strings.TrimSpace(quote))
			}
		}

		snapshot, err := service.database.GetCurrencyRateSnapshot(request.Context(), service.base, base, date, quotes)
		if err != nil {
			switch {
			case errors.Is(err, database.ErrInvalidCurrencyCode), errors.Is(err, database.ErrInvalidCurrencyRate):
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			case errors.Is(err, database.ErrCurrencyRatesNotFound):
				status := http.StatusServiceUnavailable
				message := "currency rates are not ready; try again later"
				if date != "" {
					status = http.StatusNotFound
					message = "currency rate snapshot not found"
				}
				writeJSON(w, status, map[string]string{"error": message})
			case errors.Is(err, database.ErrCurrencyRateNotFound):
				writeJSON(w, http.StatusNotFound, map[string]string{"error": err.Error()})
			default:
				log.Printf("listing currency rates failed: %v", err)
				writeJSON(w, http.StatusInternalServerError, map[string]string{
					"error": "could not load currency rates",
				})
			}
			return
		}

		writeJSON(w, http.StatusOK, snapshot)
	}
}

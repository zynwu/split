-- A snapshot is keyed by the calendar date in the configured application
-- timezone. provider_rate_date preserves the date attached to each upstream
-- quote because providers can publish different currencies on different
-- business dates.
CREATE TABLE currency_rates (
	 snapshot_date DATE NOT NULL,
	 base_currency_code TEXT NOT NULL
		CHECK (base_currency_code ~ '^[A-Z]{3}$'),
	 quote_currency_code TEXT NOT NULL
		CHECK (quote_currency_code ~ '^[A-Z]{3}$'),
	 rate NUMERIC(38, 18) NOT NULL CHECK (rate > 0),
	 provider_rate_date DATE NOT NULL,
	 source TEXT NOT NULL CHECK (char_length(source) BETWEEN 1 AND 255),
	 fetched_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
	 PRIMARY KEY (snapshot_date, base_currency_code, quote_currency_code),
	 CHECK (
		base_currency_code <> quote_currency_code
		OR rate = 1
	)
);

CREATE INDEX currency_rates_pair_date_idx
ON currency_rates (base_currency_code, quote_currency_code, snapshot_date DESC);

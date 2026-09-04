# Server

Minimal Go API for the Split backend.

## Run locally with Docker

Copy the example environment file and start both the API and PostgreSQL:

```sh
cp .env.example .env
docker compose up -d
```

Check the service logs with:

```sh
docker compose logs -f api
```

The API listens on port `8080` by default. Register a device with:

```sh
curl -X POST http://localhost:8080/api/register
```

The response contains a `device_id` and an `auth_token`. Store the token in
the iOS Keychain and send it as a bearer token on application requests.

To resolve the device ID associated with a stored token:

```sh
curl http://localhost:8080/api/device \
  -H 'Authorization: Bearer <auth_token-from-register>'
```

The response is:

```json
{"device_id":"<device-id-from-register>"}
```

Create a group with:

```sh
curl -X POST http://localhost:8080/api/groups \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <auth_token-from-register>' \
  -d '{"name":"Weekend trip","display_name":"Alice"}'
```

List the groups for the authenticated device with:

```sh
curl http://localhost:8080/api/groups \
  -H 'Authorization: Bearer <auth_token-from-register>'
```

The response contains each group's `uuid`, `name`, `creation_date`, the
current device's `actor_uuid`, `join_code`, and `latest_event_sequence`, plus an `actors` array containing
every active actor in that group. Each actor has an `actor_uuid` and optional
display name. The group UUID is used for future group requests, while the actor
UUID identifies a member when creating transactions or other group data.

Join another group with its six-letter join code:

```sh
curl -X POST http://localhost:8080/api/groups/join \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <auth_token-from-register>' \
  -d '{"join_code":"ABCDXY","display_name":"Alice"}'
```

`display_name` is the canonical initial name for the actor this device gets
in the group. It is trimmed and limited to 255 characters. Older clients that
omit it use `Me`.

Update an active actor's name within a group with:

```sh
curl -X PATCH "http://localhost:8080/api/groups/<group-uuid>/actors/<actor-uuid>" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <auth_token-from-register>' \
  -H 'Idempotency-Key: <request-uuid>' \
  -d '{"display_name":"Alice W."}'
```

The response contains the updated `actor_uuid`, `display_name`, and metadata
version. Any active member of the group may rename an active actor under the
current trusted-group model. Group actor names are server-backed and are
returned by the groups and balances APIs. The change is recorded as an
`actor.display_name_updated` ledger event. Reuse the same UUID in
`Idempotency-Key` if a PATCH response is lost and the request must be retried.

Reclaim/merge an existing actor from the device's current actor with:

```sh
curl -X POST "http://localhost:8080/api/groups/<group-uuid>/actors/<target-actor-uuid>/commandeer" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <auth_token-from-register>' \
  -d '{
    "event_uuid":"<merge-event-uuid>",
    "event_created_at":"2026-09-05T18:00:00Z",
    "client_sequence":3
  }'
```

The authenticated device's active actor is the merge source; the actor in the
URL is the target. The source actor is archived and recorded as
`merged_into_actor_uuid`, every active device binding for the source is
recreated for the target, and all of those devices can subsequently act as the
target actor. Expense creator/payer/split references and payment actor
references are redirected in their current projections. A payment that would
become a payment from an actor to itself is retained for audit but voided so it
does not affect balances. The immutable ledger keeps the original event
`actor_uuid`, `device_id`, and payload for future un-merge tooling.

The response contains `source_actor_uuid`, `target_actor_uuid`, the target actor,
and the `actor.commandeered` ledger event. Reuse the same `event_uuid`,
`event_created_at`, and `client_sequence` after a lost response; the server
returns `replayed:true` and does not apply the merge twice. Under the current
trusted-group model, any active group member may perform this operation.

Update a group's name with:

```sh
curl -X PATCH "http://localhost:8080/api/groups/<group-uuid>" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <auth_token-from-register>' \
  -H 'Idempotency-Key: <request-uuid>' \
  -d '{"name":"Updated group name"}'
```

The response contains the updated group metadata, including its `uuid`, `name`,
`creation_date`, `join_code`, `latest_event_sequence`, and
`latest_metadata_event_sequence`. An active member is required. This change is
recorded as a `group.name_updated` ledger event. Reuse the same UUID in
`Idempotency-Key` if a PATCH response is lost and the request must be retried.

`POST /api/register` and `GET /api/healthz` are public. Other current API routes
require the bearer token. The server stores only a hash of the token; whoever
possesses the token can act as that device, so it must be kept private.

### Currency rates

The API stores one complete daily currency-rate snapshot in `currency_rates`.
The snapshot date is the calendar date in `CURRENCY_RATES_TIMEZONE` (which
defaults to `America/Los_Angeles`). The background refresher runs once at the
next midnight in that timezone and also refreshes a missing/stale snapshot when
the API starts. A failed refresh is retried every 15 minutes. The default
source is the keyless Frankfurter v2 rates feed, and the source URL can be
replaced with a compatible endpoint through configuration.

The ledger settlement base is USD. Rates are exact decimal strings: a rate of
`1.3841` means one USD equals 1.3841 CAD. The API can derive a cross-rate from
the stored base, so clients can request CAD-to-EUR without the server storing a
second provider snapshot.

Get the latest available snapshot:

```sh
curl "http://localhost:8080/api/currency-rates?quotes=USD,CAD,EUR" \
  -H 'Authorization: Bearer <auth_token-from-register>'
```

Get a historical snapshot or request a different base currency:

```sh
curl "http://localhost:8080/api/currency-rates?date=2026-09-04&base=CAD&quotes=USD,EUR" \
  -H 'Authorization: Bearer <auth_token-from-register>'
```

The response is:

```json
{
  "rate_date": "2026-09-04",
  "base_currency_code": "USD",
  "rates": [
    {"quote_currency_code": "CAD", "rate": "1.3841"},
    {"quote_currency_code": "EUR", "rate": "0.86149"},
    {"quote_currency_code": "USD", "rate": "1"}
  ],
  "source": "frankfurter",
  "fetched_at": "2026-09-04T08:07:43.764334Z"
}
```

`date` refers to the app's stored snapshot date, not necessarily the
provider's business date. Each database row also retains the provider date for
auditability. Omitting `quotes` returns every currency in the snapshot.
Unknown historical snapshots return `404`; if no snapshot has ever been
fetched, the latest request returns `503` while the refresher is still working.

The Compose service accepts these settings:

```text
CURRENCY_RATES_ENABLED=true
CURRENCY_RATES_BASE=USD
CURRENCY_RATES_SOURCE_URL=https://api.frankfurter.dev/v2/rates
CURRENCY_RATES_TIMEZONE=America/Los_Angeles
```

Every accepted expense locks its conversion immediately using the newest stored
USD snapshot available at ingestion. The expense and its ledger event retain
`exchange_rate_to_usd` (USD units per one native-currency unit),
`usd_total_minor_units`, and `rate_snapshot_date`. USD expenses use an exact
rate of `1` and need no snapshot date. The native amount and currency remain
available for display, but balances use only the locked USD values, so a later
daily refresh cannot change an existing debt. Each split also stores its
deterministically allocated `usd_amount_minor_units`, ensuring the split debits
sum exactly to the locked expense total.

Payments use the same lock so a non-USD settlement can offset the all-USD
balance consistently. Editing an expense or payment creates a new ledger event
and locks the replacement amount at that event's ingestion time; retrying the
same event UUID replays its original lock.

### Expense ledger

Expenses and group metadata are written as immutable ledger events and read
from materialized projections. An event can be retried safely: resend the same
`event_uuid` and `client_sequence` after a network failure instead of creating
a second event. The server returns `replayed:true` for a duplicate of the same
event and returns the canonical current projection with the response.

The generic events endpoint accepts `expense.created`, `expense.updated`,
`expense.voided`, `payment.created`, `payment.updated`, `payment.voided`,
`group.name_updated`, and `actor.display_name_updated` events.
Group-name events return a `group` projection and actor-name events return an
`actor` projection. Metadata projections use their own
`latest_metadata_event_sequence` version, so an expense edit cannot overwrite
a name change. If two offline edits target the same projection, the event with
the later client `event_created_at` wins; the other event is retained with
`applied:false` and `conflict:true`.

Record a one-to-one payment with the same ledger endpoint:

```sh
curl -X POST "http://localhost:8080/api/groups/<group-uuid>/events" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <auth_token-from-register>' \
  -d '{
    "event_uuid":"<new-event-uuid>",
    "entity_type":"payment",
    "entity_uuid":"<new-payment-uuid>",
    "event_type":"payment.created",
    "actor_uuid":"<authenticated-member-actor-uuid>",
    "event_created_at":"2026-09-05T18:00:00Z",
    "client_sequence":2,
    "base_sequence":0,
    "payload_version":1,
    "payload":{
      "from_actor_uuid":"<payer-actor-uuid>",
      "to_actor_uuid":"<recipient-actor-uuid>",
      "currency_code":"USD",
      "amount_minor_units":1250,
      "occurred_at":"2026-09-05T17:55:00Z"
    }
  }'
```

The event response includes the current `payment` projection. `from_actor_uuid`
is debited and `to_actor_uuid` is credited by the payment amount. Payments keep
their native amount for display and also return the locked USD amount. Read all
payment records, including voided history, with:

```sh
curl "http://localhost:8080/api/groups/<group-uuid>/payments" \
  -H 'Authorization: Bearer <auth_token-from-register>'
```

Use `payment.updated` with the same `entity_uuid` and a new event UUID to edit
a payment, or `payment.voided` to reverse it without deleting its ledger
history. Reuse the same event UUID and client sequence for retries.

Create an expense with `POST /api/groups/<group-uuid>/events`:

```sh
curl -X POST "http://localhost:8080/api/groups/<group-uuid>/events" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <auth_token-from-register>' \
  -d '{
    "event_uuid":"<new-event-uuid>",
    "entity_type":"expense",
    "entity_uuid":"<new-expense-uuid>",
    "event_type":"expense.created",
    "actor_uuid":"<authenticated-member-actor-uuid>",
    "event_created_at":"2026-09-01T19:31:00Z",
    "client_sequence":0,
    "base_sequence":0,
    "payload_version":1,
    "payload":{
      "name":"Dinner",
      "description":"Friday dinner",
      "currency_code":"USD",
      "total_minor_units":4200,
      "payer_actor_uuid":"<payer-actor-uuid>",
      "split_method":"equal",
      "split_config":{},
      "occurred_at":"2026-09-01T19:30:00Z",
      "splits":[
        {"actor_uuid":"<actor-1-uuid>"},
        {"actor_uuid":"<actor-2-uuid>"}
      ]
    }
  }'
```

Amounts are integer minor units (`4200` means `$42.00`), so no floating-point
currency values are stored. Equal splits are calculated deterministically by
the server. Manual splits must include `amount_minor_units` for every split
and sum exactly to `total_minor_units`. The `currency_code` is an uppercase
three-letter code such as `USD` or `EUR`.

`event_created_at` is the client-side time at which the event was created;
`recorded_at` in the returned ledger event is when the server received it.
The expense projection's `created_at` and `updated_at` reflect the winning
event's creation time. The server-owned currency-lock fields are not part of
the client payload and must not be supplied or recomputed by the client.

Use the expense projection for the current group state:

```sh
curl "http://localhost:8080/api/groups/<group-uuid>/expenses" \
  -H 'Authorization: Bearer <auth_token-from-register>'
```

Get the current derived balances and deterministic simplified transfers:

```sh
curl "http://localhost:8080/api/groups/<group-uuid>/balances" \
  -H 'Authorization: Bearer <auth_token-from-register>'
```

The response contains an `as_of_sequence` watermark and one USD balance bucket.
A positive `net_minor_units` means the group owes that actor; a negative value
means the actor owes the group. `suggested_transfers` reduces those net
balances into direct USD payments. Native-currency expenses are included using
their immutable locked USD values.

Expense responses include `created_by_actor_uuid` with its
`created_by_device_id`; each current split also includes the device that
recorded that split snapshot. Payment responses include the analogous
`created_by_actor_uuid`/`created_by_device_id` pair. The raw ledger event always
contains the authenticated event `actor_uuid` and `device_id`, and its payload
preserves the original payer, split, and payment actor IDs even after an actor
merge redirects the materialized projections.

For offline synchronization, keep the returned group event cursor locally and
pull events after it:

```sh
curl "http://localhost:8080/api/groups/<group-uuid>/events?after=0&limit=100" \
  -H 'Authorization: Bearer <auth_token-from-register>'
```

The server assigns a monotonically increasing `sequence` per group. Each
accepted event is retained. The sequence is the server's receipt order and is
used only for synchronization. The projection applies the event with the
latest `event_created_at` for that expense; equal timestamps use `event_uuid` as
a deterministic tie-breaker. If `base_sequence` is older than the expense's
current `version`, or if the event loses that timestamp comparison, the
response has `"conflict":true`. A losing event remains in the ledger with
`"applied":false` and does not overwrite the current projection.

The top-level event `actor_uuid` normally must be the active actor currently
bound to the authenticated device in that group. For offline transaction events
created before an actor merge, the server also accepts that device's historical
merged actor UUID and resolves it to the surviving actor for the projection.
The original UUID remains in the ledger. The payer and split actor UUIDs in the
expense payload may refer to any active group actors, since a member can record
an expense paid by or shared with someone else.

For an edit, create and persist `event_created_at` on the client, keep the same
`entity_uuid`, use a new `event_uuid` and the next device `client_sequence`, and
set `base_sequence` to the expense's current `version`. Reuse all of those
values unchanged when retrying the event. To void an expense, use
`event_type:"expense.voided"` with an empty object payload. Voiding keeps the
expense and its history available; the projection returns its `voided_at`
timestamp.

The same edit can be sent through the dedicated full-replacement endpoint:

```sh
curl -X PUT "http://localhost:8080/api/groups/<group-uuid>/expenses/<expense-uuid>" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <auth_token-from-register>' \
  -d '{
    "event_uuid":"<new-event-uuid>",
    "actor_uuid":"<authenticated-member-actor-uuid>",
    "event_created_at":"2026-09-01T20:00:00Z",
    "client_sequence":1,
    "base_sequence":1,
    "payload_version":1,
    "payload":{
      "name":"Dinner (updated)",
      "description":"Friday dinner with dessert",
      "currency_code":"USD",
      "total_minor_units":4800,
      "payer_actor_uuid":"<payer-actor-uuid>",
      "split_method":"equal",
      "split_config":{},
      "occurred_at":"2026-09-01T19:30:00Z",
      "splits":[
        {"actor_uuid":"<actor-1-uuid>"},
        {"actor_uuid":"<actor-2-uuid>"}
      ]
    }
  }'
```

`PUT /api/groups/<group-uuid>/expenses/<expense-uuid>` is a full replacement,
not a partial update. It appends an `expense.updated` ledger event, preserves
the previous version in the event log, and returns the same event/expense
result as the generic ledger endpoint. The route requires the expense to
already exist; it cannot create a new expense.

Health check: `GET http://localhost:8080/api/healthz`

## Database migrations

The API runs the SQL files in `database/migrations/` during startup. Files are applied
in numeric order and recorded in the `schema_migrations` table. Each migration
runs once in a transaction, so restarting the API does not recreate or erase
data. Applied migration files must not be edited; add a new file such as
`0002_add_group_color.sql` for the next schema change.

After adding a migration, rebuild or restart the API so it starts with the new
binary:

```sh
docker compose up -d --build api
```

`docker compose down` preserves the database volume. Use `docker compose down
-v` only when you intentionally want to delete all local PostgreSQL data.

## Data model

The API currently creates rows in `groups`, which has a UUID, name, and
creation timestamp and a unique six-letter join code. Creating a group also
creates the creator's durable actor identity and active device binding.
`group_actors` stores the durable actor identity for each group member.
Each actor can have a group-scoped `display_name`. `devices` stores normally stable device identifiers, and
`actor_device_bindings` records the history of which device represented which
actor when a device is replaced or an actor is reclaimed. A commandeered actor
is archived with `merged_into_actor_uuid`; its historical bindings remain
closed, and new active bindings point at the surviving actor. Transactions
reference both actor and device provenance: expenses expose creator and split
device IDs, while payments expose their creator device ID. The current
`payments` projection stores one-to-one settlements; its immutable create, edit,
void, and commandeering history remains in `ledger_events`. Monetary
projections retain both their native amount/currency and immutable USD lock
fields; pre-existing non-USD data cannot be migrated without its original
server-time rate.

Stop the containers with:

```sh
docker compose down
```

The named PostgreSQL volume is kept by `docker compose down`, so data remains
available the next time the stack starts. To delete the local database data,
use `docker compose down -v`.

## Deploy the API image

Build the same image used by Compose:

```sh
docker build -t split-api .
```

Run it against a PostgreSQL instance by providing `DATABASE_URL`:

```sh
docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e DATABASE_URL='postgres://user:password@host:5432/database?sslmode=require' \
  split-api
```

For production, use a managed PostgreSQL database and set `DATABASE_URL` as a
deployment secret. Do not use the local Compose password in production.

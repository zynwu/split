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
  -d '{"display_name":"Alice W."}'
```

The response contains the updated `actor_uuid` and `display_name`. Any active
member of the group may rename an active actor under the current trusted-group
model. Group actor names are server-backed and are returned by the groups and
balances APIs.

Update a group's name with:

```sh
curl -X PATCH "http://localhost:8080/api/groups/<group-uuid>" \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <auth_token-from-register>' \
  -d '{"name":"Updated group name"}'
```

The response contains the updated group metadata, including its `uuid`, `name`,
`creation_date`, `join_code`, and `latest_event_sequence`. An active member is
required. This metadata update does not create an expense ledger event or
change the group's expense sequence; clients should refresh group metadata when
syncing.

`POST /api/register` and `GET /api/healthz` are public. Other current API routes
require the bearer token. The server stores only a hash of the token; whoever
possesses the token can act as that device, so it must be kept private.

### Expense ledger

Expenses are written as immutable ledger events and read from the server's
materialized `expenses` projection. An event can be retried safely: resend the
same `event_uuid` and `client_sequence` after a network failure instead of
creating a new event.

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
event's creation time.

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

The response contains an `as_of_sequence` watermark and one balance bucket per
currency. A positive `net_minor_units` means the group owes that actor; a
negative value means the actor owes the group. `suggested_transfers` reduces
those net balances into direct payments. The current default is USD when a
group has no expenses, while expenses in other currencies remain in separate
native-currency buckets until exchange-rate conversion is introduced.

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
actor when a device is replaced or an actor is reclaimed. Transactions should
reference both `actor_uuid` and `device_id` so identity corrections do not
erase device history.

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

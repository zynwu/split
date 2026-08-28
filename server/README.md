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

The API listens on port `8080` by default. Create a group with:

```sh
curl -X POST http://localhost:8080/groups \
  -H 'Content-Type: application/json' \
  -d '{"name":"Weekend trip"}'
```

Health check: `GET http://localhost:8080/healthz`

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
creation timestamp. `group_actors` stores the durable actor identity for each
group member. `devices` stores normally stable device identifiers, and
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

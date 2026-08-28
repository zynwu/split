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

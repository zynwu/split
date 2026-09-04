package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"server/database"
)

func main() {
	databaseURL := os.Getenv("DATABASE_URL")
	if databaseURL == "" {
		log.Fatal("DATABASE_URL is required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	db, err := database.Open(ctx, databaseURL)
	cancel()
	if err != nil {
		log.Fatalf("opening database: %v", err)
	}
	defer db.Close()

	port := valueOrDefault(os.Getenv("PORT"), "8080")
	server := newHTTPServer(":"+port, db)

	shutdown := make(chan os.Signal, 1)
	signal.Notify(shutdown, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(shutdown)

	go func() {
		<-shutdown

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		if err := server.Shutdown(ctx); err != nil {
			log.Printf("graceful shutdown failed: %v", err)
		}
	}()

	log.Printf("server listening on http://localhost:%s", port)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func newHTTPServer(address string, db *database.Database) *http.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/register", registerHandler(db))
	mux.HandleFunc("GET /api/healthz", healthHandler(db))
	mux.Handle("GET /api/", requireDeviceAuth(db, http.HandlerFunc(rootHandler)))
	mux.Handle("GET /api/device", requireDeviceAuth(db, http.HandlerFunc(deviceHandler)))
	mux.Handle("GET /api/groups", requireDeviceAuth(db, listGroupsHandler(db)))
	mux.Handle("POST /api/groups/{group_uuid}/events", requireDeviceAuth(db, http.HandlerFunc(appendLedgerEventHandler(db))))
	mux.Handle("GET /api/groups/{group_uuid}/events", requireDeviceAuth(db, http.HandlerFunc(listLedgerEventsHandler(db))))
	mux.Handle("GET /api/groups/{group_uuid}/expenses", requireDeviceAuth(db, http.HandlerFunc(listExpensesHandler(db))))
	mux.Handle("GET /api/groups/{group_uuid}/payments", requireDeviceAuth(db, http.HandlerFunc(listPaymentsHandler(db))))
	mux.Handle("PUT /api/groups/{group_uuid}/expenses/{expense_uuid}", requireDeviceAuth(db, http.HandlerFunc(updateExpenseHandler(db))))
	mux.Handle("POST /api/groups/{group_uuid}/actors/{actor_uuid}/commandeer", requireDeviceAuth(db, http.HandlerFunc(commandeerActorHandler(db))))
	mux.Handle("PATCH /api/groups/{group_uuid}", requireDeviceAuth(db, http.HandlerFunc(updateGroupNameHandler(db))))
	mux.Handle("PATCH /api/groups/{group_uuid}/actors/{actor_uuid}", requireDeviceAuth(db, http.HandlerFunc(updateActorDisplayNameHandler(db))))
	mux.Handle("GET /api/groups/{group_uuid}/balances", requireDeviceAuth(db, http.HandlerFunc(listGroupBalancesHandler(db))))
	mux.Handle("POST /api/groups/join", requireDeviceAuth(db, joinGroupHandler(db)))
	mux.Handle("POST /api/groups", requireDeviceAuth(db, createGroupHandler(db)))

	return &http.Server{
		Addr:              address,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
}

func valueOrDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

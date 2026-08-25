// Command readapi serves the latest vehicle positions from TimescaleDB as JSON for
// the Leaflet map (DESIGN.md §9.4 1c). Deliberately small: two endpoints, a pgx
// connection pool, no web framework.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// position is one row of the /positions response.
type position struct {
	VehicleID string    `json:"vehicle_id"`
	LineID    int       `json:"line_id"`
	Ts        time.Time `json:"ts"`
	Lat       float64   `json:"lat"`
	Lon       float64   `json:"lon"`
}

func main() {
	if err := run(); err != nil {
		log.Fatalf("readapi: %v", err)
	}
}

func run() error {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		return fmt.Errorf("DATABASE_URL is not set")
	}
	addr := ":" + envOr("PORT", "8080")

	// The map is served from a different origin (Cloudflare Pages) than this API
	// (Cloudflare Tunnel), so the browser demands an explicit CORS header.
	allowCORS := corsAllower(envOr("CORS_ALLOW_ORIGIN", "*"))

	// A pool, not a single connection like the ingester, because a server handles
	// many requests concurrently. pgxpool is lazy, so this does not fail if the DB
	// is not up yet — the first query connects.
	pool, err := pgxpool.New(context.Background(), dbURL)
	if err != nil {
		return fmt.Errorf("create pool: %w", err)
	}
	defer pool.Close()

	mux := http.NewServeMux()
	mux.HandleFunc("/positions", positionsHandler(pool, allowCORS))
	mux.HandleFunc("/healthz", healthHandler(pool))

	log.Printf("readapi listening on %s", addr)
	return http.ListenAndServe(addr, mux)
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// corsFunc sets the CORS response header, if the request is entitled to one.
type corsFunc func(http.ResponseWriter, *http.Request)

// corsAllower builds that check from a comma-separated origin allowlist.
//
// A single value cannot be hardcoded here: the map is served from Cloudflare
// Pages in production but from localhost during development, and Layer B must
// stay identical in both (DESIGN §6). So the deployed value names both origins
// and this echoes back whichever one actually asked.
//
// "*" is still accepted, and is the default so that `make port-forward` and a
// bare `curl` keep working, but the deployed Read API does not use it — a public
// endpoint answering "*" is readable by script on any page on the internet.
func corsAllower(spec string) corsFunc {
	if strings.TrimSpace(spec) == "*" {
		return func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Access-Control-Allow-Origin", "*")
		}
	}
	allowed := make(map[string]bool)
	for _, o := range strings.Split(spec, ",") {
		if o = strings.TrimSpace(o); o != "" {
			allowed[o] = true
		}
	}
	return func(w http.ResponseWriter, r *http.Request) {
		if origin := r.Header.Get("Origin"); allowed[origin] {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			// The response now differs by request origin, so any cache in front
			// of this (Cloudflare is) must key on it rather than serving one
			// origin the header minted for another.
			w.Header().Add("Vary", "Origin")
		}
	}
}

// positionsHandler returns the latest position per vehicle as a JSON array.
func positionsHandler(pool *pgxpool.Pool, allowCORS corsFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		// "Latest position per vehicle." DISTINCT ON is fine at skeleton scale;
		// DESIGN §4.9 replaces this with a materialized view before the history
		// table grows to tens of millions of rows.
		const q = `SELECT DISTINCT ON (vehicle_id) vehicle_id, line_id, ts, lat, lon
		           FROM positions
		           ORDER BY vehicle_id, ts DESC`
		rows, err := pool.Query(ctx, q)
		if err != nil {
			http.Error(w, "query failed", http.StatusInternalServerError)
			log.Printf("query: %v", err)
			return
		}
		defer rows.Close()

		out := []position{}
		for rows.Next() {
			var p position
			if err := rows.Scan(&p.VehicleID, &p.LineID, &p.Ts, &p.Lat, &p.Lon); err != nil {
				http.Error(w, "scan failed", http.StatusInternalServerError)
				log.Printf("scan: %v", err)
				return
			}
			out = append(out, p)
		}
		if err := rows.Err(); err != nil {
			http.Error(w, "rows error", http.StatusInternalServerError)
			log.Printf("rows: %v", err)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		allowCORS(w, r)
		if err := json.NewEncoder(w).Encode(out); err != nil {
			log.Printf("encode: %v", err)
		}
	}
}

// healthHandler reports 200 if the DB is reachable, else 503. This is the assertion
// DESIGN §4.7 calls readiness; wiring it as a k8s probe happens in step 5.
func healthHandler(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := pool.Ping(ctx); err != nil {
			http.Error(w, "db unreachable", http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintln(w, "ok")
	}
}

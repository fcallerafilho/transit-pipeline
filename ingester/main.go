// Command ingester is the step-1a walking skeleton for the transit pipeline.
//
// Scope (DESIGN.md §9.4 1a): authenticate to the SPTrans Olho Vivo API, poll ONE
// hardcoded line ONCE, and write ONE row into TimescaleDB. Then exit. No ticker, no
// goroutines, no channel, no batching, no metrics — those are later steps. It is
// deliberately small enough to read top to bottom.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

const (
	apiBase = "https://api.olhovivo.sptrans.com.br/v2.1"

	// Line to poll, chosen from the step-0 spike: cl=402 (line 3459-10, Term. Pq.
	// D. Pedro II -> Itaim Paulista), the busiest line at survey time. Hardcoded for
	// 1a; step 2 reads a corridor list from configuration.
	hardcodedLineCode = 402
)

// vehicle mirrors one entry of the API's terse "vs" array. The `json:"..."` struct
// tags tell encoding/json how to map the cryptic upstream field names onto readable
// Go fields. Field names are Capitalised because in Go an uppercase identifier is
// exported, and encoding/json can only populate exported fields. Unmapped upstream
// fields (the API also sends `is` and `sv`) are simply ignored by the decoder.
type vehicle struct {
	Prefix     string  `json:"p"`  // vehicle prefix (fleet id); the API sends this as a JSON string, despite the docs calling it an integer
	Accessible bool    `json:"a"`  // wheelchair accessible
	Timestamp  string  `json:"ta"` // capture time, RFC3339 UTC, e.g. 2026-08-22T15:36:29Z
	Lat        float64 `json:"py"` // latitude
	Lon        float64 `json:"px"` // longitude
}

// posicaoResponse mirrors the /Posicao/Linha payload: {"hr": "...", "vs": [ ... ]}.
type posicaoResponse struct {
	Hr string    `json:"hr"`
	Vs []vehicle `json:"vs"`
}

func main() {
	// Go idiom: keep main() tiny. The real work lives in run(), which returns an
	// error, so there is exactly one place (here) that decides to exit non-zero.
	if err := run(); err != nil {
		log.Fatalf("ingester: %v", err)
	}
}

func run() error {
	token := os.Getenv("SPTRANS_TOKEN")
	if token == "" {
		return fmt.Errorf("SPTRANS_TOKEN is not set")
	}
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		return fmt.Errorf("DATABASE_URL is not set")
	}

	// A context carries a deadline through the whole call tree; one 30s budget for
	// a single poll + insert is generous.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// An http.Client with a cookie jar is the Go equivalent of Python's
	// requests.Session(): the apiCredentials cookie the API sets on auth is stored
	// and resent automatically on the next request.
	jar, err := cookiejar.New(nil)
	if err != nil {
		return fmt.Errorf("cookie jar: %w", err)
	}
	client := &http.Client{Jar: jar, Timeout: 15 * time.Second}

	if err := authenticate(ctx, client, token); err != nil {
		return err
	}

	vehicles, err := pollLine(ctx, client, hardcodedLineCode)
	if err != nil {
		return err
	}
	log.Printf("polled line cl=%d: %d vehicles", hardcodedLineCode, len(vehicles))
	if len(vehicles) == 0 {
		// Step 0 proved an idle line still returns HTTP 200 with an empty list — a
		// successful poll with nothing to ingest, not a transport error. For 1a we
		// need a row, so treat it as a run failure and say why.
		return fmt.Errorf("line cl=%d returned no vehicles; try a busier line or time of day", hardcodedLineCode)
	}

	// DESIGN §9.4 1a asks for exactly ONE row. Take the first vehicle; looping over
	// all of them is a one-line change deferred to step 2 (batched COPY).
	if err := writeOne(ctx, dbURL, hardcodedLineCode, vehicles[0]); err != nil {
		return err
	}
	return nil
}

// authenticate POSTs the token and checks the body is literally "true". The API also
// sets the apiCredentials cookie, which the client's jar now holds for later calls.
func authenticate(ctx context.Context, client *http.Client, token string) error {
	u := fmt.Sprintf("%s/Login/Autenticar?token=%s", apiBase, url.QueryEscape(token))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, nil)
	if err != nil {
		return fmt.Errorf("build auth request: %w", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("auth request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read auth body: %w", err)
	}
	if strings.TrimSpace(string(body)) != "true" {
		return fmt.Errorf("authentication failed (status %d, body %q)", resp.StatusCode, string(body))
	}
	log.Print("authenticated ok")
	return nil
}

// pollLine fetches the current vehicles for one line code.
func pollLine(ctx context.Context, client *http.Client, lineCode int) ([]vehicle, error) {
	u := fmt.Sprintf("%s/Posicao/Linha?codigoLinha=%d", apiBase, lineCode)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, fmt.Errorf("build poll request: %w", err)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("poll request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("poll returned status %d", resp.StatusCode)
	}

	var payload posicaoResponse
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, fmt.Errorf("decode poll body: %w", err)
	}
	return payload.Vs, nil
}

// writeOne connects to Postgres/Timescale and inserts a single position row.
func writeOne(ctx context.Context, dbURL string, lineCode int, v vehicle) error {
	ts, err := time.Parse(time.RFC3339, v.Timestamp)
	if err != nil {
		return fmt.Errorf("parse ta %q: %w", v.Timestamp, err)
	}

	conn, err := pgx.Connect(ctx, dbURL)
	if err != nil {
		return fmt.Errorf("connect db: %w", err)
	}
	defer conn.Close(ctx)

	const insert = `INSERT INTO positions (vehicle_id, line_id, ts, lat, lon)
	                VALUES ($1, $2, $3, $4, $5)`
	if _, err := conn.Exec(ctx, insert,
		v.Prefix, lineCode, ts, v.Lat, v.Lon); err != nil {
		return fmt.Errorf("insert row: %w", err)
	}

	log.Printf("wrote 1 row: vehicle_id=%s line_id=%d ts=%s lat=%.5f lon=%.5f",
		v.Prefix, lineCode, ts.Format(time.RFC3339), v.Lat, v.Lon)
	return nil
}

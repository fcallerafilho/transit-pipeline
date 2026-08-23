// Command ingester continuously ingests SPTrans vehicle positions for a configured
// set of lines into TimescaleDB (DESIGN.md §9.4 step 2).
//
// Shape (DESIGN §4.2): one poll goroutine per line fans into a buffered channel that
// a single writer goroutine drains and COPYs into Timescale. The channel is the
// explicit backpressure boundary — when the DB is slow it fills, and the drop-vs-block
// decision is a visible line of code (here: we drop the batch and log it; the
// samples_dropped_total metric arrives in step 3, §5.1).
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const apiBase = "https://api.olhovivo.sptrans.com.br/v2.1"

// vehicle mirrors one entry of the API's "vs" array (only the fields we store).
type vehicle struct {
	Prefix    string  `json:"p"`  // vehicle prefix; a JSON string despite the docs (step-0 finding)
	Timestamp string  `json:"ta"` // capture time, RFC3339 UTC
	Lat       float64 `json:"py"`
	Lon       float64 `json:"px"`
}

type posicaoResponse struct {
	Vs []vehicle `json:"vs"`
}

// positionRow is one row headed for the positions table.
type positionRow struct {
	vehicleID string
	lineID    int
	ts        time.Time
	lat, lon  float64
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil))) // structured logs (§9.4 step 2)
	if err := run(); err != nil {
		slog.Error("fatal", "err", err.Error())
		os.Exit(1)
	}
}

func run() error {
	token := os.Getenv("SPTRANS_TOKEN")
	if token == "" {
		return errors.New("SPTRANS_TOKEN is not set")
	}
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		return errors.New("DATABASE_URL is not set")
	}
	lines, err := parseLineCodes(os.Getenv("LINE_CODES"))
	if err != nil {
		return err
	}
	interval := envDuration("POLL_INTERVAL", 45*time.Second) // measured source cadence (§4.5)
	bufSize := envInt("CHANNEL_BUFFER", 64)

	// k8s sends SIGTERM on pod shutdown; Ctrl-C for local runs. Cancelling ctx makes
	// every goroutine wind down.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	pool, err := pgxpool.New(ctx, dbURL)
	if err != nil {
		return fmt.Errorf("db pool: %w", err)
	}
	defer pool.Close()

	auth, err := newAuthClient(token)
	if err != nil {
		return err
	}
	if err := auth.authenticate(ctx); err != nil {
		return fmt.Errorf("initial auth: %w", err)
	}

	ch := make(chan []positionRow, bufSize)

	// Fan-in: one poller per line.
	var pollers sync.WaitGroup
	for _, line := range lines {
		pollers.Add(1)
		go func(line int) {
			defer pollers.Done()
			poll(ctx, auth, line, interval, ch)
		}(line)
	}

	// Single writer draining the channel.
	writerDone := make(chan struct{})
	go func() {
		writer(pool, ch)
		close(writerDone)
	}()

	slog.Info("ingester started", "lines", lines, "interval", interval.String(), "buffer", bufSize)

	pollers.Wait() // returns once ctx is cancelled and all pollers exit
	close(ch)      // no more sends; the writer drains what remains and returns
	<-writerDone
	slog.Info("ingester stopped")
	return nil
}

// poll fetches one line on a fixed cadence, backing off exponentially on failure, and
// sends each non-empty batch to the writer channel (dropping if the channel is full).
func poll(ctx context.Context, auth *authClient, line int, interval time.Duration, ch chan<- []positionRow) {
	var backoff time.Duration
	for {
		rows, err := fetchLine(ctx, auth, line)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			backoff = nextBackoff(backoff)
			slog.Warn("poll failed", "line", line, "err", err.Error(), "retry_in", backoff.String())
			if !sleepCtx(ctx, backoff) {
				return
			}
			continue
		}
		backoff = 0
		if len(rows) > 0 {
			select {
			case ch <- rows:
			default:
				// Backpressure boundary: DB/writer can't keep up. Drop and log.
				slog.Warn("channel full; dropping batch", "line", line, "dropped", len(rows))
			}
		}
		if !sleepCtx(ctx, interval) {
			return
		}
	}
}

// fetchLine gets a line's vehicles, re-authenticating once if the session looks expired.
func fetchLine(ctx context.Context, auth *authClient, line int) ([]positionRow, error) {
	vs, status, err := auth.getLine(ctx, line)
	if err != nil {
		return nil, err
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		if err := auth.reauthenticate(ctx); err != nil {
			return nil, fmt.Errorf("reauth: %w", err)
		}
		vs, status, err = auth.getLine(ctx, line)
		if err != nil {
			return nil, err
		}
	}
	if status != http.StatusOK {
		return nil, fmt.Errorf("status %d", status)
	}
	return toRows(line, vs), nil
}

func toRows(line int, vs []vehicle) []positionRow {
	rows := make([]positionRow, 0, len(vs))
	for _, v := range vs {
		ts, err := time.Parse(time.RFC3339, v.Timestamp)
		if err != nil {
			slog.Warn("bad timestamp", "line", line, "prefix", v.Prefix, "ta", v.Timestamp)
			continue // parse_failures_total{reason="bad_timestamp"} arrives in step 3
		}
		rows = append(rows, positionRow{v.Prefix, line, ts, v.Lat, v.Lon})
	}
	return rows
}

// writer drains batches and COPYs each into Timescale until the channel is closed.
func writer(pool *pgxpool.Pool, ch <-chan []positionRow) {
	for batch := range ch {
		// A fresh context, independent of shutdown, so batches already in the channel
		// still get written while the process is draining.
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		src := make([][]any, len(batch))
		for i, r := range batch {
			src[i] = []any{r.vehicleID, r.lineID, r.ts, r.lat, r.lon}
		}
		n, err := pool.CopyFrom(ctx, pgx.Identifier{"positions"},
			[]string{"vehicle_id", "line_id", "ts", "lat", "lon"}, pgx.CopyFromRows(src))
		if err != nil {
			slog.Error("copy failed", "err", err.Error(), "rows", len(batch))
		} else {
			slog.Info("wrote batch", "line", batch[0].lineID, "rows", n)
		}
		cancel()
	}
}

// --- auth: a cookie-jar HTTP client shared by all pollers (like requests.Session) ---

type authClient struct {
	client   *http.Client
	token    string
	mu       sync.Mutex
	lastAuth time.Time
}

func newAuthClient(token string) (*authClient, error) {
	jar, err := cookiejar.New(nil)
	if err != nil {
		return nil, fmt.Errorf("cookie jar: %w", err)
	}
	return &authClient{client: &http.Client{Jar: jar, Timeout: 15 * time.Second}, token: token}, nil
}

func (a *authClient) authenticate(ctx context.Context) error { return a.doAuth(ctx) }

// reauthenticate is called concurrently by pollers on a 401/403. It dedups: if another
// poller just refreshed the session, skip the redundant round-trip.
func (a *authClient) reauthenticate(ctx context.Context) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if time.Since(a.lastAuth) < 5*time.Second {
		return nil
	}
	return a.doAuth(ctx)
}

func (a *authClient) doAuth(ctx context.Context) error {
	u := fmt.Sprintf("%s/Login/Autenticar?token=%s", apiBase, url.QueryEscape(a.token))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, nil)
	if err != nil {
		return err
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if strings.TrimSpace(string(body)) != "true" {
		return fmt.Errorf("authentication failed (status %d)", resp.StatusCode)
	}
	a.lastAuth = time.Now()
	slog.Info("authenticated")
	return nil
}

func (a *authClient) getLine(ctx context.Context, line int) ([]vehicle, int, error) {
	u := fmt.Sprintf("%s/Posicao/Linha?codigoLinha=%d", apiBase, line)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, 0, err
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, resp.Body)
		return nil, resp.StatusCode, nil
	}
	var p posicaoResponse
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		return nil, resp.StatusCode, fmt.Errorf("decode: %w", err)
	}
	return p.Vs, resp.StatusCode, nil
}

// --- small helpers ---

func nextBackoff(cur time.Duration) time.Duration {
	const max = 60 * time.Second
	if cur == 0 {
		return time.Second
	}
	if n := cur * 2; n < max {
		return n
	}
	return max
}

// sleepCtx sleeps for d, or returns false immediately if the context is cancelled.
func sleepCtx(ctx context.Context, d time.Duration) bool {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}

func parseLineCodes(s string) ([]int, error) {
	if strings.TrimSpace(s) == "" {
		return nil, errors.New("LINE_CODES is not set (comma-separated codigoLinha values)")
	}
	var out []int
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		n, err := strconv.Atoi(part)
		if err != nil {
			return nil, fmt.Errorf("invalid line code %q: %w", part, err)
		}
		out = append(out, n)
	}
	if len(out) == 0 {
		return nil, errors.New("LINE_CODES contained no valid codes")
	}
	return out, nil
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

-- init.sql — runs once on first DB initialisation via /docker-entrypoint-initdb.d.
-- Creates the Timescale extension and the single positions table as a hypertable.

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- The five columns from DESIGN §4.6. No primary key in 1a; de-duplication is a
-- later concern.
CREATE TABLE positions (
    vehicle_id text             NOT NULL,   -- vehicle prefix `p` from the API
    line_id    integer          NOT NULL,   -- codigoLinha `cl`
    ts         timestamptz      NOT NULL,   -- capture time `ta` (UTC)
    lat        double precision NOT NULL,   -- `py`
    lon        double precision NOT NULL    -- `px`
);

-- Turn the plain table into a Timescale hypertable partitioned by time. It still
-- behaves like a normal table for reads and writes; Timescale transparently splits
-- it into time-based chunks underneath. This is what earns the Timescale image in
-- v0 (DESIGN §4.4); compression and continuous aggregates arrive in v1.
SELECT create_hypertable('positions', by_range('ts'));

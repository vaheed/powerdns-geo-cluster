CREATE TABLE IF NOT EXISTS billing_events (
  id            BIGSERIAL PRIMARY KEY,
  event_ts      TIMESTAMPTZ NOT NULL DEFAULT now(),
  event_type    TEXT NOT NULL,
  location      TEXT NOT NULL,
  zone          TEXT,
  account       TEXT,
  metric_name   TEXT NOT NULL,
  metric_value  NUMERIC NOT NULL,
  meta          JSONB DEFAULT '{}'
);
CREATE INDEX IF NOT EXISTS billing_events_ts_idx   ON billing_events(event_ts);
CREATE INDEX IF NOT EXISTS billing_events_zone_idx ON billing_events(zone, event_ts);
CREATE INDEX IF NOT EXISTS billing_events_acct_idx ON billing_events(account, event_ts);

CREATE TABLE IF NOT EXISTS billing_hourly (
  hour          TIMESTAMPTZ NOT NULL,
  location      TEXT NOT NULL,
  zone          TEXT NOT NULL,
  account       TEXT NOT NULL,
  queries_total BIGINT NOT NULL DEFAULT 0,
  geo_hits      BIGINT NOT NULL DEFAULT 0,
  bytes_out     BIGINT NOT NULL DEFAULT 0,
  PRIMARY KEY (hour, location, zone)
);

CREATE OR REPLACE VIEW billing_monthly AS
SELECT
  date_trunc('month', hour) AS month,
  account,
  zone,
  SUM(queries_total) AS queries_total,
  SUM(geo_hits) AS geo_hits,
  SUM(bytes_out) AS bytes_out
FROM billing_hourly
GROUP BY 1,2,3;

CREATE TABLE IF NOT EXISTS billing_zone_meta (
  snapshot_ts   TIMESTAMPTZ NOT NULL DEFAULT now(),
  zone          TEXT NOT NULL,
  account       TEXT,
  record_count  INT,
  has_geo       BOOLEAN DEFAULT false,
  has_dnssec    BOOLEAN DEFAULT false,
  tier          TEXT DEFAULT 'standard'
);
CREATE INDEX IF NOT EXISTS billing_zone_meta_zone_idx ON billing_zone_meta(zone, snapshot_ts);

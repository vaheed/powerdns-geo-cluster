#!/usr/bin/env python3
import argparse
import json
import os
import time
from datetime import datetime, timezone

import psycopg2
import requests
from prometheus_client import Counter, Gauge, start_http_server

PDNS_URL = os.getenv("PDNS_API_URL", "http://pdns:8081/metrics")
PG_DSN = "dbname={db} user={user} password={pw} host={host}".format(
    db=os.getenv("POSTGRES_DB", "pdns"),
    user=os.getenv("POSTGRES_USER", "pdns"),
    pw=os.getenv("POSTGRES_PASSWORD", ""),
    host=os.getenv("POSTGRES_HOST", "postgres"),
)
LOCATION = os.getenv("LOCATION_NAME", "unknown")
DRY_RUN = False

q_counter = Counter("pdns_billing_queries_total", "Cumulative DNS queries per zone", ["zone", "account", "location"])
g_counter = Counter("pdns_billing_geo_hits_total", "Cumulative GEO LUA responses", ["zone", "account", "location"])
zone_g = Gauge("pdns_billing_zone_count", "Zones per account/tier", ["account", "tier"])
rec_g = Gauge("pdns_billing_record_count", "Records per zone", ["zone", "account"])
b_out = Counter("pdns_billing_bytes_out_total", "Estimated bytes out", ["zone", "location"])
last_ok = Gauge("billing_collector_last_success_ts", "Last successful cycle", ["component"])
repl_lag = Gauge("pdns_billing_replication_lag_seconds", "Replication lag", ["standby"])
cert_exp = Gauge("pdns_cert_expiry_seconds", "Cert expiry in seconds", ["cert", "node"])

state = {"pdns_total": None, "zones": {}}

def log(level, msg, component="billing-collector", extra=None):
    payload = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "level": level,
        "msg": msg,
        "loc": LOCATION,
        "component": component,
    }
    if extra:
        payload.update(extra)
    print(json.dumps(payload), flush=True)


def pg_connect():
    while True:
      try:
        return psycopg2.connect(PG_DSN)
      except Exception as exc:
        log("error", f"postgres reconnect failed: {exc}")
        time.sleep(3)


def write_event(cur, event_type, metric_name, metric_value, zone=None, account=None, meta=None):
    if DRY_RUN:
        log("info", "dry-run billing event", extra={"event_type": event_type, "metric_name": metric_name, "metric_value": metric_value})
        return
    cur.execute(
        """
        INSERT INTO billing_events(event_type, location, zone, account, metric_name, metric_value, meta)
        VALUES (%s,%s,%s,%s,%s,%s,%s::jsonb)
        """,
        (event_type, LOCATION, zone, account, metric_name, metric_value, json.dumps(meta or {})),
    )


def scrape_pdns_total():
    resp = requests.get(PDNS_URL, timeout=10)
    resp.raise_for_status()
    total = 0.0
    for line in resp.text.splitlines():
        if line.startswith("pdns_queries") and not line.startswith("#"):
            total += float(line.split()[-1])
    return total


def do_query_snapshot(conn):
    total = scrape_pdns_total()
    prev = state["pdns_total"]
    if prev is None:
        state["pdns_total"] = total
        return
    inc = max(0.0, total - prev)
    state["pdns_total"] = total
    with conn.cursor() as cur:
        write_event(cur, "query_snapshot", "queries_total", inc, zone="_all", account="_unknown")
    q_counter.labels("_all", "_unknown", LOCATION).inc(inc)
    b_out.labels("_all", LOCATION).inc(inc * 200)


def do_zone_audit(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT id,name,coalesce(account,'') FROM domains ORDER BY id")
        domains = cur.fetchall()
        for domain_id, zone, account in domains:
            cur.execute("SELECT type, COUNT(*) FROM records WHERE domain_id=%s GROUP BY type", (domain_id,))
            rc = {t: c for t, c in cur.fetchall()}
            has_geo = "LUA" in rc
            has_dnssec = any(t in rc for t in ("RRSIG", "DNSKEY", "NSEC", "NSEC3"))
            tier = "geo-dnssec" if has_geo and has_dnssec else ("geo" if has_geo else "standard")
            rec_count = sum(rc.values())
            rec_g.labels(zone, account or "_none").set(rec_count)
            zone_g.labels(account or "_none", tier).inc(0)
            write_event(cur, "zone_change", "record_count", rec_count, zone=zone, account=account or None, meta=rc)
            cur.execute(
                "INSERT INTO billing_zone_meta(zone, account, record_count, has_geo, has_dnssec, tier) VALUES (%s,%s,%s,%s,%s,%s)",
                (zone, account or None, rec_count, has_geo, has_dnssec, tier),
            )


def do_repl_lag(conn):
    with conn.cursor() as cur:
        cur.execute("SELECT application_name, extract(epoch from coalesce(write_lag,'0 second'::interval)) FROM pg_stat_replication")
        for standby, lag in cur.fetchall():
            lag = float(lag or 0)
            repl_lag.labels(standby).set(lag)
            write_event(cur, "replication_lag", "write_lag_seconds", lag, meta={"standby": standby})


def do_hourly_rollup(conn):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO billing_hourly(hour, location, zone, account, queries_total, geo_hits, bytes_out)
            SELECT date_trunc('hour', event_ts), location, coalesce(zone,'_all'), coalesce(account,'_unknown'),
              SUM(CASE WHEN metric_name='queries_total' THEN metric_value ELSE 0 END)::bigint,
              SUM(CASE WHEN metric_name='geo_hits' THEN metric_value ELSE 0 END)::bigint,
              SUM(CASE WHEN metric_name='bytes_out' THEN metric_value ELSE 0 END)::bigint
            FROM billing_events
            WHERE event_ts >= now() - interval '2 hour'
            GROUP BY 1,2,3,4
            ON CONFLICT (hour, location, zone)
            DO UPDATE SET
              queries_total=EXCLUDED.queries_total,
              geo_hits=EXCLUDED.geo_hits,
              bytes_out=EXCLUDED.bytes_out
            """
        )


def loop():
    conn = pg_connect()
    conn.autocommit = True
    last_zone = 0
    last_repl = 0
    last_roll = ""
    while True:
        try:
            do_query_snapshot(conn)
            now = time.time()
            if now - last_zone > 30:
                do_zone_audit(conn)
                last_zone = now
            if now - last_repl > 300:
                do_repl_lag(conn)
                last_repl = now
            hour_key = datetime.utcnow().strftime("%Y%m%d%H")
            if hour_key != last_roll and datetime.utcnow().minute == 0:
                do_hourly_rollup(conn)
                last_roll = hour_key
            last_ok.labels("collector").set(time.time())
            log("info", "collector cycle complete")
        except Exception as exc:
            log("error", f"collector cycle failed: {exc}")
            conn = pg_connect()
            conn.autocommit = True
        time.sleep(60)


def main():
    global DRY_RUN
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    DRY_RUN = args.dry_run
    start_http_server(9399)
    log("info", "billing collector started")
    loop()

if __name__ == "__main__":
    main()

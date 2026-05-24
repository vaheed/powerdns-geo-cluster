from fastapi import FastAPI, Query  # type: ignore[import-not-found]
from fastapi.responses import PlainTextResponse  # type: ignore[import-not-found]
import csv
import io
import os
from typing import Any

import yaml  # type: ignore[import-untyped]
import psycopg2  # type: ignore[import-untyped]

app = FastAPI()
PG = dict(
    dbname=os.getenv("POSTGRES_DB", "pdns"),
    user=os.getenv("POSTGRES_USER", "pdns"),
    password=os.getenv("POSTGRES_PASSWORD", ""),
    host=os.getenv("POSTGRES_HOST", "postgres"),
)
PRICING: dict[str, Any] = yaml.safe_load(open("/app/pricing.yml", "r", encoding="utf-8"))

def conn():
    return psycopg2.connect(**PG)

def charge(row):
    tier = row.get("tier", "standard")
    p = PRICING["tiers"].get(tier, PRICING["tiers"]["standard"])
    q = row["queries_total"] / 1_000_000.0
    g = row["geo_hits"] / 1_000_000.0
    return round(p.get("monthly_base_usd", 0) + q * p.get("per_million_queries_usd", 0) + g * p.get("per_million_geo_hits_usd", 0) + p.get("dnssec_surcharge_usd", 0), 4)

@app.get("/api/v1/billing/summary")
def summary(account: str = Query(...), month: str = Query(...)):
    with conn() as c, c.cursor() as cur:
        cur.execute("""
          SELECT m.zone,m.queries_total,m.geo_hits,coalesce(z.tier,'standard')
          FROM billing_monthly m
          LEFT JOIN LATERAL (
            SELECT tier FROM billing_zone_meta b WHERE b.zone=m.zone ORDER BY snapshot_ts DESC LIMIT 1
          ) z ON true
          WHERE m.account=%s AND to_char(m.month,'YYYY-MM')=%s
        """, (account, month))
        zones = [{"zone": z, "queries_total": q, "geo_hits": g, "tier": t, "charge_usd": charge({"queries_total": q, "geo_hits": g, "tier": t})} for z, q, g, t in cur.fetchall()]
    return {"account": account, "month": month, "zones": zones}

@app.get("/api/v1/billing/zones")
def zones(account: str = Query(...)):
    with conn() as c, c.cursor() as cur:
        cur.execute("""
          SELECT DISTINCT ON (zone) zone, account, record_count, has_geo, has_dnssec, tier
          FROM billing_zone_meta
          WHERE account=%s
          ORDER BY zone, snapshot_ts DESC
        """, (account,))
        rows = [dict(zip(["zone", "account", "record_count", "has_geo", "has_dnssec", "tier"], r)) for r in cur.fetchall()]
    return rows

@app.get("/api/v1/billing/events")
def events(account: str, from_ts: str, to_ts: str, type: str = "query_snapshot", limit: int = 200):
    with conn() as c, c.cursor() as cur:
        cur.execute("""
          SELECT id,event_ts,event_type,location,zone,account,metric_name,metric_value,meta
          FROM billing_events
          WHERE account=%s AND event_type=%s AND event_ts BETWEEN %s AND %s
          ORDER BY event_ts DESC LIMIT %s
        """, (account, type, from_ts, to_ts, limit))
        cols = [d[0] for d in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]

@app.get("/api/v1/billing/report")
def report(account: str, month: str, format: str = "csv"):
    data = summary(account, month)["zones"]
    out = io.StringIO()
    w = csv.DictWriter(out, fieldnames=["zone", "queries_total", "geo_hits", "tier", "charge_usd"])
    w.writeheader()
    w.writerows(data)
    return PlainTextResponse(out.getvalue(), media_type="text/csv")

# Billing Runbook

1. Verify collector:
`docker compose -f docker-compose.yml -f docker-compose.<loc>.yml -f docker-compose.monitoring.yml ps billing-collector`

2. Backfill hourly after outage:
Run collector once and execute rollup SQL insert from `collector.py` manually for missing time window.

3. Trigger monthly export:
`curl "http://127.0.0.1:8088/api/v1/billing/report?account=<acct>&month=2026-05&format=csv"`

4. Add pricing tier:
Edit `monitoring/billing-api/pricing.yml`, redeploy billing-api, then set zone tiers using `geo-dnsctl billing set-tier`.

5. Disputed usage:
Use `billing_events` filtered by account + period as source of truth (append-only audit trail).

# Billing System Overview

The billing layer is append-only and failover-safe by persisting immutable events in `billing_events` and idempotent rollups in `billing_hourly`.

Components:
- `monitoring/billing-collector/collector.py`: captures query snapshots, zone metadata, replication lag, and rollups.
- `monitoring/billing-api/main.py`: read-only API for finance/export systems.
- `monitoring/grafana/dashboards/dashboard-billing.json`: operations + finance view.

.PHONY: lint typecheck validate setup up-primary up-standbys check

lint:
	shellcheck scripts/*.sh docker/postgres/entrypoint.sh
	ruff check bin monitoring

typecheck:
	mypy monitoring/billing-api/main.py monitoring/billing-collector/collector.py

validate:
	./scripts/cluster.sh validate

setup:
	./scripts/cluster.sh init

up-primary:
	./scripts/cluster.sh up eu-ams

up-standbys:
	./scripts/cluster.sh up us-nyc
	./scripts/cluster.sh up as-teh

check:
	./scripts/cluster.sh check eu-ams

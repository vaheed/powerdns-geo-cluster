# Contributing

## Command model

This repository uses 2 scripts only:
- `scripts/cluster.sh` (all operations)
- `scripts/lib.sh` (shared helpers)

Do not add new standalone scripts unless absolutely necessary.

## Local quality gate

Run before PR:

```bash
make lint
make typecheck
make validate
```

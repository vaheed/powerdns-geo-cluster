# Adding a Location

Current `init` flow is optimized for the default 3-node topology.

For a new location, create new `config/locations/<loc>.env`, add compose override `docker-compose.<loc>.yml`, create WireGuard key files under `secrets/wireguard/`, then run:

```bash
./scripts/cluster.sh wireguard generate
./scripts/cluster.sh tls generate
./scripts/cluster.sh render all
./scripts/cluster.sh up <loc>
```

# Architecture

## Service layout

Each location runs two long-lived containers:

1. `pdns`: PowerDNS Authoritative, public UDP/TCP 53, API bound to localhost or management address.
2. `postgres`: local PostgreSQL database backing that location's PowerDNS instance.

The `geoipupdate` service is a manual maintenance container used to download MaxMind GeoLite2 databases after credentials are supplied.

```text
eu-ams primary writer
  PowerDNS API -> local PostgreSQL primary
                      |
                      | WAL streaming replication
                      v
us-nyc standby     local PostgreSQL hot standby -> local PowerDNS
as-teh standby     local PostgreSQL hot standby -> local PowerDNS
```

## Why PostgreSQL streaming replication

PowerDNS AXFR is intentionally disabled. Zone transfers are useful for DNS-native primary/secondary models, but this design stores authoritative state in PostgreSQL. Streaming replication gives each site a local read copy with deterministic single-writer semantics.

Only the primary accepts DNS changes. Standbys serve DNS from replicated PostgreSQL data and should not receive record writes.

## Sync paths

The normal path is WireGuard:

```text
standby -> 10.90.0.10:5432 over wg-pdns
```

The fallback path is the primary public IP:

```text
standby -> PRIMARY_PUBLIC_IP:5432
```

The fallback path is enabled in `primary_conninfo` by listing both hosts:

```text
host=10.90.0.10,PRIMARY_PUBLIC_IP port=5432,5432 target_session_attrs=read-write sslmode=verify-ca
```

PostgreSQL's libpq client logic tries the listed hosts. WireGuard should normally win. If the tunnel is down, the direct public-IP path can connect, but only if nftables and `pg_hba.conf` allow the standby's public IP.

## GEO DNS behavior

GEO routing is implemented with PowerDNS Lua records. A generated record looks like this:

```dns
www.example-geo.test. IN LUA A ";if continent('EU') then return '203.0.113.10' elseif continent('NA') then return '198.51.100.10' elseif continent('AS') then return '192.0.2.10' else return '203.0.113.100' end"
```

PowerDNS uses `bestwho`, which is the EDNS Client Subnet network when supplied, otherwise the resolver IP. This means GEO accuracy depends on the recursive resolver. Public resolvers that send ECS give better location signals. Resolvers that do not send ECS are routed by resolver location.

## Traffic steering

DNS traffic reaches the preferred location through your parent zone delegation and network design.

Basic unicast model:

```dns
example.com. NS ns1.example.net.  # eu-ams public IP
example.com. NS ns2.example.net.  # us-nyc public IP
example.com. NS ns3.example.net.  # as-teh public IP
```

Recursive resolvers choose among authoritative nameservers based on reachability, RTT, cache state, and resolver policy. This is adequate for many deployments but does not guarantee closest-site selection for the authoritative hop.

Production anycast model:

Advertise the same service IP from all sites using BGP anycast. DNS packets then reach the topologically nearest available site. Use upstream DDoS filtering or a DNS-focused scrubbing provider for high-volume public traffic.

## Adding locations

New locations are added by `scripts/bootstrap-location.sh`. The script creates:

- `config/locations/LOCATION.env`
- `docker-compose.LOCATION.yml`
- WireGuard peer config for every node
- PostgreSQL peer allow-list updates
- rendered PowerDNS/PostgreSQL config

The new node joins as a PostgreSQL standby and receives a base backup from the primary.

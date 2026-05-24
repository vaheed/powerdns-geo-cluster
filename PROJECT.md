# powerdns-geo-cluster

## File tree

```text
powerdns-geo-cluster/
├── bin/
│   └── geo-dnsctl
├── config/
│   ├── db/
│   │   ├── 20-init-primary.sh
│   │   ├── init.sql
│   │   ├── pg_hba.conf.template
│   │   └── postgresql.conf.template
│   ├── locations/
│   │   ├── as-teh.env
│   │   ├── eu-ams.env
│   │   └── us-nyc.env
│   └── pdns/
│       ├── as-teh/
│       │   ├── geo.conf
│       │   └── pdns.conf
│       ├── eu-ams/
│       │   ├── geo.conf
│       │   └── pdns.conf
│       ├── records/
│       │   └── example-geo.test.zone
│       ├── us-nyc/
│       │   ├── geo.conf
│       │   └── pdns.conf
│       ├── geoip-zones.yml
│       └── pdns.conf.template
├── docker/
│   └── postgres/
│       ├── Dockerfile
│       └── entrypoint.sh
├── docs/
│   ├── adding-location.md
│   ├── architecture.md
│   ├── backup-restore.md
│   ├── operations.md
│   ├── postgres-sync.md
│   ├── security.md
│   └── wireguard.md
├── scripts/
│   ├── nftables/
│   │   └── pdns-geo.nft
│   ├── apply-wireguard.sh
│   ├── backup.sh
│   ├── bootstrap-location.sh
│   ├── deploy-cluster.sh
│   ├── download-geoip.sh
│   ├── generate-postgres-tls.sh
│   ├── generate-wireguard-configs.sh
│   ├── healthcheck.sh
│   ├── install-nftables.sh
│   ├── lib.sh
│   ├── node-compose.sh
│   ├── push-node.sh
│   ├── render-config.sh
│   ├── restore.sh
│   ├── setup-cluster.sh
│   └── sync-zones.sh
├── tests/
│   └── test-geo-routing.sh
├── README.md
├── cluster-inventory.yml
├── docker-compose.as-teh.yml
├── docker-compose.eu-ams.yml
├── docker-compose.us-nyc.yml
├── docker-compose.yml
└── env.example
```

## Architecture summary

This project deploys one PowerDNS Authoritative and one PostgreSQL instance per location. The initial writer is `eu-ams`; `us-nyc` and `as-teh` are PostgreSQL hot standbys. Operators add and modify DNS records only through the primary PowerDNS API using `bin/geo-dnsctl`. PostgreSQL streaming replication keeps all locations synchronized. WireGuard is the preferred replication network. Public-IP PostgreSQL fallback is configured only for known peer public `/32` addresses and uses PostgreSQL TLS. Backups are encrypted client-side with GPG and uploaded to S3 with server-side encryption.

## Run commands

```bash
# First machine
cd powerdns-geo-cluster
cp env.example .env
./scripts/setup-cluster.sh

# Optional push and remote start
./scripts/deploy-cluster.sh

# Manual per-node start
sudo ./scripts/apply-wireguard.sh eu-ams
./scripts/node-compose.sh eu-ams up -d --build

sudo ./scripts/apply-wireguard.sh us-nyc
./scripts/node-compose.sh us-nyc up -d --build

sudo ./scripts/apply-wireguard.sh as-teh
./scripts/node-compose.sh as-teh up -d --build

# GeoIP database download after MaxMind credentials are set
./scripts/download-geoip.sh eu-ams

# Example domain
./bin/geo-dnsctl add-domain example-geo.test
./bin/geo-dnsctl add-geo-record example-geo.test www \
  --eu 203.0.113.10 \
  --na 198.51.100.10 \
  --asia 192.0.2.10 \
  --default 203.0.113.100 \
  --ttl 60

# Validation
./bin/geo-dnsctl validate
./scripts/healthcheck.sh eu-ams
./scripts/sync-zones.sh --check
./tests/test-geo-routing.sh eu-ams

# Firewall
sudo ./scripts/install-nftables.sh eu-ams
sudo ./scripts/install-nftables.sh us-nyc
sudo ./scripts/install-nftables.sh as-teh

# Backup and restore
./scripts/backup.sh
./scripts/restore.sh s3://BUCKET/PREFIX/eu-ams/pdns-eu-ams-YYYYmmddTHHMMSSZ.sql.gz.gpg

# Add new location
./scripts/bootstrap-location.sh --interactive
```

## Project files

### `README.md`

```markdown
# powerdns-geo-cluster

Production-oriented PowerDNS Authoritative GEO DNS cluster with three starting locations:

- `eu-ams`, Amsterdam, primary writer
- `us-nyc`, New York, standby reader
- `as-teh`, Tehran, standby reader

The deployment uses Docker Compose, PowerDNS Authoritative, PostgreSQL streaming replication, WireGuard for the normal replication path, restricted public-IP PostgreSQL fallback, encrypted S3 backups, nftables, and a small CLI named `geo-dnsctl`.

## Supported operating model

Write DNS data only on the primary node. The primary PostgreSQL database streams WAL to the standby locations. Each location runs its own PowerDNS Authoritative service and answers public DNS on UDP/TCP 53 from its local database copy.

Normal sync path:

```text
standby PostgreSQL -> WireGuard tunnel -> primary PostgreSQL
```

Fallback sync path:

```text
standby PostgreSQL -> primary public IP TCP/5432 -> primary PostgreSQL
```

The fallback is not open to the internet. nftables and `pg_hba.conf` restrict it to known node public IP addresses only. PostgreSQL TLS is enabled for both WireGuard and direct-public replication.

## Fast start

Install dependencies on all nodes first:

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin wireguard wireguard-tools nftables openssl jq curl dnsutils awscli gnupg rsync
```

On the first machine, clone or copy this repository, then run:

```bash
cd powerdns-geo-cluster
cp env.example .env
./scripts/setup-cluster.sh
```

The setup script asks for the primary node, standby nodes, public IPs, WireGuard IPs, SSH information, MaxMind credentials, and S3 backup settings. It generates all per-node files under `config/generated/`, `config/locations/`, and `secrets/`.

Start the primary:

```bash
./scripts/node-compose.sh eu-ams up -d --build
```

Start the standby nodes after WireGuard is up and the generated files are copied to each node:

```bash
./scripts/node-compose.sh us-nyc up -d --build
./scripts/node-compose.sh as-teh up -d --build
```

Load the example domain on the primary:

```bash
./bin/geo-dnsctl add-domain example-geo.test
./bin/geo-dnsctl add-geo-record example-geo.test www \
  --eu 203.0.113.10 \
  --na 198.51.100.10 \
  --asia 192.0.2.10 \
  --default 203.0.113.100 \
  --ttl 60
```

Validate:

```bash
./bin/geo-dnsctl validate
./scripts/healthcheck.sh
./scripts/sync-zones.sh --check
./tests/test-geo-routing.sh
```

Enable firewall:

```bash
sudo ./scripts/install-nftables.sh eu-ams
sudo ./scripts/install-nftables.sh us-nyc
sudo ./scripts/install-nftables.sh as-teh
```

Back up to encrypted S3:

```bash
./scripts/backup.sh
```

Restore to the primary from S3:

```bash
./scripts/restore.sh s3://YOUR_BUCKET/powerdns-geo-cluster/eu-ams/pdns-eu-ams-YYYYmmddTHHMMSSZ.sql.gz.gpg
```

## Current documentation references

This project follows these supported product behaviors:

- PowerDNS Authoritative PostgreSQL backend is read-write capable through the API.
- Lua records support GEO decisions through the GeoIP backend and EDNS Client Subnet.
- The PowerDNS built-in webserver/API should be bound and ACL-restricted.
- PostgreSQL streaming replication supports primary/standby operation; `primary_conninfo` uses libpq connection parameters.
- AWS CLI `s3 cp` supports server-side encryption modes including AES256 and `aws:kms`.

See `docs/` for the detailed production procedure.

```

### `bin/geo-dnsctl`

```bash
#!/usr/bin/env python3
import argparse, json, os, sys, urllib.request, urllib.error, urllib.parse, pathlib, ipaddress

ROOT = pathlib.Path(__file__).resolve().parents[1]

def load_env_file(path):
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line=line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        k,v=line.split('=',1)
        v=v.strip().strip('"').strip("'")
        os.environ.setdefault(k.strip(), v)

def load_env():
    load_env_file(ROOT/'.env')
    loc=os.environ.get('LOCATION_NAME')
    if not loc:
        # Prefer eu-ams for primary operations if present.
        loc='eu-ams'
    load_env_file(ROOT/'config'/'locations'/f'{loc}.env')

load_env()
API_BASE=os.environ.get('PDNS_API_URL','http://127.0.0.1:8081/api/v1/servers/localhost').rstrip('/')
API_KEY=os.environ.get('PDNS_API_KEY','')

def req(method, path, body=None, ok=(200,201,204)):
    if not API_KEY:
        raise SystemExit('PDNS_API_KEY is not set')
    data=None
    headers={'X-API-Key': API_KEY, 'Accept': 'application/json'}
    if body is not None:
        data=json.dumps(body).encode()
        headers['Content-Type']='application/json'
    url=API_BASE+path
    r=urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(r, timeout=15) as resp:
            raw=resp.read().decode()
            if resp.status not in ok:
                raise SystemExit(f'{method} {path} failed: HTTP {resp.status}: {raw}')
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw=e.read().decode(errors='replace')
        raise SystemExit(f'{method} {path} failed: HTTP {e.code}: {raw}')

def fqdn(name, domain=None):
    if name in ('@','') and domain:
        return domain.rstrip('.')+'.'
    if name.endswith('.'):
        return name
    if domain and not name.endswith(domain.rstrip('.')):
        return name+'.'+domain.rstrip('.')+'.'
    return name.rstrip('.')+'.'

def zone_id(domain):
    return urllib.parse.quote(domain.rstrip('.')+'.', safe='')

def add_domain(args):
    domain=args.domain.rstrip('.')+'.'
    nameservers=[f'ns1.{domain}', f'ns2.{domain}', f'ns3.{domain}']
    body={'name': domain, 'kind': 'Native', 'nameservers': nameservers}
    try:
        req('POST','/zones',body,ok=(201,204))
    except SystemExit as e:
        if 'already exists' not in str(e).lower() and '409' not in str(e):
            raise
    rrsets=[]
    ttl=int(args.ttl)
    ns_ips=[os.environ.get('NS1_IP','203.0.113.53'), os.environ.get('NS2_IP','198.51.100.53'), os.environ.get('NS3_IP','192.0.2.53')]
    for i,ip in enumerate(ns_ips, start=1):
        rrsets.append({'name': f'ns{i}.{domain}', 'type':'A', 'ttl':ttl, 'changetype':'REPLACE', 'records':[{'content':ip,'disabled':False}]})
    req('PATCH', f'/zones/{zone_id(domain)}', {'rrsets': rrsets}, ok=(204,))
    print(f'created or updated zone {domain}')

def add_record(args):
    domain=args.domain.rstrip('.')+'.'
    name=fqdn(args.name, domain)
    ip_validate(args.type, args.value)
    rr={'name':name,'type':args.type.upper(),'ttl':int(args.ttl),'changetype':'REPLACE','records':[{'content':args.value,'disabled':False}]}
    req('PATCH', f'/zones/{zone_id(domain)}', {'rrsets':[rr]}, ok=(204,))
    print(f'upserted {name} {args.type.upper()} {args.value}')

def ip_validate(rtype, value):
    rtype=rtype.upper()
    if rtype == 'A': ipaddress.ip_address(value)
    if rtype == 'AAAA': ipaddress.ip_address(value)

def add_geo_record(args):
    for v in [args.eu,args.na,args.asia,args.default]:
        ipaddress.ip_address(v)
    domain=args.domain.rstrip('.')+'.'
    name=fqdn(args.name, domain)
    lua=("A \";if continent('EU') then return '%s' "
         "elseif continent('NA') then return '%s' "
         "elseif continent('AS') then return '%s' "
         "else return '%s' end\"") % (args.eu,args.na,args.asia,args.default)
    rr={'name':name,'type':'LUA','ttl':int(args.ttl),'changetype':'REPLACE','records':[{'content':lua,'disabled':False}]}
    req('PATCH', f'/zones/{zone_id(domain)}', {'rrsets':[rr]}, ok=(204,))
    print(f'upserted GEO LUA A policy for {name}')

def list_domains(args):
    zones=req('GET','/zones') or []
    for z in zones:
        print(z.get('name',''))

def show_domain(args):
    z=req('GET', f'/zones/{zone_id(args.domain)}')
    print(json.dumps(z, indent=2, sort_keys=True))

def delete_domain(args):
    if not args.yes:
        raise SystemExit('refusing to delete without --yes')
    req('DELETE', f'/zones/{zone_id(args.domain)}', ok=(204,))
    print(f'deleted {args.domain}')

def sync(args):
    import subprocess
    subprocess.check_call([str(ROOT/'scripts'/'sync-zones.sh'),'--check'])

def validate(args):
    errors=[]
    try:
        req('GET','/servers/localhost')
    except SystemExit as e:
        errors.append(str(e))
    if not (ROOT/'config'/'pdxns').exists():
        pass
    for path in ['.env','docker-compose.yml','config/db/init.sql','config/pdns/pdns.conf.template']:
        if not (ROOT/path).exists(): errors.append(f'missing {path}')
    if errors:
        for e in errors: print('ERROR:', e, file=sys.stderr)
        return 1
    print('validation passed: API reachable and required files exist')
    return 0

def main():
    p=argparse.ArgumentParser(prog='geo-dnsctl')
    sub=p.add_subparsers(dest='cmd', required=True)
    s=sub.add_parser('add-domain'); s.add_argument('domain'); s.add_argument('--ttl', default=300); s.set_defaults(func=add_domain)
    s=sub.add_parser('add-record'); s.add_argument('domain'); s.add_argument('name'); s.add_argument('type'); s.add_argument('value'); s.add_argument('--ttl', default=300); s.set_defaults(func=add_record)
    s=sub.add_parser('add-geo-record'); s.add_argument('domain'); s.add_argument('name'); s.add_argument('--eu', required=True); s.add_argument('--na', required=True); s.add_argument('--asia', required=True); s.add_argument('--default', required=True); s.add_argument('--ttl', default=60); s.set_defaults(func=add_geo_record)
    s=sub.add_parser('list-domains'); s.set_defaults(func=list_domains)
    s=sub.add_parser('show-domain'); s.add_argument('domain'); s.set_defaults(func=show_domain)
    s=sub.add_parser('delete-domain'); s.add_argument('domain'); s.add_argument('--yes', action='store_true'); s.set_defaults(func=delete_domain)
    s=sub.add_parser('sync'); s.set_defaults(func=sync)
    s=sub.add_parser('validate'); s.set_defaults(func=validate)
    args=p.parse_args()
    rc=args.func(args)
    if isinstance(rc,int): sys.exit(rc)

if __name__=='__main__': main()

```

### `cluster-inventory.yml`

```yaml
# Generated and maintained by scripts/setup-cluster.sh and scripts/bootstrap-location.sh.
# The initial values below are documentation-safe examples. Run setup-cluster.sh before production use.
cluster:
  name: powerdns-geo-cluster
  primary: eu-ams
  wireguard_network_cidr: 10.90.0.0/24
  wireguard_port: 51820
  postgres_public_fallback_enabled: true
  backup_target: s3
nodes:
  - name: eu-ams
    role: primary
    region_code: EU
    city: Amsterdam
    public_dns_ip: CHANGE_ME_EU_AMS_PUBLIC_IP
    wireguard_ip: 10.90.0.10
    ssh_user: root
    ssh_port: 22
  - name: us-nyc
    role: standby
    region_code: NA
    city: New York
    public_dns_ip: CHANGE_ME_US_NYC_PUBLIC_IP
    wireguard_ip: 10.90.0.20
    ssh_user: root
    ssh_port: 22
  - name: as-teh
    role: standby
    region_code: AS
    city: Tehran
    public_dns_ip: CHANGE_ME_AS_TEH_PUBLIC_IP
    wireguard_ip: 10.90.0.30
    ssh_user: root
    ssh_port: 22

```

### `config/db/20-init-primary.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${LOCATION_ROLE:-primary}" != "primary" ]]; then
  exit 0
fi

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${POSTGRES_REPLICATION_USER}') THEN
    CREATE ROLE ${POSTGRES_REPLICATION_USER} WITH REPLICATION LOGIN PASSWORD '${POSTGRES_REPLICATION_PASSWORD}';
  ELSE
    ALTER ROLE ${POSTGRES_REPLICATION_USER} WITH REPLICATION LOGIN PASSWORD '${POSTGRES_REPLICATION_PASSWORD}';
  END IF;
END
\$\$;
SQL

```

### `config/db/init.sql`

```sql
-- PowerDNS Authoritative Generic PostgreSQL backend schema.
-- This schema follows the current gpgsql backend model: domains, records,
-- supermasters, comments, domainmetadata, cryptokeys, and tsigkeys.

CREATE TABLE IF NOT EXISTS domains (
  id                    SERIAL PRIMARY KEY,
  name                  VARCHAR(255) NOT NULL,
  master                VARCHAR(128) DEFAULT NULL,
  last_check            INT DEFAULT NULL,
  type                  VARCHAR(8) NOT NULL,
  notified_serial       INT DEFAULT NULL,
  account               VARCHAR(40) DEFAULT NULL,
  options               TEXT DEFAULT NULL,
  catalog               VARCHAR(255) DEFAULT NULL,
  CONSTRAINT c_lowercase_name CHECK (((name)::TEXT = lower((name)::TEXT)))
);
CREATE UNIQUE INDEX IF NOT EXISTS name_index ON domains(name);
CREATE INDEX IF NOT EXISTS catalog_idx ON domains(catalog);

CREATE TABLE IF NOT EXISTS records (
  id                    BIGSERIAL PRIMARY KEY,
  domain_id             INT DEFAULT NULL REFERENCES domains(id) ON DELETE CASCADE,
  name                  VARCHAR(255) DEFAULT NULL,
  type                  VARCHAR(10) DEFAULT NULL,
  content               TEXT DEFAULT NULL,
  ttl                   INT DEFAULT NULL,
  prio                  INT DEFAULT NULL,
  disabled              BOOLEAN DEFAULT false,
  ordername             VARCHAR(255),
  auth                  BOOLEAN DEFAULT true
);
CREATE INDEX IF NOT EXISTS rec_name_index ON records(name);
CREATE INDEX IF NOT EXISTS nametype_index ON records(name,type);
CREATE INDEX IF NOT EXISTS domain_id ON records(domain_id);
CREATE INDEX IF NOT EXISTS recordorder ON records(domain_id, ordername text_pattern_ops);

CREATE TABLE IF NOT EXISTS supermasters (
  ip                    INET NOT NULL,
  nameserver            VARCHAR(255) NOT NULL,
  account               VARCHAR(40) NOT NULL,
  PRIMARY KEY(ip, nameserver)
);

CREATE TABLE IF NOT EXISTS comments (
  id                    SERIAL PRIMARY KEY,
  domain_id             INT NOT NULL REFERENCES domains(id) ON DELETE CASCADE,
  name                  VARCHAR(255) NOT NULL,
  type                  VARCHAR(10) NOT NULL,
  modified_at           INT NOT NULL,
  account               VARCHAR(40) DEFAULT NULL,
  comment               TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS comments_name_type_idx ON comments(name, type);
CREATE INDEX IF NOT EXISTS comments_order_idx ON comments(domain_id, modified_at);

CREATE TABLE IF NOT EXISTS domainmetadata (
  id                    SERIAL PRIMARY KEY,
  domain_id             INT REFERENCES domains(id) ON DELETE CASCADE,
  kind                  VARCHAR(32),
  content               TEXT
);
CREATE INDEX IF NOT EXISTS domainmetadata_idx ON domainmetadata(domain_id, kind);

CREATE TABLE IF NOT EXISTS cryptokeys (
  id                    SERIAL PRIMARY KEY,
  domain_id             INT REFERENCES domains(id) ON DELETE CASCADE,
  flags                 INT NOT NULL,
  active                BOOLEAN,
  published             BOOLEAN DEFAULT true,
  content               TEXT
);
CREATE INDEX IF NOT EXISTS domainidindex ON cryptokeys(domain_id);

CREATE TABLE IF NOT EXISTS tsigkeys (
  id                    SERIAL PRIMARY KEY,
  name                  VARCHAR(255),
  algorithm             VARCHAR(50),
  secret                VARCHAR(255)
);
CREATE UNIQUE INDEX IF NOT EXISTS namealgoindex ON tsigkeys(name, algorithm);

```

### `config/db/pg_hba.conf.template`

```text
# TYPE  DATABASE        USER                      ADDRESS                 METHOD
local   all             all                                               trust
host    all             all                       127.0.0.1/32            scram-sha-256
host    all             all                       __DOCKER_DNS_SUBNET__   scram-sha-256
hostssl replication     __REPL_USER__             __WIREGUARD_NETWORK__   scram-sha-256
__PUBLIC_REPLICATION_HBA__
hostssl all             all                       __WIREGUARD_NETWORK__   scram-sha-256
hostssl all             all                       __MGMT_ALLOWED_CIDRS__  scram-sha-256
host    all             all                       0.0.0.0/0               reject
host    all             all                       ::/0                    reject

```

### `config/db/postgresql.conf.template`

```text
listen_addresses = '*'
port = 5432
max_connections = 200
shared_buffers = 256MB
effective_cache_size = 768MB
maintenance_work_mem = 64MB
checkpoint_completion_target = 0.9
wal_level = replica
wal_compression = on
max_wal_senders = 16
max_replication_slots = 16
hot_standby = on
wal_keep_size = __POSTGRES_WAL_KEEP_SIZE__
max_slot_wal_keep_size = __POSTGRES_MAX_SLOT_WAL_KEEP_SIZE__
synchronous_commit = local
password_encryption = scram-sha-256
ssl = on
ssl_cert_file = '/var/lib/postgresql/data/pgdata/tls/server.crt'
ssl_key_file = '/var/lib/postgresql/data/pgdata/tls/server.key'
ssl_ca_file = '/var/lib/postgresql/data/pgdata/tls/ca.crt'
log_connections = on
log_disconnections = on
log_line_prefix = '%m [%p] %u@%d %r '

```

### `config/locations/as-teh.env`

```text
LOCATION_NAME=as-teh
LOCATION_ROLE=standby
REGION_CODE=AS
LOCATION_CITY="Tehran"
PUBLIC_DNS_IP=CHANGE_ME_AS_TEH_PUBLIC_IP
WG_IPV4=10.90.0.30
WG_IPV4_CIDR=10.90.0.30/24
WG_PORT=51820
WG_PRIVATE_KEY=CHANGE_ME_GENERATED_BY_SETUP
WG_PUBLIC_KEY=CHANGE_ME_GENERATED_BY_SETUP
POSTGRES_PRIMARY_HOSTS=10.90.0.10,CHANGE_ME_EU_AMS_PUBLIC_IP
POSTGRES_PRIMARY_PORTS=5432,5432
REPLICATION_SLOT_NAME=eu_ams_as_teh
DOCKER_DNS_SUBNET=172.30.30.0/24

```

### `config/locations/eu-ams.env`

```text
LOCATION_NAME=eu-ams
LOCATION_ROLE=primary
REGION_CODE=EU
LOCATION_CITY="Amsterdam"
PUBLIC_DNS_IP=CHANGE_ME_EU_AMS_PUBLIC_IP
WG_IPV4=10.90.0.10
WG_IPV4_CIDR=10.90.0.10/24
WG_PORT=51820
WG_PRIVATE_KEY=CHANGE_ME_GENERATED_BY_SETUP
WG_PUBLIC_KEY=CHANGE_ME_GENERATED_BY_SETUP
POSTGRES_PRIMARY_HOSTS=
POSTGRES_PRIMARY_PORTS=5432,5432
REPLICATION_SLOT_NAME=
DOCKER_DNS_SUBNET=172.30.10.0/24

```

### `config/locations/us-nyc.env`

```text
LOCATION_NAME=us-nyc
LOCATION_ROLE=standby
REGION_CODE=NA
LOCATION_CITY="New York"
PUBLIC_DNS_IP=CHANGE_ME_US_NYC_PUBLIC_IP
WG_IPV4=10.90.0.20
WG_IPV4_CIDR=10.90.0.20/24
WG_PORT=51820
WG_PRIVATE_KEY=CHANGE_ME_GENERATED_BY_SETUP
WG_PUBLIC_KEY=CHANGE_ME_GENERATED_BY_SETUP
POSTGRES_PRIMARY_HOSTS=10.90.0.10,CHANGE_ME_EU_AMS_PUBLIC_IP
POSTGRES_PRIMARY_PORTS=5432,5432
REPLICATION_SLOT_NAME=eu_ams_us_nyc
DOCKER_DNS_SUBNET=172.30.20.0/24

```

### `config/pdns/as-teh/geo.conf`

```text
# GEO settings for as-teh. The authoritative GEO policy is stored as LUA records in PostgreSQL.
# Location code: as-teh
geoip-database-files=mmdb:/usr/share/GeoIP/GeoLite2-City.mmdb
edns-subnet-processing=yes

```

### `config/pdns/as-teh/pdns.conf`

```text
# Example generated PowerDNS config for as-teh.
# Run scripts/setup-cluster.sh to render production config into config/generated/as-teh/pdns/pdns.conf.
# This file documents the per-location config requirement; Docker mounts the generated file.
include-dir=/etc/powerdns/conf.d
launch=gpgsql,geoip
enable-lua-records=yes
enable-lua-record-updates=yes
edns-subnet-processing=yes
geoip-database-files=mmdb:/usr/share/GeoIP/GeoLite2-City.mmdb
geoip-zones-file=/etc/powerdns/geoip-zones.yml
disable-axfr=yes
api=yes
webserver=yes

```

### `config/pdns/eu-ams/geo.conf`

```text
# GEO settings for eu-ams. The authoritative GEO policy is stored as LUA records in PostgreSQL.
# Location code: eu-ams
geoip-database-files=mmdb:/usr/share/GeoIP/GeoLite2-City.mmdb
edns-subnet-processing=yes

```

### `config/pdns/eu-ams/pdns.conf`

```text
# Example generated PowerDNS config for eu-ams.
# Run scripts/setup-cluster.sh to render production config into config/generated/eu-ams/pdns/pdns.conf.
# This file documents the per-location config requirement; Docker mounts the generated file.
include-dir=/etc/powerdns/conf.d
launch=gpgsql,geoip
enable-lua-records=yes
enable-lua-record-updates=yes
edns-subnet-processing=yes
geoip-database-files=mmdb:/usr/share/GeoIP/GeoLite2-City.mmdb
geoip-zones-file=/etc/powerdns/geoip-zones.yml
disable-axfr=yes
api=yes
webserver=yes

```

### `config/pdns/geoip-zones.yml`

```yaml
# Minimal GeoIP backend zone file.
# This project stores actual customer zones in PostgreSQL and uses Lua records
# for GEO routing. The geoip backend is launched so Lua helpers such as
# continent(), country(), and continentCode() can use MaxMind data.
domains: []

```

### `config/pdns/pdns.conf.template`

```text
# Generated by scripts/render-config.sh. Do not edit generated copies manually.
launch=gpgsql,geoip
local-address=0.0.0.0
local-port=53
local-address-nonexist-fail=no

# Authoritative only. PowerDNS Authoritative does not provide recursion; keep resolver behavior out of this service.
version-string=anonymous
include-dir=/etc/powerdns/conf.d

# Generic PostgreSQL backend
gpgsql-host=postgres
gpgsql-port=5432
gpgsql-dbname=__POSTGRES_DB__
gpgsql-user=__POSTGRES_USER__
gpgsql-password=__POSTGRES_PASSWORD__
gpgsql-dnssec=yes
gpgsql-extra-connection-parameters=sslmode=disable

# Lua and GeoIP
# Lua GEO records require enable-lua-records and the geoip backend.
enable-lua-records=yes
enable-lua-record-updates=yes
edns-subnet-processing=yes
geoip-database-files=mmdb:/usr/share/GeoIP/GeoLite2-City.mmdb
geoip-zones-file=/etc/powerdns/geoip-zones.yml

# API and webserver. Expose only through localhost/management bindings and nftables.
webserver=yes
webserver-address=0.0.0.0
webserver-port=8081
webserver-allow-from=127.0.0.1,::1,__MGMT_ALLOWED_CIDRS__,__WIREGUARD_NETWORK__
webserver-password=__PDNS_WEBSERVER_PASSWORD__
webserver-max-bodysize=10
api=yes
api-key=__PDNS_API_KEY__

# Zone transfer is off because database streaming replication is the sync model.
disable-axfr=yes
allow-axfr-ips=
allow-dnsupdate-from=127.0.0.1,::1
allow-notify-from=
primary=no
secondary=no

# Performance and logs
receiver-threads=2
distributor-threads=3
max-tcp-connections=1000
max-tcp-connections-per-client=20
loglevel=__PDNS_LOGLEVEL__
log-dns-queries=no
log-dns-details=no
log-timestamp=yes
guardian=no
daemon=no

```

### `config/pdns/records/example-geo.test.zone`

```text
$ORIGIN example-geo.test.
$TTL 300
@ IN SOA ns1.example-geo.test. hostmaster.example-geo.test. 2026052501 300 120 1209600 300
@ IN NS ns1.example-geo.test.
@ IN NS ns2.example-geo.test.
@ IN NS ns3.example-geo.test.
ns1 IN A 203.0.113.53
ns2 IN A 198.51.100.53
ns3 IN A 192.0.2.53
www IN LUA A ";if continent('EU') then return '203.0.113.10' elseif continent('NA') then return '198.51.100.10' elseif continent('AS') then return '192.0.2.10' else return '203.0.113.100' end"

```

### `config/pdns/us-nyc/geo.conf`

```text
# GEO settings for us-nyc. The authoritative GEO policy is stored as LUA records in PostgreSQL.
# Location code: us-nyc
geoip-database-files=mmdb:/usr/share/GeoIP/GeoLite2-City.mmdb
edns-subnet-processing=yes

```

### `config/pdns/us-nyc/pdns.conf`

```text
# Example generated PowerDNS config for us-nyc.
# Run scripts/setup-cluster.sh to render production config into config/generated/us-nyc/pdns/pdns.conf.
# This file documents the per-location config requirement; Docker mounts the generated file.
include-dir=/etc/powerdns/conf.d
launch=gpgsql,geoip
enable-lua-records=yes
enable-lua-record-updates=yes
edns-subnet-processing=yes
geoip-database-files=mmdb:/usr/share/GeoIP/GeoLite2-City.mmdb
geoip-zones-file=/etc/powerdns/geoip-zones.yml
disable-axfr=yes
api=yes
webserver=yes

```

### `docker/postgres/Dockerfile`

```bash
FROM postgres:16-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates openssl \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/pdns-postgres-entrypoint.sh
RUN chmod +x /usr/local/bin/pdns-postgres-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/pdns-postgres-entrypoint.sh"]
CMD ["postgres"]

```

### `docker/postgres/entrypoint.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

: "${LOCATION_ROLE:=primary}"
: "${PGDATA:=/var/lib/postgresql/data/pgdata}"

prepare_tls() {
  if [[ -d /tls && -f /tls/server.crt && -f /tls/server.key && -f /tls/ca.crt ]]; then
    mkdir -p "$PGDATA/tls"
    cp /tls/server.crt /tls/server.key /tls/ca.crt "$PGDATA/tls/"
    chown -R postgres:postgres "$PGDATA/tls"
    chmod 700 "$PGDATA/tls"
    chmod 600 "$PGDATA/tls/server.key"
    chmod 644 "$PGDATA/tls/server.crt" "$PGDATA/tls/ca.crt"
  fi
}

prepare_tls

if [[ "$LOCATION_ROLE" == "standby" ]]; then
  if [[ -z "${POSTGRES_PRIMARY_HOSTS:-}" ]]; then
    echo "POSTGRES_PRIMARY_HOSTS is required on standby nodes" >&2
    exit 1
  fi
  if [[ -z "${REPLICATION_SLOT_NAME:-}" ]]; then
    echo "REPLICATION_SLOT_NAME is required on standby nodes" >&2
    exit 1
  fi
  if [[ ! -s "$PGDATA/PG_VERSION" ]]; then
    echo "Initializing standby from primary via pg_basebackup"
    rm -rf "$PGDATA"
    mkdir -p "$PGDATA"
    chown -R postgres:postgres "$(dirname "$PGDATA")"
    chmod 700 "$PGDATA"

    conninfo="host=${POSTGRES_PRIMARY_HOSTS} port=${POSTGRES_PRIMARY_PORTS:-5432} user=${POSTGRES_REPLICATION_USER} dbname=replication application_name=${LOCATION_NAME:-standby} sslmode=${POSTGRES_SYNC_SSLMODE:-verify-ca} sslrootcert=/tls/ca.crt connect_timeout=5 target_session_attrs=read-write"

    export PGPASSWORD="${POSTGRES_REPLICATION_PASSWORD}"
    until gosu postgres pg_basebackup -D "$PGDATA" -X stream -R -C -S "$REPLICATION_SLOT_NAME" -d "$conninfo"; do
      echo "pg_basebackup failed; retrying in 5 seconds" >&2
      sleep 5
    done
    unset PGPASSWORD

    echo "primary_conninfo = '$conninfo password=${POSTGRES_REPLICATION_PASSWORD}'" >> "$PGDATA/postgresql.auto.conf"
    echo "primary_slot_name = '$REPLICATION_SLOT_NAME'" >> "$PGDATA/postgresql.auto.conf"
    chown -R postgres:postgres "$PGDATA"
    chmod 700 "$PGDATA"
    prepare_tls
  fi
fi

exec /usr/local/bin/docker-entrypoint.sh "$@"

```

### `docker-compose.as-teh.yml`

```yaml
services:
  pdns:
    container_name: pdns-auth-as-teh
    env_file:
      - ./.env
      - ./config/locations/as-teh.env
    labels:
      com.powerdns_geo_cluster.location: "as-teh"
      com.powerdns_geo_cluster.service: "pdns-auth"
  postgres:
    container_name: pdns-postgres-as-teh
    env_file:
      - ./.env
      - ./config/locations/as-teh.env
    labels:
      com.powerdns_geo_cluster.location: "as-teh"
      com.powerdns_geo_cluster.service: "postgres"
  geoipupdate:
    container_name: pdns-geoipupdate-as-teh
    env_file:
      - ./.env
      - ./config/locations/as-teh.env
    labels:
      com.powerdns_geo_cluster.location: "as-teh"
      com.powerdns_geo_cluster.service: "geoipupdate"

```

### `docker-compose.eu-ams.yml`

```yaml
services:
  pdns:
    container_name: pdns-auth-eu-ams
    env_file:
      - ./.env
      - ./config/locations/eu-ams.env
    labels:
      com.powerdns_geo_cluster.location: "eu-ams"
      com.powerdns_geo_cluster.service: "pdns-auth"
  postgres:
    container_name: pdns-postgres-eu-ams
    env_file:
      - ./.env
      - ./config/locations/eu-ams.env
    labels:
      com.powerdns_geo_cluster.location: "eu-ams"
      com.powerdns_geo_cluster.service: "postgres"
  geoipupdate:
    container_name: pdns-geoipupdate-eu-ams
    env_file:
      - ./.env
      - ./config/locations/eu-ams.env
    labels:
      com.powerdns_geo_cluster.location: "eu-ams"
      com.powerdns_geo_cluster.service: "geoipupdate"

```

### `docker-compose.us-nyc.yml`

```yaml
services:
  pdns:
    container_name: pdns-auth-us-nyc
    env_file:
      - ./.env
      - ./config/locations/us-nyc.env
    labels:
      com.powerdns_geo_cluster.location: "us-nyc"
      com.powerdns_geo_cluster.service: "pdns-auth"
  postgres:
    container_name: pdns-postgres-us-nyc
    env_file:
      - ./.env
      - ./config/locations/us-nyc.env
    labels:
      com.powerdns_geo_cluster.location: "us-nyc"
      com.powerdns_geo_cluster.service: "postgres"
  geoipupdate:
    container_name: pdns-geoipupdate-us-nyc
    env_file:
      - ./.env
      - ./config/locations/us-nyc.env
    labels:
      com.powerdns_geo_cluster.location: "us-nyc"
      com.powerdns_geo_cluster.service: "geoipupdate"

```

### `docker-compose.yml`

```yaml
services:
  pdns:
    image: ${PDNS_IMAGE:-powerdns/pdns-auth-49:latest}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    command: ["--config-dir=/etc/powerdns"]
    ports:
      - "${PUBLIC_DNS_IP}:53:53/udp"
      - "${PUBLIC_DNS_IP}:53:53/tcp"
      - "${PDNS_API_BIND:-127.0.0.1}:${PDNS_API_PORT:-8081}:8081/tcp"
    volumes:
      - ./config/generated/${LOCATION_NAME}/pdns/pdns.conf:/etc/powerdns/pdns.conf:ro
      - ./config/pdns/geoip-zones.yml:/etc/powerdns/geoip-zones.yml:ro
      - ./data/geoip:/usr/share/GeoIP:ro
      - ./logs/pdns/${LOCATION_NAME}:/var/log/pdns
    networks:
      - dns_internal
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS -H 'X-API-Key: ${PDNS_API_KEY}' http://127.0.0.1:8081/api/v1/servers/localhost >/dev/null"]
      interval: 20s
      timeout: 5s
      retries: 6
      start_period: 20s
    security_opt:
      - no-new-privileges:true

  postgres:
    build:
      context: ./docker/postgres
    image: powerdns-geo-postgres:16
    restart: unless-stopped
    environment:
      LOCATION_NAME: ${LOCATION_NAME}
      LOCATION_ROLE: ${LOCATION_ROLE}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_REPLICATION_USER: ${POSTGRES_REPLICATION_USER}
      POSTGRES_REPLICATION_PASSWORD: ${POSTGRES_REPLICATION_PASSWORD}
      POSTGRES_PRIMARY_HOSTS: ${POSTGRES_PRIMARY_HOSTS:-}
      POSTGRES_PRIMARY_PORTS: ${POSTGRES_PRIMARY_PORTS:-5432}
      POSTGRES_SYNC_SSLMODE: ${POSTGRES_SYNC_SSLMODE:-verify-ca}
      REPLICATION_SLOT_NAME: ${REPLICATION_SLOT_NAME:-}
      PGDATA: /var/lib/postgresql/data/pgdata
    ports:
      - "${WG_IPV4}:5432:5432/tcp"
      - "${PUBLIC_DNS_IP}:5432:5432/tcp"
    volumes:
      - ./data/postgres/${LOCATION_NAME}:/var/lib/postgresql/data
      - ./config/generated/${LOCATION_NAME}/db/postgresql.conf:/etc/postgresql/postgresql.conf:ro
      - ./config/generated/${LOCATION_NAME}/db/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
      - ./config/db/init.sql:/docker-entrypoint-initdb.d/10-init.sql:ro
      - ./config/db/20-init-primary.sh:/docker-entrypoint-initdb.d/20-init-primary.sh:ro
      - ./secrets/postgres-tls/${LOCATION_NAME}:/tls:ro
    command: ["postgres", "-c", "config_file=/etc/postgresql/postgresql.conf", "-c", "hba_file=/etc/postgresql/pg_hba.conf"]
    networks:
      - dns_internal
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB} -h 127.0.0.1"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 30s
    security_opt:
      - no-new-privileges:true

  geoipupdate:
    image: ${GEOIPUPDATE_IMAGE:-ghcr.io/maxmind/geoipupdate:v7}
    restart: "no"
    environment:
      GEOIPUPDATE_ACCOUNT_ID: ${MAXMIND_ACCOUNT_ID}
      GEOIPUPDATE_LICENSE_KEY: ${MAXMIND_LICENSE_KEY}
      GEOIPUPDATE_EDITION_IDS: ${GEOIPUPDATE_EDITION_IDS:-GeoLite2-City}
      GEOIPUPDATE_FREQUENCY: "72"
    volumes:
      - ./data/geoip:/usr/share/GeoIP
    networks:
      - dns_internal
    profiles:
      - geoip

networks:
  dns_internal:
    driver: bridge
    internal: false
    ipam:
      config:
        - subnet: ${DOCKER_DNS_SUBNET:-172.30.53.0/24}

```

### `docs/adding-location.md`

```markdown
# Adding a location

## Example

Add Frankfurt as `eu-fra`:

```bash
./scripts/bootstrap-location.sh eu-fra 203.0.113.44 10.90.0.40 EU root 22
```

The script is idempotent. If the location already exists, it refreshes generated configuration.

## What the script changes

It creates or updates:

```text
config/locations/eu-fra.env
docker-compose.eu-fra.yml
config/generated/eu-fra/wireguard/wg-pdns.conf
config/generated/eu-fra/pdns/pdns.conf
config/generated/eu-fra/db/postgresql.conf
config/generated/eu-fra/db/pg_hba.conf
config/generated/cluster-peer-public-cidrs
cluster-inventory.yml
```

## Apply on the primary

After adding a node, reload the primary WireGuard configuration and firewall:

```bash
sudo ./scripts/apply-wireguard.sh eu-ams
sudo ./scripts/install-nftables.sh eu-ams
./scripts/node-compose.sh eu-ams restart postgres
```

Restarting PostgreSQL is needed only when `pg_hba.conf` changes and a reload is not enough in your operational policy. A reload normally suffices:

```bash
docker exec pdns-postgres-eu-ams pg_ctl reload -D /var/lib/postgresql/data/pgdata
```

## Start the new node

Copy the repository to the new node:

```bash
./scripts/push-node.sh eu-fra
```

On the new node:

```bash
sudo ./scripts/apply-wireguard.sh eu-fra
sudo ./scripts/install-nftables.sh eu-fra
./scripts/node-compose.sh eu-fra up -d --build
```

The first boot initializes PostgreSQL by streaming a base backup from the primary.

## Remove a location safely

1. Remove the location's NS record at the parent zone and wait at least the parent-zone TTL.
2. Stop containers on the removed node.
3. Remove its WireGuard peer from all remaining generated configs.
4. Remove its public `/32` from `config/generated/cluster-peer-public-cidrs`.
5. Drop the PostgreSQL replication slot on the primary:

```sql
SELECT pg_drop_replication_slot('eu_ams_LOCATION');
```

6. Re-render configs and re-apply nftables.

```

### `docs/architecture.md`

```markdown
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

```

### `docs/backup-restore.md`

```markdown
# Encrypted S3 backup and restore

## Backup design

Backups are created on the primary node only. The process is:

1. Run `pg_dump` from the PostgreSQL container.
2. Compress with gzip.
3. Encrypt client-side with GPG symmetric AES256.
4. Upload to S3 with server-side encryption enabled.
5. Remove local encrypted files unless `KEEP_LOCAL_BACKUPS=true`.

This gives encryption before the object reaches S3 and encryption at rest inside S3.

## Required environment

```env
S3_BUCKET=your-bucket
S3_PREFIX=powerdns-geo-cluster
S3_REGION=eu-west-1
S3_SSE_MODE=aws:kms
S3_KMS_KEY_ID=alias/pdns-backups
BACKUP_GPG_PASSPHRASE_FILE=./secrets/backup-gpg-passphrase
```

For S3-compatible storage, set:

```env
S3_ENDPOINT_URL=https://s3.example.net
S3_SSE_MODE=AES256
```

## AWS IAM minimum

The backup identity needs:

- `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` for the target bucket/prefix
- `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey` when SSE-KMS is used

## Run backup

```bash
./scripts/backup.sh
```

## Restore

```bash
./scripts/restore.sh s3://bucket/prefix/eu-ams/pdns-eu-ams-YYYYmmddTHHMMSSZ.sql.gz.gpg
```

The script requires typing `RESTORE` before it applies the SQL. After a full restore, reinitialize standbys if there is any sign of replication divergence.

```

### `docs/operations.md`

```markdown
# Operations guide

## First machine setup

Run all cluster generation from the first machine, normally `eu-ams`.

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin wireguard wireguard-tools nftables openssl jq curl dnsutils awscli gnupg rsync
cd /opt
unzip powerdns-geo-cluster.zip
cd powerdns-geo-cluster
cp env.example .env
./scripts/setup-cluster.sh
```

The setup script asks for:

- public DNS IP for every node
- WireGuard IP for every node
- SSH user and port
- management CIDRs
- MaxMind account and license key
- S3 bucket, region, and encryption mode

After the script completes, copy the project directory to every standby node:

```bash
./scripts/push-node.sh us-nyc
./scripts/push-node.sh as-teh
```

Password SSH is intentionally not automated by default. Use SSH keys. If you must use password SSH for a temporary bootstrap, install `sshpass` yourself and remove password auth afterward.

## Start WireGuard

On each node:

```bash
sudo ./scripts/apply-wireguard.sh eu-ams
sudo ./scripts/apply-wireguard.sh us-nyc
sudo ./scripts/apply-wireguard.sh as-teh
```

Use the location that matches the current host.

Check tunnel state:

```bash
sudo wg show wg-pdns
ping -c 3 10.90.0.10
```

## Start containers

Start the primary first:

```bash
./scripts/node-compose.sh eu-ams up -d --build
```

Wait until PostgreSQL and PowerDNS are healthy:

```bash
./scripts/healthcheck.sh eu-ams
```

Then start standbys:

```bash
./scripts/node-compose.sh us-nyc up -d --build
./scripts/node-compose.sh as-teh up -d --build
```

Each standby performs `pg_basebackup` on first boot. It will retry until the primary is reachable.

## Download MaxMind GeoLite2

MaxMind credentials are required. They are not bundled.

```bash
./scripts/download-geoip.sh eu-ams
```

Copy `data/geoip/` to the other nodes or run the same command on each node. Restart PowerDNS after the first database download:

```bash
./scripts/node-compose.sh eu-ams restart pdns
```

## Add a domain

Always run write commands on the primary.

```bash
./bin/geo-dnsctl add-domain example.com
./bin/geo-dnsctl add-record example.com @ A 203.0.113.20 --ttl 300
./bin/geo-dnsctl add-record example.com mail A 203.0.113.25 --ttl 300
./bin/geo-dnsctl add-record example.com @ MX '10 mail.example.com.' --ttl 300
```

## Add a GEO record

```bash
./bin/geo-dnsctl add-geo-record example.com www \
  --eu 203.0.113.10 \
  --na 198.51.100.10 \
  --asia 192.0.2.10 \
  --default 203.0.113.100 \
  --ttl 60
```

## Validate GEO behavior

```bash
./tests/test-geo-routing.sh eu-ams www.example-geo.test EU_PUBLIC_IP
```

Manual ECS tests:

```bash
dig @EU_PUBLIC_IP www.example-geo.test A +subnet=80.101.1.1/32 +short
dig @EU_PUBLIC_IP www.example-geo.test A +subnet=8.8.8.8/32 +short
dig @EU_PUBLIC_IP www.example-geo.test A +subnet=202.12.27.33/32 +short
```

## Check replication

On the primary:

```bash
./scripts/sync-zones.sh --check
```

On a standby:

```bash
LOCATION_NAME=us-nyc ./scripts/sync-zones.sh --check
```

## Recover a failed standby

If a standby falls too far behind and its replication slot no longer has required WAL:

```bash
LOCATION_NAME=us-nyc ./scripts/sync-zones.sh --reinit-standby
```

This deletes the standby's local PostgreSQL data and takes a fresh base backup from the primary. Do not run this on the primary.

## Backups

Backups are encrypted locally with GPG symmetric AES256 before upload to S3. The S3 upload also requests server-side encryption, either SSE-KMS or SSE-S3.

```bash
./scripts/backup.sh
```

The local encrypted backup is removed by default after upload. Set `KEEP_LOCAL_BACKUPS=true` only if the local disk is protected and monitored.

## Restore

Restore only to the primary:

```bash
./scripts/restore.sh s3://BUCKET/PREFIX/eu-ams/pdns-eu-ams-YYYYmmddTHHMMSSZ.sql.gz.gpg
```

After a major restore, reinitialize standbys to guarantee they follow the restored primary state.

## Optional one-pass remote deployment

After `setup-cluster.sh` generates all files, you can use the interactive deployment helper from the first machine:

```bash
./scripts/deploy-cluster.sh
```

It asks before touching each node. For each accepted node it copies the repository to `/opt/powerdns-geo-cluster`, applies WireGuard, optionally applies nftables if `INSTALL_FIREWALL_DURING_DEPLOY=true`, and starts the node's Compose stack.

Key-based SSH is preferred:

```env
SSH_USER=root
SSH_PORT=22
SSH_KEY=/root/.ssh/pdns-cluster-ed25519
SSH_PASSWORD=
```

Temporary password bootstrap is supported only when `sshpass` is installed on the first machine:

```env
SSH_USER=root
SSH_PORT=22
SSH_KEY=
SSH_PASSWORD=TEMPORARY_PASSWORD
```

Remove password SSH after bootstrap.

```

### `docs/postgres-sync.md`

```markdown
# PostgreSQL synchronization

## Model

The cluster uses one PostgreSQL writer and multiple hot standbys.

- `eu-ams` is the initial primary.
- `us-nyc` and `as-teh` are read-only standbys.
- PowerDNS reads local PostgreSQL in every location.
- `geo-dnsctl` writes only through the primary PowerDNS API.

## Standby initialization

On first startup, a standby runs `pg_basebackup` against the primary and creates a physical replication slot. The slot name is stored in `config/locations/LOCATION.env`.

Example:

```env
REPLICATION_SLOT_NAME=eu_ams_us_nyc
POSTGRES_PRIMARY_HOSTS=10.90.0.10,PRIMARY_PUBLIC_IP
POSTGRES_PRIMARY_PORTS=5432,5432
POSTGRES_SYNC_SSLMODE=verify-ca
```

## Fallback host order

The host list is ordered. WireGuard comes first:

```text
10.90.0.10,PRIMARY_PUBLIC_IP
```

If the tunnel is healthy, replication uses WireGuard. If WireGuard fails, libpq can connect to the primary public IP. The public fallback must remain restricted to known node public `/32` addresses.

## Conflict avoidance

There is no multi-master mode. Do not promote or write to standby nodes unless you are executing a disaster-recovery runbook. This prevents split-brain records.

## Monitoring

Primary:

```bash
./scripts/sync-zones.sh --check
```

Standby:

```bash
LOCATION_NAME=us-nyc ./scripts/sync-zones.sh --check
```

## Rebuild a standby

```bash
LOCATION_NAME=us-nyc ./scripts/sync-zones.sh --reinit-standby
```

This deletes the standby's local database copy and creates a fresh base backup.

```

### `docs/security.md`

```markdown
# Security guide

## Exposed ports

Public internet:

- UDP 53
- TCP 53
- UDP WireGuard port, default 51820
- TCP 5432 only from known cluster peer public IPs, for fallback replication

Management only:

- SSH
- PowerDNS API, default bound to `127.0.0.1`

The PowerDNS API is enabled because `geo-dnsctl` uses it, but it must not be exposed publicly.

## nftables

Install nftables after confirming your management CIDRs are correct:

```bash
sudo ./scripts/install-nftables.sh eu-ams
```

The policy is default deny. Denied packets are logged with the prefix `pdns_geo_drop`.

## PostgreSQL fallback over public IPs

The fallback path is not a general database listener. It is restricted in three layers:

1. Docker binds PostgreSQL only to the node public IP and WireGuard IP.
2. nftables allows TCP 5432 only from cluster peer public IPs and the WireGuard CIDR.
3. `pg_hba.conf` allows replication only from the WireGuard CIDR and explicit peer public `/32` addresses.

PostgreSQL TLS is enabled and standbys verify the generated cluster CA.

## Secrets

Protect these paths:

```text
.env
secrets/
config/locations/*.env
config/generated/*/pdns/pdns.conf
```

They contain API keys, database passwords, WireGuard private keys, and backup encryption material.

## DDoS notes

nftables rate limiting is not DDoS protection. For production authoritative DNS traffic, use anycast with upstream filtering, a DNS DDoS provider, or provider-level ACL/scrubbing. DNS UDP amplification exposure should be monitored continuously.

## AXFR and TSIG

AXFR is disabled because database replication is the sync model. If you later enable AXFR for external secondaries, use TSIG and a dedicated allow-list. Do not enable unauthenticated AXFR on public interfaces.

```

### `docs/wireguard.md`

```markdown
# WireGuard sync network

## Purpose

WireGuard is the preferred replication network. PostgreSQL streaming replication should use the WireGuard IP first and the public primary IP only as a fallback.

Default IP plan:

| Location | Role | WireGuard IP |
|---|---:|---:|
| eu-ams | primary | 10.90.0.10 |
| us-nyc | standby | 10.90.0.20 |
| as-teh | standby | 10.90.0.30 |

## Generate configuration

Run on the first machine:

```bash
./scripts/setup-cluster.sh
```

The script generates:

```text
config/generated/eu-ams/wireguard/wg-pdns.conf
config/generated/us-nyc/wireguard/wg-pdns.conf
config/generated/as-teh/wireguard/wg-pdns.conf
```

## Install on a node

On the matching node:

```bash
sudo ./scripts/apply-wireguard.sh eu-ams
```

Use the current node's location name.

## Verify

```bash
sudo wg show wg-pdns
ping -c 3 10.90.0.10
```

From standbys, PostgreSQL should connect to `10.90.0.10` during normal operation.

## Failure behavior

When WireGuard is down, standby PostgreSQL reconnects through the next host in `POSTGRES_PRIMARY_HOSTS`, normally the primary public IP. The fallback is protected by nftables, `pg_hba.conf`, and PostgreSQL TLS.

## Adding a peer

Use:

```bash
./scripts/bootstrap-location.sh --interactive
```

Then re-apply WireGuard on every existing node because each WireGuard node needs the new peer block.

```

### `env.example`

```text
# powerdns-geo-cluster global environment
# Copy this file to .env, then run scripts/setup-cluster.sh.
# Do not commit .env, generated keys, generated TLS material, or backups.

COMPOSE_PROJECT_NAME=powerdns-geo-cluster

# Container images
PDNS_IMAGE=powerdns/pdns-auth-49:latest
POSTGRES_IMAGE=postgres:16-bookworm
GEOIPUPDATE_IMAGE=ghcr.io/maxmind/geoipupdate:v7

# PowerDNS API. Bind the API to localhost by default. Do not expose it publicly.
PDNS_API_BIND=127.0.0.1
PDNS_API_PORT=8081
PDNS_API_URL=http://127.0.0.1:8081/api/v1/servers/localhost
PDNS_API_KEY=CHANGE_ME_GENERATED_BY_SETUP
PDNS_WEBSERVER_PASSWORD=CHANGE_ME_GENERATED_BY_SETUP
PDNS_DEFAULT_TTL=300
PDNS_LOGLEVEL=4

# PostgreSQL users. Passwords are generated by setup-cluster.sh.
POSTGRES_DB=pdns
POSTGRES_USER=pdns
POSTGRES_PASSWORD=CHANGE_ME_GENERATED_BY_SETUP
POSTGRES_REPLICATION_USER=replicator
POSTGRES_REPLICATION_PASSWORD=CHANGE_ME_GENERATED_BY_SETUP
POSTGRES_SYNC_SSLMODE=verify-ca
POSTGRES_PUBLIC_FALLBACK_ENABLED=true
POSTGRES_PORT=5432
POSTGRES_WAL_KEEP_SIZE=2048MB
POSTGRES_MAX_SLOT_WAL_KEEP_SIZE=10240MB

# MaxMind GeoLite2. Leave blank until you have a MaxMind account/license key.
MAXMIND_ACCOUNT_ID=
MAXMIND_LICENSE_KEY=
GEOIPUPDATE_EDITION_IDS=GeoLite2-City
GEOIP_DB_PATH=/usr/share/GeoIP/GeoLite2-City.mmdb

# Cluster defaults. setup-cluster.sh generates config/locations/*.env.
WIREGUARD_NETWORK_CIDR=10.90.0.0/24
WIREGUARD_PORT=51820
WIREGUARD_PERSISTENT_KEEPALIVE=25
WIREGUARD_MTU=1420

# Management source CIDRs allowed to SSH and PowerDNS API.
# Example: 203.0.113.55/32,198.51.100.0/24
MGMT_ALLOWED_CIDRS=CHANGE_ME_ADMIN_PUBLIC_IP_OR_CIDR
SSH_PORT=22
SSH_USER=root
SSH_KEY=
SSH_PASSWORD=

# Encrypted S3 backups. setup-cluster.sh asks for these values.
BACKUP_ENABLED=true
BACKUP_TMP_DIR=./run/backups/tmp
KEEP_LOCAL_BACKUPS=false
S3_BUCKET=CHANGE_ME_BUCKET_NAME
S3_PREFIX=powerdns-geo-cluster
S3_REGION=eu-west-1
S3_ENDPOINT_URL=
S3_SSE_MODE=aws:kms
S3_KMS_KEY_ID=CHANGE_ME_KMS_KEY_ID_OR_ALIAS
BACKUP_GPG_PASSPHRASE_FILE=./secrets/backup-gpg-passphrase
BACKUP_RETENTION_DAYS=35

# Runtime paths. These are bind mounts, not Docker named volumes.
DATA_DIR=./data
GENERATED_DIR=./config/generated
SECRETS_DIR=./secrets
LOG_DIR=./logs

```

### `scripts/apply-wireguard.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root_for_firewall
loc="${1:-}"
[[ -n "$loc" ]] || fatal "usage: $0 LOCATION"
conf="$PROJECT_ROOT/config/generated/$loc/wireguard/wg-pdns.conf"
[[ -f "$conf" ]] || fatal "missing $conf; run setup-cluster.sh or bootstrap-location.sh first"
need wg
need wg-quick
install -d -m 700 /etc/wireguard
install -m 600 "$conf" /etc/wireguard/wg-pdns.conf
systemctl enable --now wg-quick@wg-pdns
wg show wg-pdns

```

### `scripts/backup.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
loc="${LOCATION_NAME:-eu-ams}"
load_env "$loc"
[[ "$LOCATION_ROLE" == "primary" ]] || fatal "run backups on the primary only"
need docker
need gzip
need gpg
need aws

ts="$(date -u +%Y%m%dT%H%M%SZ)"
work="$PROJECT_ROOT/${BACKUP_TMP_DIR:-run/backups/tmp}"
mkdir -p "$work"
plain="$work/pdns-${LOCATION_NAME}-${ts}.sql"
gz="$plain.gz"
enc="$gz.gpg"
sha="$enc.sha256"

[[ -f "$BACKUP_GPG_PASSPHRASE_FILE" ]] || fatal "missing BACKUP_GPG_PASSPHRASE_FILE=$BACKUP_GPG_PASSPHRASE_FILE"

docker exec "pdns-postgres-$LOCATION_NAME" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=plain --clean --if-exists --no-owner --no-privileges > "$plain"
gzip -9 "$plain"
gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" \
  --symmetric --cipher-algo AES256 -o "$enc" "$gz"
sha256sum "$enc" > "$sha"

s3_uri="s3://${S3_BUCKET}/${S3_PREFIX}/${LOCATION_NAME}/$(basename "$enc")"
aws_args=(s3 cp "$enc" "$s3_uri" --region "$S3_REGION")
[[ -n "${S3_ENDPOINT_URL:-}" ]] && aws_args+=(--endpoint-url "$S3_ENDPOINT_URL")
if [[ "${S3_SSE_MODE:-aws:kms}" == "aws:kms" ]]; then
  aws_args+=(--sse aws:kms --sse-kms-key-id "$S3_KMS_KEY_ID")
else
  aws_args+=(--sse AES256)
fi
aws "${aws_args[@]}"
aws s3 cp "$sha" "$s3_uri.sha256" --region "$S3_REGION" ${S3_ENDPOINT_URL:+--endpoint-url "$S3_ENDPOINT_URL"}

if [[ "${KEEP_LOCAL_BACKUPS:-false}" != "true" ]]; then
  rm -f "$gz" "$enc" "$sha"
fi
log "backup uploaded: $s3_uri"

```

### `scripts/bootstrap-location.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need wg

usage() {
  cat >&2 <<'EOF'
usage: scripts/bootstrap-location.sh [--interactive] LOCATION PUBLIC_DNS_IP WIREGUARD_IP REGION_CODE [SSH_USER] [SSH_PORT]

Example:
  ./scripts/bootstrap-location.sh eu-fra 203.0.113.44 10.90.0.40 EU root 22
EOF
  exit 2
}

if [[ "${1:-}" == "--interactive" ]]; then
  read -r -p "Location name: " loc
  read -r -p "Public DNS IP: " public_ip
  read -r -p "WireGuard IP, example 10.90.0.40: " wg_ip
  read -r -p "Region code, example EU/NA/AS: " region
  read -r -p "SSH user [root]: " ssh_user; ssh_user="${ssh_user:-root}"
  read -r -p "SSH port [22]: " ssh_port; ssh_port="${ssh_port:-22}"
else
  [[ $# -ge 4 ]] || usage
  loc="$1"; public_ip="$2"; wg_ip="$3"; region="$4"; ssh_user="${5:-root}"; ssh_port="${6:-22}"
fi

load_env
[[ "$loc" =~ ^[a-z0-9][a-z0-9-]+$ ]] || fatal "invalid location name: $loc"
mkdir -p "$PROJECT_ROOT/config/locations" "$PROJECT_ROOT/secrets/wireguard"

if [[ -f "$PROJECT_ROOT/config/locations/$loc.env" ]]; then
  log "$loc already exists; refreshing rendered config only"
else
  priv="$(wg genkey)"
  pub="$(printf '%s' "$priv" | wg pubkey)"
  printf '%s\n' "$priv" > "$PROJECT_ROOT/secrets/wireguard/$loc.private"
  printf '%s\n' "$pub" > "$PROJECT_ROOT/secrets/wireguard/$loc.public"
  chmod 600 "$PROJECT_ROOT/secrets/wireguard/$loc.private"
  slot="eu_ams_${loc//-/_}"
  primary_public="$(awk -F= '/^PUBLIC_DNS_IP=/{print $2; exit}' "$PROJECT_ROOT/config/locations/eu-ams.env")"
  cat > "$PROJECT_ROOT/config/locations/$loc.env" <<EOF
LOCATION_NAME=$loc
LOCATION_ROLE=standby
REGION_CODE=$region
LOCATION_CITY="$loc"
PUBLIC_DNS_IP=$public_ip
WG_IPV4=$wg_ip
WG_IPV4_CIDR=$wg_ip/24
WG_PORT=${WIREGUARD_PORT:-51820}
WG_PRIVATE_KEY=$priv
WG_PUBLIC_KEY=$pub
POSTGRES_PRIMARY_HOSTS=10.90.0.10,$primary_public
POSTGRES_PRIMARY_PORTS=5432,5432
REPLICATION_SLOT_NAME=$slot
DOCKER_DNS_SUBNET=172.30.$((RANDOM % 100 + 40)).0/24
EOF
fi

# Update peer public CIDRs.
peers=""
for f in "$PROJECT_ROOT"/config/locations/*.env; do
  pub="$(awk -F= '/^PUBLIC_DNS_IP=/{print $2; exit}' "$f")"
  [[ -n "$pub" ]] || continue
  [[ -n "$peers" ]] && peers+=","
  peers+="$pub/32"
done
mkdir -p "$PROJECT_ROOT/config/generated"
printf '%s\n' "$peers" > "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs"

# Add to inventory if not present.
if ! grep -q "name: $loc" "$PROJECT_ROOT/cluster-inventory.yml"; then
  cat >> "$PROJECT_ROOT/cluster-inventory.yml" <<EOF
  - name: $loc
    role: standby
    region_code: $region
    city: $loc
    public_dns_ip: $public_ip
    wireguard_ip: $wg_ip
    ssh_user: $ssh_user
    ssh_port: $ssh_port
EOF
fi

if [[ ! -f "$PROJECT_ROOT/docker-compose.$loc.yml" ]]; then
  cat > "$PROJECT_ROOT/docker-compose.$loc.yml" <<EOF
services:
  pdns:
    container_name: pdns-auth-$loc
    env_file:
      - ./.env
      - ./config/locations/$loc.env
    labels:
      com.powerdns_geo_cluster.location: "$loc"
      com.powerdns_geo_cluster.service: "pdns-auth"
  postgres:
    container_name: pdns-postgres-$loc
    env_file:
      - ./.env
      - ./config/locations/$loc.env
    labels:
      com.powerdns_geo_cluster.location: "$loc"
      com.powerdns_geo_cluster.service: "postgres"
  geoipupdate:
    container_name: pdns-geoipupdate-$loc
    env_file:
      - ./.env
      - ./config/locations/$loc.env
    labels:
      com.powerdns_geo_cluster.location: "$loc"
      com.powerdns_geo_cluster.service: "geoipupdate"
EOF
fi

./scripts/generate-wireguard-configs.sh
./scripts/generate-postgres-tls.sh
for envfile in "$PROJECT_ROOT"/config/locations/*.env; do
  node="$(basename "$envfile" .env)"
  ./scripts/render-config.sh "$node"
done

cat <<EOF
Location $loc is configured.

Next steps:
1. Copy the repository to $public_ip.
2. On the new node, run: sudo ./scripts/apply-wireguard.sh $loc
3. On the primary, reload WireGuard: sudo wg syncconf wg-pdns <(wg-quick strip /etc/wireguard/wg-pdns.conf)
4. On the primary, re-apply firewall: sudo ./scripts/install-nftables.sh eu-ams
5. On the new node, start services: ./scripts/node-compose.sh $loc up -d --build
6. Check replication: ./scripts/sync-zones.sh --check
EOF

```

### `scripts/deploy-cluster.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_env
need rsync

make_ssh_array() {
  SSH_ARR=()
  if [[ -n "${SSH_PASSWORD:-}" ]]; then
    command -v sshpass >/dev/null 2>&1 || fatal "SSH_PASSWORD is set but sshpass is not installed"
    SSH_ARR+=(sshpass -p "$SSH_PASSWORD")
  fi
  SSH_ARR+=(ssh -o StrictHostKeyChecking=accept-new -p "${SSH_PORT:-22}")
  if [[ -n "${SSH_KEY:-}" ]]; then
    SSH_ARR+=(-i "$SSH_KEY")
  fi
}

remote_path="${REMOTE_PROJECT_PATH:-/opt/powerdns-geo-cluster}"
locations=(eu-ams us-nyc as-teh)

cat <<MSG
This deploys generated files to nodes and starts services in order.
It assumes Docker, Compose plugin, WireGuard, nftables, awscli, gpg, curl, dig, and rsync are installed on each node.
MSG

for loc in "${locations[@]}"; do
  load_env "$loc"
  read -r -p "Deploy $loc at $PUBLIC_DNS_IP? [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]] || continue
  remote="${SSH_USER:-root}@$PUBLIC_DNS_IP"
  make_ssh_array
  ssh_cmd_string="${SSH_ARR[*]}"

  log "creating remote path $remote:$remote_path"
  "${SSH_ARR[@]}" "$remote" "mkdir -p '$remote_path'"

  log "copying project to $remote:$remote_path"
  rsync -az --delete -e "$ssh_cmd_string" \
    --exclude 'data/postgres/*' --exclude 'run/*' --exclude 'logs/*' \
    "$PROJECT_ROOT/" "$remote:$remote_path/"

  log "starting WireGuard on $loc"
  "${SSH_ARR[@]}" "$remote" "cd '$remote_path' && sudo ./scripts/apply-wireguard.sh '$loc'"

  if [[ "${INSTALL_FIREWALL_DURING_DEPLOY:-false}" == "true" ]]; then
    log "applying nftables on $loc"
    "${SSH_ARR[@]}" "$remote" "cd '$remote_path' && sudo ./scripts/install-nftables.sh '$loc'"
  else
    echo "Firewall not applied automatically. Run after SSH access is verified: sudo ./scripts/install-nftables.sh $loc"
  fi

  log "starting containers on $loc"
  "${SSH_ARR[@]}" "$remote" "cd '$remote_path' && ./scripts/node-compose.sh '$loc' up -d --build"
done

log "deployment pass complete. Run ./scripts/healthcheck.sh on every node."

```

### `scripts/download-geoip.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
loc="${1:-eu-ams}"
load_env "$loc"
[[ -n "${MAXMIND_ACCOUNT_ID:-}" && -n "${MAXMIND_LICENSE_KEY:-}" ]] || fatal "set MAXMIND_ACCOUNT_ID and MAXMIND_LICENSE_KEY in .env"
./scripts/node-compose.sh "$loc" --profile geoip run --rm geoipupdate
ls -lh "$PROJECT_ROOT/data/geoip"

```

### `scripts/generate-postgres-tls.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
need openssl

# Arguments are accepted for backward compatibility but the script now renders
# certificates for every location present in config/locations/*.env.
tls_root="$PROJECT_ROOT/secrets/postgres-tls"
ca_dir="$tls_root/ca"
mkdir -p "$ca_dir"
chmod 700 "$tls_root" "$ca_dir"

if [[ ! -f "$ca_dir/ca.key" ]]; then
  openssl genrsa -out "$ca_dir/ca.key" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes -key "$ca_dir/ca.key" -sha256 -days 3650 \
    -subj "/CN=powerdns-geo-postgres-ca" -out "$ca_dir/ca.crt" >/dev/null 2>&1
  chmod 600 "$ca_dir/ca.key"
fi

for envfile in "$PROJECT_ROOT"/config/locations/*.env; do
  [[ -f "$envfile" ]] || continue
  node="$(basename "$envfile" .env)"
  set -a
  # shellcheck disable=SC1090
  source "$envfile"
  set +a
  mkdir -p "$tls_root/$node"
  chmod 700 "$tls_root/$node"
  cat > "$tls_root/$node/server.cnf" <<CNF
[req]
default_bits = 4096
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
CN = postgres-$node

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = postgres
DNS.2 = postgres-$node
DNS.3 = pdns-postgres-$node
IP.1 = $PUBLIC_DNS_IP
IP.2 = $WG_IPV4
IP.3 = 127.0.0.1
CNF
  openssl genrsa -out "$tls_root/$node/server.key" 4096 >/dev/null 2>&1
  openssl req -new -key "$tls_root/$node/server.key" -out "$tls_root/$node/server.csr" -config "$tls_root/$node/server.cnf" >/dev/null 2>&1
  openssl x509 -req -in "$tls_root/$node/server.csr" -CA "$ca_dir/ca.crt" -CAkey "$ca_dir/ca.key" -CAcreateserial \
    -out "$tls_root/$node/server.crt" -days 825 -sha256 -extensions req_ext -extfile "$tls_root/$node/server.cnf" >/dev/null 2>&1
  cp "$ca_dir/ca.crt" "$tls_root/$node/ca.crt"
  chmod 600 "$tls_root/$node/server.key"
  chmod 644 "$tls_root/$node/server.crt" "$tls_root/$node/ca.crt"
done
log "generated PostgreSQL TLS CA and per-node server certificates"

```

### `scripts/generate-wireguard-configs.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_env
need wg
mkdir -p "$PROJECT_ROOT/config/generated"

mapfile -t locs < <(ls "$PROJECT_ROOT/config/locations"/*.env 2>/dev/null | xargs -n1 basename | sed 's/\.env$//')
[[ ${#locs[@]} -gt 0 ]] || fatal "no location env files found"

for loc in "${locs[@]}"; do
  load_env "$loc"
  out="$PROJECT_ROOT/config/generated/$loc/wireguard"
  mkdir -p "$out"
  umask 077
  {
    echo "[Interface]"
    echo "Address = ${WG_IPV4_CIDR}"
    echo "ListenPort = ${WG_PORT}"
    echo "PrivateKey = ${WG_PRIVATE_KEY}"
    echo "MTU = ${WIREGUARD_MTU:-1420}"
    echo ""
    for peer in "${locs[@]}"; do
      [[ "$peer" == "$loc" ]] && continue
      set -a; source "$PROJECT_ROOT/config/locations/$peer.env"; set +a
      peer_pub="$WG_PUBLIC_KEY"
      peer_wg="$WG_IPV4"
      peer_public="$PUBLIC_DNS_IP"
      peer_port="$WG_PORT"
      echo "[Peer]"
      echo "PublicKey = $peer_pub"
      echo "AllowedIPs = $peer_wg/32"
      echo "Endpoint = $peer_public:$peer_port"
      echo "PersistentKeepalive = ${WIREGUARD_PERSISTENT_KEEPALIVE:-25}"
      echo ""
    done
  } > "$out/wg-pdns.conf"
done
log "generated WireGuard configs under config/generated/*/wireguard/wg-pdns.conf"

```

### `scripts/healthcheck.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
loc="${1:-${LOCATION_NAME:-eu-ams}}"
load_env "$loc"
need docker
need curl
need dig

fail=0
check() { echo "== $*"; "$@" || fail=1; }
check docker ps --format 'table {{.Names}}\t{{.Status}}'
check curl -fsS -H "X-API-Key: $PDNS_API_KEY" "http://${PDNS_API_BIND}:${PDNS_API_PORT}/api/v1/servers/localhost"
check docker exec "pdns-postgres-$LOCATION_NAME" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" -h 127.0.0.1
check dig "@${PUBLIC_DNS_IP}" example-geo.test SOA +time=2 +tries=1
./scripts/sync-zones.sh --check || fail=1
exit "$fail"

```

### `scripts/install-nftables.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
require_root_for_firewall
loc="${1:-}"
[[ -n "$loc" ]] || fatal "usage: $0 LOCATION"
load_env "$loc"
need nft

peer_public_cidrs="127.0.0.1/32"
if [[ -f "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs" ]]; then
  peer_public_cidrs="$(cat "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs")"
fi

mgmt_set="$(csv_to_nft_set "${MGMT_ALLOWED_CIDRS:-127.0.0.1/32}")"
peer_set="$(csv_to_nft_set "$peer_public_cidrs")"

rendered="/etc/nftables.d/pdns-geo.nft"
mkdir -p /etc/nftables.d
sed \
  -e "s|__MGMT_ALLOWED_CIDRS__|$mgmt_set|g" \
  -e "s|__PEER_PUBLIC_CIDRS__|$peer_set|g" \
  -e "s|__WIREGUARD_NETWORK__|${WIREGUARD_NETWORK_CIDR}|g" \
  -e "s|__PUBLIC_DNS_IP__|${PUBLIC_DNS_IP}|g" \
  -e "s|__WG_IPV4__|${WG_IPV4}|g" \
  -e "s|__SSH_PORT__|${SSH_PORT:-22}|g" \
  -e "s|__WIREGUARD_PORT__|${WG_PORT:-51820}|g" \
  "$PROJECT_ROOT/scripts/nftables/pdns-geo.nft" > "$rendered"

nft -c -f "$rendered"
nft -f "$rendered"
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
include "$rendered"
EOF
systemctl enable nftables >/dev/null 2>&1 || true
log "nftables rules applied from $rendered"

```

### `scripts/lib.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fatal "required command not found: $1"; }

load_env() {
  local loc="${1:-}"
  [[ -f "$PROJECT_ROOT/.env" ]] || fatal ".env not found. Copy env.example to .env or run scripts/setup-cluster.sh"
  set -a
  # shellcheck disable=SC1091
  source "$PROJECT_ROOT/.env"
  if [[ -n "$loc" ]]; then
    [[ -f "$PROJECT_ROOT/config/locations/$loc.env" ]] || fatal "missing config/locations/$loc.env"
    # shellcheck disable=SC1091
    source "$PROJECT_ROOT/config/locations/$loc.env"
  fi
  set +a
}

csv_to_nft_set() {
  local value="$1"
  value="${value// /}"
  [[ -n "$value" ]] || { printf '127.0.0.1/32'; return; }
  printf '%s' "$value" | sed 's/,/, /g'
}

random_secret() {
  openssl rand -base64 32 | tr -d '\n'
}

require_root_for_firewall() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fatal "this command must run as root"
}

```

### `scripts/nftables/pdns-geo.nft`

```text
#!/usr/sbin/nft -f
flush ruleset

define mgmt_cidrs = { __MGMT_ALLOWED_CIDRS__ }
define peer_public_cidrs = { __PEER_PUBLIC_CIDRS__ }
define wg_cidr = __WIREGUARD_NETWORK__
define public_dns_ip = __PUBLIC_DNS_IP__
define wg_ip = __WG_IPV4__
define ssh_port = __SSH_PORT__
define wg_port = __WIREGUARD_PORT__

table inet pdns_geo {
  set dns_rate_sources {
    type ipv4_addr
    flags timeout
    timeout 1m
  }

  chain input {
    type filter hook input priority 0; policy drop;

    iif lo accept
    ct state established,related accept
    ct state invalid drop

    ip protocol icmp accept
    ip6 nexthdr ipv6-icmp accept

    tcp dport $ssh_port ip saddr $mgmt_cidrs accept

    udp dport $wg_port ip daddr $public_dns_ip accept

    # Public authoritative DNS. Lightweight rate limits mitigate accidental floods only.
    udp dport 53 ip daddr $public_dns_ip limit rate over 2500/second burst 5000 packets add @dns_rate_sources { ip saddr timeout 1m } drop
    udp dport 53 ip daddr $public_dns_ip accept
    tcp dport 53 ip daddr $public_dns_ip ct state new limit rate 500/second burst 1000 packets accept
    tcp dport 53 ip daddr $public_dns_ip accept

    # PowerDNS API: management/WireGuard only. Docker also binds to localhost by default.
    tcp dport 8081 ip saddr $mgmt_cidrs accept
    tcp dport 8081 ip saddr $wg_cidr accept

    # PostgreSQL replication: WireGuard normal path plus explicit public fallback from cluster peers only.
    tcp dport 5432 ip saddr $wg_cidr accept
    tcp dport 5432 ip saddr $peer_public_cidrs accept

    counter log prefix "pdns_geo_drop " flags all drop
  }

  chain forward {
    type filter hook forward priority 0; policy drop;
    ct state established,related accept
    iifname "docker0" accept
    oifname "docker0" accept
    iifname "br-*" accept
    oifname "br-*" accept
    counter log prefix "pdns_geo_forward_drop " flags all drop
  }

  chain output {
    type filter hook output priority 0; policy accept;
  }
}

```

### `scripts/node-compose.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# -ge 2 ]] || { echo "usage: $0 LOCATION compose-args..." >&2; exit 2; }
LOC="$1"; shift
[[ -f "$ROOT/.env" ]] || { echo ".env missing" >&2; exit 1; }
[[ -f "$ROOT/config/locations/$LOC.env" ]] || { echo "config/locations/$LOC.env missing" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
# shellcheck disable=SC1091
source "$ROOT/config/locations/$LOC.env"
set +a
cd "$ROOT"
exec docker compose -f docker-compose.yml -f "docker-compose.$LOC.yml" "$@"

```

### `scripts/push-node.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
loc="${1:-}"
[[ -n "$loc" ]] || fatal "usage: $0 LOCATION"
load_env "$loc"
need rsync
remote_user="${SSH_USER:-root}"
remote_port="${SSH_PORT:-22}"
remote_host="$PUBLIC_DNS_IP"
remote_path="/opt/powerdns-geo-cluster"
ssh_cmd="ssh -p $remote_port"
if [[ -n "${SSH_KEY:-}" ]]; then ssh_cmd="ssh -i $SSH_KEY -p $remote_port"; fi
rsync -az --delete -e "$ssh_cmd" \
  --exclude 'data/postgres/*' --exclude 'run/*' --exclude 'logs/*' \
  "$PROJECT_ROOT/" "$remote_user@$remote_host:$remote_path/"
log "pushed repository to $remote_user@$remote_host:$remote_path"

```

### `scripts/render-config.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

loc="${1:-${LOCATION_NAME:-}}"
[[ -n "$loc" ]] || fatal "usage: $0 LOCATION"
load_env "$loc"

out="$PROJECT_ROOT/config/generated/$loc"
mkdir -p "$out/pdns" "$out/db" "$out/wireguard"

peer_public_cidrs=""
if [[ -f "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs" ]]; then
  peer_public_cidrs="$(cat "$PROJECT_ROOT/config/generated/cluster-peer-public-cidrs")"
fi
: "${peer_public_cidrs:=127.0.0.1/32}"

public_hba=""
if [[ "${POSTGRES_PUBLIC_FALLBACK_ENABLED:-true}" == "true" ]]; then
  IFS=',' read -ra peers <<< "$peer_public_cidrs"
  for cidr in "${peers[@]}"; do
    cidr="${cidr// /}"
    [[ -n "$cidr" ]] || continue
    public_hba+="hostssl replication ${POSTGRES_REPLICATION_USER} ${cidr} scram-sha-256"$'\n'
  done
fi

mgmt_hba="$(csv_to_nft_set "${MGMT_ALLOWED_CIDRS:-127.0.0.1/32}")"
# pg_hba does not accept nft set syntax. Use only the first management CIDR for DB admin by default.
mgmt_first="${MGMT_ALLOWED_CIDRS%%,*}"
mgmt_first="${mgmt_first// /}"
: "${mgmt_first:=127.0.0.1/32}"

sed \
  -e "s|__POSTGRES_DB__|${POSTGRES_DB}|g" \
  -e "s|__POSTGRES_USER__|${POSTGRES_USER}|g" \
  -e "s|__POSTGRES_PASSWORD__|${POSTGRES_PASSWORD}|g" \
  -e "s|__PDNS_API_KEY__|${PDNS_API_KEY}|g" \
  -e "s|__PDNS_WEBSERVER_PASSWORD__|${PDNS_WEBSERVER_PASSWORD}|g" \
  -e "s|__MGMT_ALLOWED_CIDRS__|${MGMT_ALLOWED_CIDRS}|g" \
  -e "s|__WIREGUARD_NETWORK__|${WIREGUARD_NETWORK_CIDR}|g" \
  -e "s|__PDNS_LOGLEVEL__|${PDNS_LOGLEVEL:-4}|g" \
  "$PROJECT_ROOT/config/pdns/pdns.conf.template" > "$out/pdns/pdns.conf"

sed \
  -e "s|__POSTGRES_WAL_KEEP_SIZE__|${POSTGRES_WAL_KEEP_SIZE:-2048MB}|g" \
  -e "s|__POSTGRES_MAX_SLOT_WAL_KEEP_SIZE__|${POSTGRES_MAX_SLOT_WAL_KEEP_SIZE:-10240MB}|g" \
  "$PROJECT_ROOT/config/db/postgresql.conf.template" > "$out/db/postgresql.conf"

sed \
  -e "s|__DOCKER_DNS_SUBNET__|${DOCKER_DNS_SUBNET}|g" \
  -e "s|__REPL_USER__|${POSTGRES_REPLICATION_USER}|g" \
  -e "s|__WIREGUARD_NETWORK__|${WIREGUARD_NETWORK_CIDR}|g" \
  -e "s|__PUBLIC_REPLICATION_HBA__|${public_hba//$'\n'/\\n}|g" \
  -e "s|__MGMT_ALLOWED_CIDRS__|${mgmt_first}|g" \
  "$PROJECT_ROOT/config/db/pg_hba.conf.template" | sed 's/\\n/\
/g' > "$out/db/pg_hba.conf"

chmod 600 "$out/db/pg_hba.conf" "$out/pdns/pdns.conf"
log "rendered config for $loc in $out"

```

### `scripts/restore.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
uri="${1:-}"
[[ -n "$uri" ]] || fatal "usage: $0 s3://bucket/prefix/file.sql.gz.gpg"
loc="${LOCATION_NAME:-eu-ams}"
load_env "$loc"
[[ "$LOCATION_ROLE" == "primary" ]] || fatal "restore must be run on the primary"
need aws
need gpg
need gunzip
need docker
[[ -f "$BACKUP_GPG_PASSPHRASE_FILE" ]] || fatal "missing backup passphrase file"

work="$PROJECT_ROOT/run/restore/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$work"
enc="$work/backup.sql.gz.gpg"
gz="$work/backup.sql.gz"
sql="$work/backup.sql"

aws_args=(s3 cp "$uri" "$enc" --region "$S3_REGION")
[[ -n "${S3_ENDPOINT_URL:-}" ]] && aws_args+=(--endpoint-url "$S3_ENDPOINT_URL")
aws "${aws_args[@]}"

gpg --batch --yes --pinentry-mode loopback --passphrase-file "$BACKUP_GPG_PASSPHRASE_FILE" -o "$gz" -d "$enc"
gunzip -c "$gz" > "$sql"

echo "This will replace PowerDNS records in PostgreSQL on $LOCATION_NAME. Type RESTORE to continue:"
read -r confirm
[[ "$confirm" == "RESTORE" ]] || fatal "restore cancelled"

./scripts/node-compose.sh "$LOCATION_NAME" stop pdns
cat "$sql" | docker exec -i "pdns-postgres-$LOCATION_NAME" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1
./scripts/node-compose.sh "$LOCATION_NAME" start pdns
log "restore complete. Reinitialize standbys if replication diverged: scripts/sync-zones.sh --reinit-standby"

```

### `scripts/setup-cluster.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

need openssl
need sed
need awk
need wg

cd "$PROJECT_ROOT"
mkdir -p config/locations config/generated secrets/wireguard secrets/postgres-tls data/geoip logs run/backups/tmp
[[ -f .env ]] || cp env.example .env

ask() {
  local prompt="$1" default="${2:-}" secret="${3:-false}" value
  if [[ "$secret" == "true" ]]; then
    read -r -s -p "$prompt${default:+ [$default]}: " value; echo >&2
  else
    read -r -p "$prompt${default:+ [$default]}: " value
  fi
  printf '%s' "${value:-$default}"
}

replace_env() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" .env; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

log "Interactive first-machine cluster setup"
cluster_name="$(ask 'Cluster name' 'powerdns-geo-cluster')"
mgmt_cidrs="$(ask 'Management CIDRs allowed for SSH/API, comma-separated' 'CHANGE_ME_ADMIN_PUBLIC_IP_OR_CIDR')"
ssh_user_default="$(ask 'Default SSH user for nodes' 'root')"
ssh_port_default="$(ask 'Default SSH port for nodes' '22')"
ssh_key_default="$(ask 'SSH private key path for deployment, blank for default agent/password' '')"
ssh_password_default=""
if [[ -z "$ssh_key_default" ]]; then
  ssh_password_default="$(ask 'SSH password for temporary bootstrap, blank to use SSH agent only' '' true)"
fi
wg_port="$(ask 'WireGuard UDP port' '51820')"
wg_cidr="$(ask 'WireGuard CIDR' '10.90.0.0/24')"

pdns_key="$(random_secret)"
pdns_web_pw="$(random_secret)"
pg_pw="$(random_secret)"
repl_pw="$(random_secret)"
backup_pass="$(random_secret)"
mkdir -p secrets
printf '%s\n' "$backup_pass" > secrets/backup-gpg-passphrase
chmod 600 secrets/backup-gpg-passphrase

replace_env COMPOSE_PROJECT_NAME "$cluster_name"
replace_env PDNS_API_KEY "$pdns_key"
replace_env PDNS_WEBSERVER_PASSWORD "$pdns_web_pw"
replace_env POSTGRES_PASSWORD "$pg_pw"
replace_env POSTGRES_REPLICATION_PASSWORD "$repl_pw"
replace_env MGMT_ALLOWED_CIDRS "$mgmt_cidrs"
replace_env SSH_USER "$ssh_user_default"
replace_env SSH_PORT "$ssh_port_default"
replace_env SSH_KEY "$ssh_key_default"
replace_env SSH_PASSWORD "$ssh_password_default"
replace_env WIREGUARD_PORT "$wg_port"
replace_env WIREGUARD_NETWORK_CIDR "$wg_cidr"
replace_env BACKUP_GPG_PASSPHRASE_FILE './secrets/backup-gpg-passphrase'

maxmind_account="$(ask 'MaxMind account ID, blank to skip GeoLite2 download' '')"
maxmind_key=""
if [[ -n "$maxmind_account" ]]; then
  maxmind_key="$(ask 'MaxMind license key' '' true)"
fi
replace_env MAXMIND_ACCOUNT_ID "$maxmind_account"
replace_env MAXMIND_LICENSE_KEY "$maxmind_key"

s3_bucket="$(ask 'S3 bucket for encrypted backups' 'CHANGE_ME_BUCKET_NAME')"
s3_prefix="$(ask 'S3 prefix' 'powerdns-geo-cluster')"
s3_region="$(ask 'S3 region' 'eu-west-1')"
s3_sse="$(ask 'S3 SSE mode: aws:kms or AES256' 'aws:kms')"
s3_kms=""
if [[ "$s3_sse" == "aws:kms" ]]; then
  s3_kms="$(ask 'S3 KMS key ID or alias' 'CHANGE_ME_KMS_KEY_ID_OR_ALIAS')"
fi
replace_env S3_BUCKET "$s3_bucket"
replace_env S3_PREFIX "$s3_prefix"
replace_env S3_REGION "$s3_region"
replace_env S3_SSE_MODE "$s3_sse"
replace_env S3_KMS_KEY_ID "$s3_kms"

nodes=(eu-ams us-nyc as-teh)
roles=(primary standby standby)
regions=(EU NA AS)
cities=(Amsterdam "New York" Tehran)
wgips=(10.90.0.10 10.90.0.20 10.90.0.30)

node_publics=()
node_wgpubs=()
node_sshusers=()
node_sshports=()

for i in "${!nodes[@]}"; do
  loc="${nodes[$i]}"
  role="${roles[$i]}"
  region="${regions[$i]}"
  city="${cities[$i]}"
  pub="$(ask "Public DNS IP for $loc" "CHANGE_ME_${loc^^}_PUBLIC_IP")"
  wgip="$(ask "WireGuard IP for $loc" "${wgips[$i]}")"
  wgips[$i]="$wgip"
  ssh_user="$(ask "SSH user for $loc" "$ssh_user_default")"
  ssh_port="$(ask "SSH port for $loc" "$ssh_port_default")"

  priv="$(wg genkey)"
  pubkey="$(printf '%s' "$priv" | wg pubkey)"
  printf '%s\n' "$priv" > "secrets/wireguard/$loc.private"
  printf '%s\n' "$pubkey" > "secrets/wireguard/$loc.public"
  chmod 600 "secrets/wireguard/$loc.private"

  slot=""
  phosts=""
  if [[ "$role" == "standby" ]]; then
    slot="eu_ams_${loc//-/_}"
    phosts="${wgips[0]},${node_publics[0]}"
  fi

  cat > "config/locations/$loc.env" <<EOF
LOCATION_NAME=$loc
LOCATION_ROLE=$role
REGION_CODE=$region
LOCATION_CITY="$city"
PUBLIC_DNS_IP=$pub
WG_IPV4=$wgip
WG_IPV4_CIDR=$wgip/24
WG_PORT=$wg_port
WG_PRIVATE_KEY=$priv
WG_PUBLIC_KEY=$pubkey
POSTGRES_PRIMARY_HOSTS=$phosts
POSTGRES_PRIMARY_PORTS=5432,5432
REPLICATION_SLOT_NAME=$slot
DOCKER_DNS_SUBNET=172.30.$((10 + i*10)).0/24
EOF

  node_publics+=("$pub")
  node_wgpubs+=("$pubkey")
  node_sshusers+=("$ssh_user")
  node_sshports+=("$ssh_port")
done

peer_cidrs=""
for pub in "${node_publics[@]}"; do
  [[ -n "$peer_cidrs" ]] && peer_cidrs+=","
  peer_cidrs+="$pub/32"
done
printf '%s\n' "$peer_cidrs" > config/generated/cluster-peer-public-cidrs

cat > cluster-inventory.yml <<EOF
cluster:
  name: $cluster_name
  primary: eu-ams
  wireguard_network_cidr: $wg_cidr
  wireguard_port: $wg_port
  postgres_public_fallback_enabled: true
  backup_target: s3
nodes:
EOF
for i in "${!nodes[@]}"; do
  cat >> cluster-inventory.yml <<EOF
  - name: ${nodes[$i]}
    role: ${roles[$i]}
    region_code: ${regions[$i]}
    city: ${cities[$i]}
    public_dns_ip: ${node_publics[$i]}
    wireguard_ip: ${wgips[$i]}
    ssh_user: ${node_sshusers[$i]}
    ssh_port: ${node_sshports[$i]}
EOF
done

./scripts/generate-wireguard-configs.sh
./scripts/generate-postgres-tls.sh eu-ams "${node_publics[0]}" "${wgips[0]}"
for loc in "${nodes[@]}"; do
  ./scripts/render-config.sh "$loc"
done

log "Cluster files generated. Next steps:"
echo "1. Copy this directory to each node, including secrets/. Protect it as root-only."
echo "2. On each node: sudo ./scripts/apply-wireguard.sh LOCATION"
echo "3. Start primary first: ./scripts/node-compose.sh eu-ams up -d --build"
echo "4. Start standbys: ./scripts/node-compose.sh us-nyc up -d --build and ./scripts/node-compose.sh as-teh up -d --build"
echo "5. Enable nftables after confirming SSH management CIDRs: sudo ./scripts/install-nftables.sh LOCATION"

```

### `scripts/sync-zones.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
mode="${1:---check}"
loc="${LOCATION_NAME:-}"
if [[ -z "$loc" ]]; then
  for f in "$PROJECT_ROOT/config/locations"/*.env; do loc="$(basename "$f" .env)"; break; done
fi
load_env "$loc"

cid="pdns-postgres-$LOCATION_NAME"
case "$mode" in
  --check)
    if [[ "$LOCATION_ROLE" == "primary" ]]; then
      docker exec "$cid" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
        "select application_name, client_addr, state, sync_state, sent_lsn, replay_lsn from pg_stat_replication order by application_name;"
    else
      docker exec "$cid" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -c \
        "select pg_is_in_recovery() as standby, status, sender_host, sender_port, latest_end_lsn, now() - pg_last_xact_replay_timestamp() as replay_lag from pg_stat_wal_receiver;"
    fi
    ;;
  --reinit-standby)
    [[ "$LOCATION_ROLE" == "standby" ]] || fatal "--reinit-standby must be run on a standby"
    ./scripts/node-compose.sh "$LOCATION_NAME" down
    rm -rf "$PROJECT_ROOT/data/postgres/$LOCATION_NAME"
    ./scripts/node-compose.sh "$LOCATION_NAME" up -d --build postgres
    ;;
  *) fatal "usage: $0 --check|--reinit-standby" ;;
esac

```

### `tests/test-geo-routing.sh`

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
loc="${1:-eu-ams}"
load_env "$loc"
need dig
name="${2:-www.example-geo.test}"
server="${3:-$PUBLIC_DNS_IP}"

declare -A tests=(
  [EU]="80.101.1.1/32:203.0.113.10"
  [NA]="8.8.8.8/32:198.51.100.10"
  [AS]="202.12.27.33/32:192.0.2.10"
)

fail=0
for region in "${!tests[@]}"; do
  subnet="${tests[$region]%%:*}"
  expected="${tests[$region]##*:}"
  got="$(dig "@$server" "$name" A +short +subnet="$subnet" +time=2 +tries=1 | tail -n1)"
  printf '%s ECS %s -> %s expected %s\n' "$region" "$subnet" "${got:-NO_ANSWER}" "$expected"
  [[ "$got" == "$expected" ]] || fail=1
done
exit "$fail"

```

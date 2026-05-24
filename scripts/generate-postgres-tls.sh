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

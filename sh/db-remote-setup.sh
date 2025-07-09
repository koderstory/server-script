#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<EOF
Usage: $0 <listen_ip> [client_cidr] [port]

  listen_ip    IP address PostgreSQL should bind to (e.g. 10.0.0.5)
  client_cidr  CIDR or IP/netmask allowed to connect (default: listen_ip/32)
  port         TCP port (default: 5432)

Requires:
  - Debian/Ubuntu-style layout under /etc/postgresql/<version>/main/
  - root privileges (or use sudo)

Example:
  # Only allow 10.0.0.5 to connect, server listens on 10.0.0.5:
  $0 10.0.0.5

  # Allow entire 10.0.0.0/24 to connect, server listens on 10.0.0.5:
  $0 10.0.0.5 10.0.0.0/24

  # Custom port 55432:
  $0 10.0.0.5 10.0.0.0/24 55432
EOF
  exit 1
}

if [[ $# -lt 1 || $# -gt 3 ]]; then
  usage
fi

LISTEN_IP="$1"
CLIENT_CIDR="${2:-${LISTEN_IP}/32}"
PORT="${3:-5432}"

# Locate the PG conf directory
# Allow override via PG_CONF_DIR env; else auto-detect one version under /etc/postgresql
PG_CONF_DIR="${PG_CONF_DIR:-}"
if [[ -z "$PG_CONF_DIR" ]]; then
  # find first directory under /etc/postgresql/*/main
  PG_CONF_DIR=$(find /etc/postgresql -maxdepth 2 -type d -path "*/main" | head -n1)
  if [[ -z "$PG_CONF_DIR" ]]; then
    echo "❌ Could not find /etc/postgresql/<version>/main/ on this system."
    exit 1
  fi
fi

PG_CONF="${PG_CONF_DIR}/postgresql.conf"
PG_HBA="${PG_CONF_DIR}/pg_hba.conf"

echo "⚙️  Config directory: $PG_CONF_DIR"
echo "📝 Backing up configs..."
cp -v "$PG_CONF" "${PG_CONF}.bak"
cp -v "$PG_HBA" "${PG_HBA}.bak"

echo "🔧 Setting listen_addresses to '$LISTEN_IP' and port to '$PORT' in postgresql.conf..."
# uncomment/set listen_addresses
if grep -Eq '^\s*#?\s*listen_addresses' "$PG_CONF"; then
  sed -ri "s|^\s*#?\s*listen_addresses\s*=.*|listen_addresses = '${LISTEN_IP}'|" "$PG_CONF"
else
  echo "listen_addresses = '${LISTEN_IP}'" >>"$PG_CONF"
fi
# uncomment/set port
if grep -Eq '^\s*#?\s*port' "$PG_CONF"; then
  sed -ri "s|^\s*#?\s*port\s*=.*|port = ${PORT}|" "$PG_CONF"
else
  echo "port = ${PORT}" >>"$PG_CONF"
fi

echo "➕ Adding pg_hba rule to allow $CLIENT_CIDR..."
# check if already present
if grep -Fq "$CLIENT_CIDR" "$PG_HBA"; then
  echo "   ↳ Entry for $CLIENT_CIDR already exists in pg_hba.conf, skipping."
else
  cat <<EOF >>"$PG_HBA"

# Allow connections from $CLIENT_CIDR on port $PORT
host    all             all             $CLIENT_CIDR           md5
EOF
fi

echo "🚀 Reloading PostgreSQL..."
if command -v systemctl >/dev/null; then
  systemctl reload postgresql
else
  service postgresql reload
fi

echo "✅ Done! PostgreSQL now listens on ${LISTEN_IP}:${PORT} and accepts $CLIENT_CIDR."

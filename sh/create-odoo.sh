#!/usr/bin/env bash
# setup.sh — run as root
# Usage: ./setup.sh <domain> <user>

set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <domain> <user>" >&2
  exit 1
fi

DOMAIN_RAW="$1"
DEV_USER_RAW="$2"

# --- helpers ---
to_key() {
  # lowercase and strip non [a-z0-9]
  local s
  s="$(echo -n "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]//g')"
  printf "%s" "$s"
}

gen_passphrase() {
  # 10-char random token from [A-Za-z0-9#!%]
  # Works under `set -euo pipefail` (ignore SIGPIPE from head).
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 \
      | LC_ALL=C tr -dc 'A-Za-z0-9#!%' \
      | head -c 16 || true
  else
    LC_ALL=C tr -dc 'A-Za-z0-9#!%' </dev/urandom \
      | head -c 16 || true
  fi
  echo
}

rand_suffix() {
  if command -v hexdump >/dev/null 2>&1; then
    hexdump -n 4 -v -e '/1 "%02x"' /dev/urandom
  else
    # fallback if hexdump isn't available
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
  fi
}


# --- normalize inputs ---
DOMAIN="$(to_key "$DOMAIN_RAW")"                   # example.com -> examplecom
DEV_USER="$(echo -n "$DEV_USER_RAW" | tr '[:upper:]' '[:lower:]')"


SUFFIX="$(rand_suffix)"

DB_USER="u_${DOMAIN}_${SUFFIX}"                    # u_examplecom_x1y2z3
DB_NAME="db_${DOMAIN}_${SUFFIX}"                   # db_examplecom_x1y2z3
DB_PASS="$(gen_passphrase)"

# --- sanity checks ---
[[ -x ./setup-server.sh ]] || { echo "Error: ./setup-server.sh not found or not executable in $(pwd)"; exit 1; }
[[ -x ./db_add.sh       ]] || { echo "Error: ./db_add.sh not found or not executable at ./db_add.sh"; exit 1; }

( ./setup-server.sh )

# --- create unix user if needed ---
if id -u "$DEV_USER" >/dev/null 2>&1; then
  echo "==> User '${DEV_USER}' already exists; skipping adduser"
else
  echo "==> Creating user '${DEV_USER}' (disabled password, empty GECOS)"
  adduser --gecos "" --disabled-password "$DEV_USER"
fi


# --- run setup-server.sh "as if" we were the dev user (no user switch) ---
export USER="$DEV_USER"
export LOGNAME="$DEV_USER"
export HOME="/home/${DEV_USER}"
export SHELL="/bin/bash"
umask 022

if [[ ! -d "$HOME" ]]; then
  echo "Warning: HOME directory '$HOME' does not exist; creating."
  mkdir -p "$HOME"
  chown "${DEV_USER}:${DEV_USER}" "$HOME" || true
fi

# --- configure database via ./db_add.sh ---
echo "==> Configuring database via ./db_add.sh"
# ./db_add.sh expects: ./db_add.sh user_domain_com db_domain_com 16word-random-pass
./db_add.sh "${DB_USER}" "${DB_NAME}" "${DB_PASS}"

# --- output summary (password shown) ---
cat <<EOF

✅ Done.

Summary:
- Unix user:     ${DEV_USER} (created if missing)
- Ran:           $( [[ -n "${ODOO_FOUND}" ]] && echo "skipped setup-server.sh (Odoo 18 present)" || echo "setup-server.sh (with USER=${DEV_USER}, HOME=/home/${DEV_USER})" )
- DB user:       ${DB_USER}
- DB name:       ${DB_NAME}
- DB password:   ${DB_PASS}

Store the password securely (e.g., a secret manager).
EOF

# Optional: support a hidden flag to print just the password if invoked that way
if [[ "${3:-}" == "--print-pass" ]]; then
  echo "$DB_PASS"
fi

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
to_id() {
  # lowercase, replace non-alnum with underscores, collapse repeats, trim underscores
  local s
  s="$(echo -n "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/_+/_/g; s/^_+|_+$//g')"
  printf "%s" "$s"
}

gen_passphrase() {
  # Prefer a 16-word passphrase from system dictionary; fallback to urandom
  if command -v shuf >/dev/null 2>&1 && [[ -r /usr/share/dict/words ]]; then
    # restrict to simple lowercase words to avoid punctuation/uppercase
    tr '[:upper:]' '[:lower:]' </usr/share/dict/words \
      | grep -E '^[a-z]{3,10}$' \
      | shuf -n 16 \
      | paste -sd'-' -
  else
    # fallback: 48 random bytes base64, chunked into 16 "words"
    head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' \
      | fold -w6 | head -n16 | paste -sd'-' -
  fi
}

# Execute in current working directory with the faked environment
( ./server.sh )


# --- normalize inputs ---
DOMAIN="$(to_id "$DOMAIN_RAW")"
DEV_USER="$(to_id "$DEV_USER_RAW")"

DB_USER="${DEV_USER}_${DOMAIN}"   # e.g. newuser_example_com
DB_NAME="db_${DOMAIN}"            # e.g. db_example_com
DB_PASS="$(gen_passphrase)"

# --- sanity checks ---
[[ -x ./server.sh ]] || { echo "Error: ./server.sh not found or not executable in $(pwd)"; exit 1; }
[[ -x ./db_add.sh        ]] || { echo "Error: ./db_add.sh not found or not executable at ./db_add.sh"; exit 1; }

echo "==> Inputs"
echo " Domain:        ${DOMAIN_RAW}  -> ${DOMAIN}"
echo " Dev user:      ${DEV_USER_RAW} -> ${DEV_USER}"
echo " DB user:       ${DB_USER}"
echo " DB name:       ${DB_NAME}"
echo " (password will not be echoed again)"

# --- create unix user if needed ---
if id -u "$DEV_USER" >/dev/null 2>&1; then
  echo "==> User '${DEV_USER}' already exists; skipping adduser"
else
  echo "==> Creating user '${DEV_USER}' (disabled password, empty GECOS)"
  adduser --gecos "" --disabled-password "$DEV_USER"
fi

# --- run server.sh "as if" we were the dev user (no user switch) ---
# We simulate environment variables the script might expect from the dev user.
echo "==> Running ./server.sh with ${DEV_USER}-like environment (no user switch)"
export USER="$DEV_USER"
export LOGNAME="$DEV_USER"
export HOME="/home/${DEV_USER}"
export SHELL="/bin/bash"
umask 022

# If server.sh relies on HOME, ensure it exists
if [[ ! -d "$HOME" ]]; then
  echo "Warning: HOME directory '$HOME' does not exist; creating."
  mkdir -p "$HOME"
  chown "${DEV_USER}:${DEV_USER}" "$HOME" || true
fi

# --- configure database via ./db_add.sh ---
echo "==> Configuring database via ./db_add.sh"
# Note: We do not echo the password.
# ./db_add.sh expects: /db_add.sh user_domain_com db_domain_com 16word-random-pass
./db_add.sh "${DB_USER}" "${DB_NAME}" "${DB_PASS}"

# --- output summary (without password) ---
cat <<EOF

✅ Done.

Summary:
- Unix user:     ${DEV_USER} (created if missing)
- Ran:           ./server.sh (with USER=${DEV_USER}, HOME=/home/${DEV_USER})
- DB user:       ${DB_USER}
- DB name:       ${DB_NAME}
- DB password:   (generated, not displayed)

Tip: store the password securely (e.g., a secret manager). If you need it now, re-run with:
  PASS="\$( $(basename "$0") ${DOMAIN_RAW@Q} ${DEV_USER_RAW@Q} --print-pass )"

EOF

# Optional: support a hidden flag to print just the password if invoked that way
if [[ "${3:-}" == "--print-pass" ]]; then
  echo "$DB_PASS"
fi

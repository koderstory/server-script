#!/usr/bin/env bash
# setup.sh — run as root
# Usage: ./setup.sh [--no-color] <domain> <user>

set -euo pipefail



# ==========================================================================
# arg parsing
# ==========================================================================
NO_COLOR_FLAG=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --no-color) NO_COLOR_FLAG=1 ;;
    *) ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]}"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 [--no-color] <domain> <user>" >&2
  exit 1
fi

DOMAIN_RAW="$1"
DEV_USER_RAW="$2"




# ==========================================================================
# color detection
# ==========================================================================
supports_color() {
  [[ -t 1 ]] || return 1
  command -v tput >/dev/null 2>&1 || return 1
  local n; n=$(tput colors || echo 0)
  [[ "$n" -ge 8 ]] || return 1
  [[ "${NO_COLOR:-}" == "" ]] || return 1
  [[ "$NO_COLOR_FLAG" -eq 0 ]] || return 1
  return 0
}

if supports_color; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"
else
  BOLD=""; DIM=""; RESET=""
  RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

info()  { printf "%s[*]%s %s\n" "$CYAN" "$RESET" "$*"; }
step()  { printf "\n%s==>%s %s%s%s\n" "$BLUE" "$RESET" "$BOLD" "$*" "$RESET"; }
ok()    { printf "%s[✓]%s %s\n" "$GREEN" "$RESET" "$*"; }
warn()  { printf "%s[!]%s %s\n" "$YELLOW" "$RESET" "$*"; }
err()   { printf "%s[x]%s %s\n" "$RED" "$RESET" "$*" >&2; }

trap 'err "Script failed on line $LINENO."' ERR



# ==========================================================================
# guards
# ==========================================================================
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  err "This script must be run as root."
  exit 1
fi




# ==========================================================================
# helpers
# ========================================================================== 
to_key() {
  # lowercase and strip non [a-z0-9]
  local s
  s="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]//g')"
  printf "%s" "$s"
}

gen_passphrase() {
  # 10-char token from [A-Za-z0-9#!%], robust under set -euo pipefail
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 \
      | LC_ALL=C tr -dc 'A-Za-z0-9#!%' \
      | head -c 10 || true
  else
    LC_ALL=C tr -dc 'A-Za-z0-9#!%' </dev/urandom \
      | head -c 10 || true
  fi
  echo
}

rand_suffix() {
  # 8 hex chars; no SIGPIPE issues
  if command -v hexdump >/dev/null 2>&1; then
    hexdump -n 4 -v -e '/1 "%02x"' /dev/urandom
  else
    od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
  fi
}

as_dev() {
  # Run a command as DEV_USER (non-interactive). Prefers sudo to set proper ownership.
  if command -v sudo >/dev/null 2>&1; then
    sudo -u "$DEV_USER" -H bash -lc "$*"
  else
    USER="$DEV_USER" LOGNAME="$DEV_USER" HOME="/home/${DEV_USER}" \
    bash -lc "$*"
  fi
}

kv() { printf "  %-12s : %s\n" "$1" "$2"; }

abs_path() {
  local p="$1"
  if command -v readlink >/dev/null 2>&1; then
    readlink -f "$p" 2>/dev/null || printf "%s" "$p"
  else
    printf "%s" "$p"
  fi
}



# ==========================================================================
# normalize inputs
# ==========================================================================
DOMAIN="$(to_key "$DOMAIN_RAW")"               # example.com -> examplecom
DEV_USER="$(printf "%s" "$DEV_USER_RAW" | tr '[:upper:]' '[:lower:]')"
SUFFIX="$(rand_suffix)"

DB_USER="u_${DOMAIN}_${SUFFIX}"                # u_examplecom_1a2b3c4d
DB_NAME="db_${DOMAIN}_${SUFFIX}"               # db_examplecom_1a2b3c4d
DB_PASS="$(gen_passphrase)"

PROJECT_DIR="${DOMAIN_RAW}"                    # folder name kept as raw domain
REQ_FILE="/opt/odoo/18/ce/requirements.txt"


CONFIG_SCRIPT="$(abs_path ./odoo-config.sh)"
SERVICE_SCRIPT="$(abs_path ./odoo-service.sh)"
NGINX_SCRIPT="$(abs_path ./odoo-nginx.sh)"



# ==========================================================================
# sanity checks
# ==========================================================================
step "Sanity checks"
[[ -x ./setup-server.sh ]] || { err "setup-server.sh not found or not executable in $(pwd)"; exit 1; }
[[ -x ./db_add.sh       ]] || { err "db_add.sh not found or not executable at ./db_add.sh"; exit 1; }
[[ -x "$CONFIG_SCRIPT"  ]] || { err "odoo-config.sh not found or not executable at $CONFIG_SCRIPT"; exit 1; }
[[ -x "$SERVICE_SCRIPT"  ]] || { err "odoo-service.sh not found or not executable at $SERVICE_SCRIPT"; exit 1; }
[[ -x "$NGINX_SCRIPT"  ]] || { err "odoo-nginx.sh not found or not executable at $NGINX_SCRIPT"; exit 1; }

ok "Found ./setup-server.sh"
ok "Found ./db_add.sh"
ok "Found $CONFIG_SCRIPT"
ok "Found $SERVICE_SCRIPT"
ok "Found $NGINX_SCRIPT"


# ==========================================================================
# show inputs
# ==========================================================================
step "Inputs"
kv "Domain (raw)" "$DOMAIN_RAW"
kv "Domain (key)" "$DOMAIN"
kv "Dev user"     "$DEV_USER"
kv "DB user"      "$DB_USER"
kv "DB name"      "$DB_NAME"


# ==========================================================================
# create unix user if needed
# ==========================================================================
step "Ensure Unix user"
if id -u "$DEV_USER" >/dev/null 2>&1; then
  ok "User '${DEV_USER}' already exists"
else
  info "Creating user '${DEV_USER}' (disabled password, empty GECOS)"
  adduser --gecos "" --disabled-password "$DEV_USER"
  ok "Created '${DEV_USER}'"
fi


# ==========================================================================
# run setup-server.sh with dev-like env (no interactive switch)
# ==========================================================================
step "Run setup-server.sh (dev-like env)"
export USER="$DEV_USER"
export LOGNAME="$DEV_USER"
export HOME="/home/${DEV_USER}"
export SHELL="/bin/bash"
umask 022

if [[ ! -d "$HOME" ]]; then
  warn "HOME directory '$HOME' does not exist; creating."
  mkdir -p "$HOME"
  chown "${DEV_USER}:${DEV_USER}" "$HOME" || true
  ok "Created $HOME"
fi

( ./setup-server.sh )
ok "setup-server.sh completed"


# ==========================================================================
# Bootstrap project with Pipenv (non-interactive)
# ==========================================================================
step "Bootstrap project directory and Pipenv env"

info "Create ~/${PROJECT_DIR}"
as_dev "mkdir -p ~/${PROJECT_DIR}"

info "Ensure Pipenv is available for ${DEV_USER}"
as_dev "export PATH=\"\$HOME/.local/bin:\$PATH\"; command -v pipenv >/dev/null 2>&1 || python3 -m pip install --user pipenv"

info "Initialize Pipenv (venv in project: .venv)"
as_dev "cd ~/${PROJECT_DIR} && export PATH=\"\$HOME/.local/bin:\$PATH\"; PIPENV_VENV_IN_PROJECT=1 pipenv --python 3"

info "Upgrade pip inside the Pipenv virtualenv"
as_dev "cd ~/${PROJECT_DIR} && export PATH=\"\$HOME/.local/bin:\$PATH\"; PIPENV_VENV_IN_PROJECT=1 pipenv run python -m pip install --upgrade pip"

info "Install requirements from ${REQ_FILE}"
as_dev "cd ~/${PROJECT_DIR} && export PATH=\"\$HOME/.local/bin:\$PATH\"; PIPENV_VENV_IN_PROJECT=1 pipenv run pip install -r '${REQ_FILE}'"

ok "Python env ready at ~/${PROJECT_DIR}/.venv"


# ==========================================================================
# configure database
# ==========================================================================
step "Configure database"
info "Calling: ./db_add.sh ${DB_USER} ${DB_NAME} **********"
./db_add.sh "${DB_USER}" "${DB_NAME}" "${DB_PASS}"
ok "Database configured"


# ==========================================================================
# generate odoo.conf
# ==========================================================================
step "Generate odoo.conf"
# Run as root (so it executes even if script lives in /root), then fix ownership.
if [[ ! -x "$CONFIG_SCRIPT" ]]; then
  info "Making $CONFIG_SCRIPT executable"
  chmod 0755 "$CONFIG_SCRIPT"
fi
info "Generating config via ${CONFIG_SCRIPT}"
bash "$CONFIG_SCRIPT" "${DEV_USER}" "${PROJECT_DIR}" "${DB_USER}" "${DB_NAME}" "${DB_PASS}"

# Ensure ownership of the project dir
TARGET_DIR="/home/${DEV_USER}/${PROJECT_DIR}"
chown -R "${DEV_USER}:${DEV_USER}" "${TARGET_DIR}" || true
ok "odoo.conf created at ${TARGET_DIR}/odoo.conf"




# ==========================================================================
# initialize Odoo database (non-interactive)
# ==========================================================================
step "Initialize Odoo database (base,web)"
as_dev "cd ~/${PROJECT_DIR} && export PATH=\"\$HOME/.local/bin:\$PATH\"; \
  PIPENV_VENV_IN_PROJECT=1 pipenv run /opt/odoo/18/ce/odoo-bin -c odoo.conf -i base,web --stop-after-init"
ok "Odoo init completed"



# ==========================================================================
# systemd service
# ==========================================================================
step "Create & start systemd service"

# Create/update the unit
info "Creating service via ${SERVICE_SCRIPT}"
bash "$SERVICE_SCRIPT" "${DOMAIN_RAW}" "${DEV_USER}" --odoo-root /opt/odoo/18/ce

# Activate
info "Reload systemd and enable/start ${DOMAIN_RAW}.service"
systemctl daemon-reload
systemctl enable "${DOMAIN_RAW}.service"
systemctl restart "${DOMAIN_RAW}.service"




# ==========================================================================
# Nginx vhost
# ==========================================================================
step "Create Nginx vhost"

# Read ports from the generated odoo.conf
ODOO_CONF="/home/${DEV_USER}/${PROJECT_DIR}/odoo.conf"
if [[ ! -f "$ODOO_CONF" ]]; then
  err "Cannot find ${ODOO_CONF} to detect ports"
  exit 1
fi

HTTP_PORT="$(awk -F'=' '/^[[:space:]]*http_port[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2}' "$ODOO_CONF")"
GEVENT_PORT="$(awk -F'=' '/^[[:space:]]*gevent_port[[:space:]]*=/ {gsub(/[[:space:]]/,"",$2); print $2}' "$ODOO_CONF")"

if [[ -z "${HTTP_PORT:-}" || -z "${GEVENT_PORT:-}" ]]; then
  err "Failed to parse http_port/gevent_port from ${ODOO_CONF}"
  exit 1
fi

info "Detected ports: http=${HTTP_PORT}, gevent=${GEVENT_PORT}"
info "Generating Nginx config via ${NGINX_SCRIPT}"
bash "$NGINX_SCRIPT" "${PROJECT_DIR}" "${HTTP_PORT}" "${GEVENT_PORT}"

ok "Nginx vhost created and reloaded"




# ==========================================================================
# summary
# ==========================================================================
step "Summary"
kv "${BOLD}Unix user${RESET}"   "${DEV_USER} (created if missing)"
kv "${BOLD}Ran${RESET}"          "setup-server.sh (USER=${DEV_USER}, HOME=${HOME})"
kv "${BOLD}Project dir${RESET}"  "~/${PROJECT_DIR}"
kv "${BOLD}DB user${RESET}"      "${DB_USER}"
kv "${BOLD}DB name${RESET}"      "${DB_NAME}"
if [[ -n "$GREEN" ]]; then
  kv "${BOLD}DB password${RESET}" "${GREEN}${DB_PASS}${RESET}"
else
  kv "DB password" "${DB_PASS}"
fi
printf "\n%sStore the password securely (e.g., a secret manager).%s\n" "$DIM" "$RESET"

# Optional: support a hidden flag to print just the password if invoked that way
if [[ "${3:-}" == "--print-pass" ]]; then
  printf "%s\n" "${DB_PASS}"
fi

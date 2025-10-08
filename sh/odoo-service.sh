#!/usr/bin/env bash
# make-odoo-service.sh — create and enable a systemd service for an Odoo project
# Usage: ./make-odoo-service.sh <domain> <linux_user> [--odoo-root /opt/odoo/18/ce] [--no-start]

set -euo pipefail

OD_ROOT="/opt/odoo/18/ce"
START_AFTER_CREATE=1

# --- parse args ---
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <domain> <linux_user> [--odoo-root /opt/odoo/18/ce] [--no-start]" >&2
  exit 1
fi

DOMAIN_RAW="$1"; shift
LINUX_USER="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --odoo-root)
      OD_ROOT="${2:-}"; shift 2;;
    --no-start)
      START_AFTER_CREATE=0; shift;;
    *)
      echo "Unknown option: $1" >&2; exit 1;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

# --- derive paths ---
PROJECT_DIR="/home/${LINUX_USER}/${DOMAIN_RAW}"
VENV_PY="${PROJECT_DIR}/.venv/bin/python"
ODOO_BIN="${OD_ROOT}/odoo-bin"
CONF_FILE="${PROJECT_DIR}/odoo.conf"
SERVICE_FILE="/etc/systemd/system/${DOMAIN_RAW}.service"

# --- sanity checks (soft warnings if not present yet) ---
if ! id -u "$LINUX_USER" >/dev/null 2>&1; then
  echo "Warning: Linux user '${LINUX_USER}' does not exist (continuing)." >&2
fi
[[ -f "$CONF_FILE" ]] || echo "Warning: ${CONF_FILE} not found (continuing)." >&2
[[ -x "$VENV_PY" ]] || echo "Warning: ${VENV_PY} not found/executable (continuing)." >&2
[[ -f "$ODOO_BIN" ]] || { echo "Error: ${ODOO_BIN} not found. Use --odoo-root to override."; exit 1; }

# --- write systemd unit ---
cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=Odoo (gevent, reverse-proxied) - ${DOMAIN_RAW}
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=${LINUX_USER}
Group=${LINUX_USER}
WorkingDirectory=${PROJECT_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=${VENV_PY} ${ODOO_BIN} -c ${CONF_FILE}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# --- permissions & reload ---
chmod 0644 "$SERVICE_FILE"
systemctl daemon-reload

# --- enable & (optionally) start ---
systemctl enable "${DOMAIN_RAW}.service"
if [[ "$START_AFTER_CREATE" -eq 1 ]]; then
  systemctl start "${DOMAIN_RAW}.service"
  systemctl status --no-pager "${DOMAIN_RAW}.service" || true
else
  echo "Service created and enabled. Start it with: systemctl start ${DOMAIN_RAW}.service"
fi

echo "Created: ${SERVICE_FILE}"

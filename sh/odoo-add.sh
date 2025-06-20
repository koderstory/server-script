#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<EOF
Usage: $0 -u USER -d DOMAIN -U DB_USER -n DB_NAME -p DB_PASS [-v PYTHON_VERSION] [-h]

Options:
  -U USER             OS user to own and run Odoo under (required)
  -D DOMAIN           Domain name/directory (e.g. example.com) (required)
  -u DB_USER          Database user (required)
  -n DB_NAME          Database name (required)
  -p DB_PASS          Database password (required)
  -v PYTHON_VERSION   Python version for this directory (pyenv local). Defaults to pyenv global if omitted.
  -h                  Show this help message and exit.

Example:
  ./odoo.sh -U dev -D tes.domain.com -u user1 -n tes1 -p pass1 -v 3.11

EOF
  exit 1
}

# Function to pick a free TCP port in [10000,65000]
get_free_port() {
  while :; do
    port=$(( RANDOM % (65000-10000+1) + 10000 ))
    if ! ss -lntu | awk '{print $5}' | grep -E -q "(^|:)$port$"; then
      echo "$port"
      return
    fi
  done
}

# Acquire two distinct free ports for XML-RPC and longpolling
XMLRPC_PORT=$(get_free_port)
LONGPOLLING_PORT=$(get_free_port)
while [ "$LONGPOLLING_PORT" = "$XMLRPC_PORT" ]; do
  LONGPOLLING_PORT=$(get_free_port)
 done

# Parse options
PYVER=
while getopts ":U:D:u:n:p:v:h" opt; do
  case "$opt" in
    U) USERNAME="$OPTARG" ;;
    D) DOMAIN="$OPTARG" ;;
    u) DB_USER="$OPTARG" ;;
    n) DB_NAME="$OPTARG" ;;
    p) DB_PASS="$OPTARG" ;;
    v) PYVER="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done
shift $((OPTIND-1))

enforce_opts() {
  if [ -z "${USERNAME:-}" ] || [ -z "${DOMAIN:-}" ] || [ -z "${DB_USER:-}" ] || [ -z "${DB_NAME:-}" ] || [ -z "${DB_PASS:-}" ] || [ -z "${PYVER:-}" ]; then
    usage
  fi
}
enforce_opts

# Check user exists
if ! id "$USERNAME" &>/dev/null; then
  echo "Error: user '$USERNAME' does not exist." >&2
  exit 1
fi

DOMAIN_DIR="/home/$USERNAME/$DOMAIN"

# Prepare directory
echo "Creating directory $DOMAIN_DIR..."
mkdir -p "$DOMAIN_DIR"/.venv
chown -R "$USERNAME":"$USERNAME" "$DOMAIN_DIR"

# Set python version locally if specified
echo "Configuring Python version and pipenv"
sudo -i -u "$USERNAME" bash -lc "/home/$USERNAME/.pyenv/shims/python3 -m pip install --upgrade pip pipenv  && cd $DOMAIN_DIR && /home/$USERNAME/.pyenv/shims/python3 -m pipenv --python $PYVER install "



# Install Python requirements
echo "Installing Python requirements..."
sudo -i -u "$USERNAME" bash -lc "$DOMAIN_DIR/.venv/bin/python3 -m pip install -r /opt/odoo18-ce/requirements.txt"


# Create odoo.conf before init/install
CONF_FILE="$DOMAIN_DIR/odoo.conf"
echo "Generating Odoo config at $CONF_FILE..."
cat <<EOF > "$CONF_FILE"
[options]

; 1. Core Add-ons & Modules
addons_path = /opt/odoo18-ce/odoo/addons,/opt/odoo18-ce/addons,/opt/odoo18-themes
server_wide_modules = base,web
import_partial =
without_demo = True
translate_modules = ['all']

; 2. Security & Access Control
admin_passwd = admin
proxy_mode = False
dbfilter =

; 3. Database Configuration & Management
db_host = localhost
db_port = False
db_user = $DB_USER
db_name = $DB_NAME
db_password = $DB_PASS
db_template = template0
db_sslmode = prefer
unaccent = False
db_maxconn = 64
db_maxconn_gevent = False
db_replica_host = False
db_replica_port = False
list_db = True

; 4. Server & Protocol Interfaces
http_enable = True
http_interface =
http_port = 8069
gevent_port = 8072
xmlrpc_port = $XMLRPC_PORT
longpolling_port = $LONGPOLLING_PORT
websocket_keep_alive_timeout = 3600
websocket_rate_limit_burst = 10
websocket_rate_limit_delay = 0.2
x_sendfile = False
pidfile =

; 5. Paths & Data Storage
data_dir = $DOMAIN_DIR

; 6. Performance & Resource Limits
workers = 0
max_cron_threads = 2
limit_memory_hard = 2684354560
limit_memory_hard_gevent = False
limit_memory_soft = 2147483648
limit_memory_soft_gevent = False
limit_request = 65536
limit_time_cpu = 60
limit_time_real = 120
limit_time_real_cron = -1
limit_time_worker_cron = 0
osv_memory_count_limit = 0
transient_age_limit = 1.0

; 7. Logging & Reporting
logfile = $DOMAIN_DIR/logs/odoo.log
log_level = info
log_handler = :INFO
syslog = False
log_db = False
log_db_level = warning
reportgz = False
screencasts =
screenshots = /tmp/odoo_tests

; 8. Email & Notifications
smtp_server = localhost
smtp_port = 25
smtp_ssl = False
smtp_user = False
smtp_password = False
smtp_ssl_certificate_filename = False
smtp_ssl_private_key_filename = False
email_from = False
from_filter = False

; 9. Localization & Data Formats
csv_internal_sep = ,
geoip_city_db = /usr/share/GeoIP/GeoLite2-City.mmdb
geoip_country_db = /usr/share/GeoIP/GeoLite2-Country.mmdb

; 10. Testing & Maintenance
test_enable = False
test_file =
test_tags = None
pre_upgrade_scripts =
upgrade_path =
EOF

# Adjust ownership and permissions for config
chown "$USERNAME":"$USERNAME" "$CONF_FILE"
chmod 640 "$CONF_FILE"

# Initialize database
echo "Initializing Odoo database (base module)..."
sudo -i -u "$USERNAME" bash -lc "$DOMAIN_DIR/.venv/bin/python3  /opt/odoo18-ce/odoo-bin -c $DOMAIN_DIR/odoo.conf -i base --stop-after-init"



# Create systemd service
SERVICE_NAME="odoo_${DOMAIN}"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
echo "Creating systemd service file $SERVICE_FILE..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Odoo ${DOMAIN}
After=network.target

[Service]
User=${USERNAME}
Group=${USERNAME}
WorkingDirectory=/opt/odoo18-ce
ExecStart="$DOMAIN_DIR"/.venv/bin/python3 /opt/odoo18-ce/odoo-bin -c "$CONF_FILE"
Restart=on-failure
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

# Enable and start service
echo "Reloading systemd, enabling and starting $SERVICE_NAME..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"


# Configure Nginx
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
echo "Creating nginx config $NGINX_CONF..."
cat <<EOF > "$NGINX_CONF"
server {
    listen 80;
    server_name ${DOMAIN};

    client_max_body_size 200M;
    access_log ${DOMAIN_DIR}/logs/nginx.access.log;
    error_log  ${DOMAIN_DIR}/logs/nginx.error.log;

    location / {
        proxy_pass         http://127.0.0.1:${XMLRPC_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }

    location /longpolling/ {
        proxy_pass         http://127.0.0.1:${LONGPOLLING_PORT};
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
echo "Testing nginx config and reloading..."
nginx -t && systemctl reload nginx

echo "✅ Odoo setup complete for domain $DOMAIN (user: $USERNAME)."
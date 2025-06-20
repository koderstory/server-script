#!/usr/bin/env bash
set -euo pipefail

# Usage and parameters
usage() {
  cat <<USAGE
Usage: $0 <linux_user> <domain> <db_user> <db_name> <db_pass>

  <linux_user>  Linux system username (used for home directory)
  <domain>      Domain name (e.g. example.com)
  <db_user>     PostgreSQL username
  <db_name>     PostgreSQL database name
  <db_pass>     PostgreSQL password
USAGE
  exit 1
}

# Require exactly 5 arguments
if [[ $# -ne 5 ]]; then
  usage
fi

# Assign positional arguments
domain="$2"
linux_user="$1"
db_user="$3"
db_name="$4"
db_pass="$5"

# Determine output directory and file
OUTPUT_DIR="/home/${linux_user}/${domain}"
OUTPUT_FILE="${OUTPUT_DIR}/odoo.conf"

# Create output directory if missing
mkdir -p "$OUTPUT_DIR"

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
if [[ "$LONGPOLLING_PORT" == "$XMLRPC_PORT" ]]; then
  LONGPOLLING_PORT=$(get_free_port)
fi

# Generate the Odoo configuration file
cat > "$OUTPUT_FILE" <<EOF
[options]

; 1. Core Add-ons & Modules
addons_path = /opt/odoo18-ce/odoo/addons,/opt/odoo18-ce/addons
server_wide_modules = base,web
import_partial =
without_demo = False
translate_modules = ['all']

; 2. Security & Access Control
admin_passwd = admin
proxy_mode = False
dbfilter =

; 3. Database Configuration & Management
db_host = localhost
db_port = False
db_user = $db_user
db_name = $db_name
db_password = $db_pass
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
data_dir = /home/dev/.local/share/Odoo

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
logfile =
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

# Final message
echo "Generated Odoo config at $OUTPUT_FILE"
echo "  Domain:     $domain"
echo "  Linux User: $linux_user"
echo "  DB:         $db_name (@$db_user)"
echo "  Ports:      xmlrpc=$XMLRPC_PORT, longpolling=$LONGPOLLING_PORT"

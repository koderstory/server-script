#!/usr/bin/env bash

# WordPress one-shot installer for Ubuntu (Nginx + PHP-FPM + MariaDB + UFW + Let's Encrypt)
# - Idempotent(ish): safe to re-run; won’t clobber existing DB unless you choose to.
# - Safer defaults, stricter Bash, clearer logs.
# - Works with PHP 7.4–8.x (default: 8.2).

set -Eeuo pipefail
IFS=$'\n\t'

########################################
# Helpers
########################################
log() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
err() { printf "\n\033[1;31m[ERROR]\033[0m %s\n" "$*" >&2; }
confirm() { read -r -p "$1 [y/N]: " ans; [[ ${ans:-N} =~ ^[Yy]$ ]]; }
require_root() { [[ $EUID -eq 0 ]] || { err "Please run as root."; exit 1; }; }
exists() { command -v "$1" >/dev/null 2>&1; }

# Hex-only to avoid quoting headaches in SQL and config
rand_hex() { local n=${1:-16}; openssl rand -hex "$n"; }

# Replace-or-append in php.ini (simple, line-based)
php_ini_set() {
  local key="$1" val="$2" ini="/etc/php/${PHP_VERSION}/fpm/php.ini"
  if grep -qE "^\s*${key}\s*=\s*" "$ini"; then
    sed -i "s|^\s*${key}\s*=.*|${key} = ${val}|" "$ini"
  else
    printf "\n%s = %s\n" "$key" "$val" >>"$ini"
  fi
}

########################################
# Input
########################################
require_root

read -r -p "Enter your domain (e.g., example.com or www.example.com): " DOMAIN
DOMAIN=${DOMAIN,,} # lowercase
[[ -n ${DOMAIN} ]] || { err "Domain is required."; exit 1; }

# Compute server_names and canonical host
if [[ $DOMAIN == www.* ]]; then
  ROOT_DOMAIN="${DOMAIN#www.}"
  SERVER_NAMES="$ROOT_DOMAIN www.$ROOT_DOMAIN"
  CANON_HOST="$ROOT_DOMAIN"
else
  ROOT_DOMAIN="$DOMAIN"
  SERVER_NAMES="$ROOT_DOMAIN"
  CANON_HOST="$ROOT_DOMAIN"
fi

# DB identifiers (<= 64 chars for MariaDB). Replace dots with underscores.
DB_NAME=${ROOT_DOMAIN//./_}
# Add a short random suffix to the user for uniqueness
DB_USER="${DB_NAME}_$(rand_hex 4)"
DB_PASS=$(rand_hex 16)

read -r -p "Enter PHP version (7.4, 8.0, 8.1, 8.2) [8.2]: " PHP_VERSION
PHP_VERSION=${PHP_VERSION:-8.2}

read -r -p "Email for Let's Encrypt/Certbot notices: " LE_EMAIL
[[ -n ${LE_EMAIL} ]] || { err "Email is required for Let's Encrypt."; exit 1; }

########################################
# Packages
########################################
log "Installing system packages (Nginx, MariaDB, PHP ${PHP_VERSION})..."
apt-get update -y
apt-get install -y nginx mariadb-server mariadb-client curl git zip unzip software-properties-common ufw

# PHP from ppa:ondrej/php
if ! apt-cache policy | grep -q "ondrej/php"; then
  log "Adding ppa:ondrej/php"
  LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
  apt-get update -y
fi

# Core PHP packages (php-json is default in 8.x)
PHP_PKGS=("php${PHP_VERSION}" "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-cli" \
          "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-xml" \
          "php${PHP_VERSION}-mbstring" "php${PHP_VERSION}-gd" "php${PHP_VERSION}-soap" \
          "php${PHP_VERSION}-intl" "php${PHP_VERSION}-bcmath" "php${PHP_VERSION}-xmlrpc")

# Only add php-json for < 8.0
if [[ ! ${PHP_VERSION} =~ ^8 ]]; then
  PHP_PKGS+=("php${PHP_VERSION}-json")
fi

apt-get install -y "${PHP_PKGS[@]}"

systemctl enable --now php${PHP_VERSION}-fpm

########################################
# Tune PHP for WordPress
########################################
log "Configuring PHP-FPM settings..."
php_ini_set upload_max_filesize 64M
php_ini_set post_max_size 64M
php_ini_set memory_limit 256M
php_ini_set max_execution_time 300
systemctl reload php${PHP_VERSION}-fpm

########################################
# MariaDB: DB + user
########################################
log "Configuring MariaDB (database & user)..."
systemctl enable --now mariadb

# Create/replace database optionally
DB_EXISTS=$(mysql -Nse "SHOW DATABASES LIKE '${DB_NAME}'" || true)
if [[ -n "$DB_EXISTS" ]]; then
  log "Database '${DB_NAME}' already exists."
  if confirm "Drop and recreate database '${DB_NAME}'?"; then
    mysql -e "DROP DATABASE \`${DB_NAME}\`;"
    mysql -e "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  else
    log "Keeping existing database."
  fi
else
  mysql -e "CREATE DATABASE \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
fi

# Create/ensure user + grant (password is hex-only, safe to single-quote)
mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

########################################
# WordPress download & config
########################################
log "Downloading WordPress..."
TMP_DIR=$(mktemp -d)
cd "$TMP_DIR"
curl -fsSL -o latest.tar.gz https://wordpress.org/latest.tar.gz
 tar -xzf latest.tar.gz

INSTALL_ROOT="/var/www/${CANON_HOST}"
mkdir -p "$INSTALL_ROOT"
# Only move if empty to avoid overwriting an existing site
if [[ -z $(ls -A "$INSTALL_ROOT" 2>/dev/null || true) ]]; then
  mv wordpress/* "$INSTALL_ROOT"/
else
  log "Target directory ${INSTALL_ROOT} not empty; skipping move of core files."
fi

chown -R www-data:www-data "$INSTALL_ROOT"
find "$INSTALL_ROOT" -type d -exec chmod 755 {} +
find "$INSTALL_ROOT" -type f -exec chmod 644 {} +

# wp-config.php
if [[ ! -f "$INSTALL_ROOT/wp-config.php" ]]; then
  cp "$INSTALL_ROOT/wp-config-sample.php" "$INSTALL_ROOT/wp-config.php"
  sed -i "s/database_name_here/${DB_NAME}/" "$INSTALL_ROOT/wp-config.php"
  sed -i "s/username_here/${DB_USER}/" "$INSTALL_ROOT/wp-config.php"
  sed -i "s/password_here/${DB_PASS}/" "$INSTALL_ROOT/wp-config.php"
  # Add WordPress salts
  SALTS=$(curl -fsSL https://api.wordpress.org/secret-key/1.1/salt/)
  if [[ -n $SALTS ]]; then
    # Replace placeholder keys block
    sed -i "/AUTH_KEY/,\$d" "$INSTALL_ROOT/wp-config.php"
    printf "\n%s\n" "$SALTS" >> "$INSTALL_ROOT/wp-config.php"
  fi
fi

########################################
# Nginx vhost
########################################
log "Configuring Nginx for ${SERVER_NAMES}..."
SOCKET_PATH="/var/run/php/php${PHP_VERSION}-fpm.sock"
SITE_CONF="/etc/nginx/sites-available/${CANON_HOST}"

cat >"$SITE_CONF" <<EOF
server {
    listen 80;
    server_name ${SERVER_NAMES};

    root ${INSTALL_ROOT};
    index index.php index.html index.htm;

    # Recommended for WP permalinks
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${SOCKET_PATH};
    }

    # Security hardening
    location ~* /\. { deny all; }
    location = /xmlrpc.php { deny all; }

    client_max_body_size 128m;
}
EOF

ln -sfn "$SITE_CONF" "/etc/nginx/sites-enabled/${CANON_HOST}"
nginx -t
systemctl reload nginx

########################################
# UFW
########################################
log "Configuring UFW..."
ufw allow OpenSSH || true
ufw allow "Nginx Full" || true
ufw --force enable || true

########################################
# Let's Encrypt (Certbot)
########################################
log "Installing Certbot & requesting certificates..."
apt-get install -y certbot python3-certbot-nginx

# Cover both root and www if applicable
CERT_DOMAINS=(-d "$ROOT_DOMAIN")
if [[ $SERVER_NAMES == *"www."* ]]; then
  CERT_DOMAINS+=(-d "www.$ROOT_DOMAIN")
fi

certbot --nginx "${CERT_DOMAINS[@]}" --non-interactive --agree-tos --email "$LE_EMAIL" --redirect || {
  err "Certbot failed; you can retry later with: certbot --nginx -d ${SERVER_NAMES// / -d }";
}

systemctl reload nginx

########################################
# Done
########################################
log "WordPress installed (or updated) successfully!"
echo "Domain:              $SERVER_NAMES"
echo "Web root:            $INSTALL_ROOT"
echo "Database Name:       $DB_NAME"
echo "Database User:       $DB_USER"
echo "Database Password:   $DB_PASS"
echo "Visit:               https://${CANON_HOST} (or http if SSL not issued)"

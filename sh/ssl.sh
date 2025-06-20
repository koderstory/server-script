#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# install_ssl.sh
#
# Usage:
#   sudo ./install_ssl.sh example.com
#
# This will:
#   1. Install Certbot and the Nginx plugin
#   2. Obtain a TLS certificate for your domain
#   3. Update your existing Nginx site to enable HTTPS
#   4. Reload Nginx
# ------------------------------------------------------------

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <your-domain>" >&2
  exit 1
fi

DOMAIN="$1"
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"

# 1) Ensure we’re root
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root" >&2
  exit 1
fi

# 2) Install Certbot + Nginx plugin
apt update -y
apt install -y certbot python3-certbot-nginx

# 3) Test Nginx configuration before touching it
nginx -t || { echo "ERROR: nginx config test failed" >&2; exit 1; }

# 4) Obtain/renew certificate via Certbot’s Nginx plugin
#    --non-interactive: no prompts
#    --agree-tos: agree to Let’s Encrypt terms
#    --redirect: automatically configure HTTP→HTTPS redirect
#    --no-eff-email: don’t subscribe to EFF mail list
certbot --nginx \
        --non-interactive \
        --agree-tos \
        --no-eff-email \
        --redirect \
        -d "${DOMAIN}" \
        -m "admin@${DOMAIN}"

# 5) Reload Nginx to pick up Certbot’s certificates
systemctl reload nginx

echo "✅ SSL enabled for ${DOMAIN}. Certificates live in /etc/letsencrypt/live/${DOMAIN}/"

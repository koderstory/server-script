#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# ssl.sh
#
# Usage:
#   sudo ./ssl.sh <domain> <email>
#
# Example:
#   sudo ./ssl.sh example.com ops@example.com
#
# This will:
#   1. Install Certbot and the Nginx plugin
#   2. Obtain a TLS certificate for your domain
#   3. Update your existing Nginx site to enable HTTPS (redirect HTTP->HTTPS)
#   4. Reload Nginx
# ------------------------------------------------------------

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <domain> <email>" >&2
  exit 1
fi

DOMAIN="$1"
EMAIL="$2"
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"

# 1) Ensure we’re root
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: must run as root" >&2
  exit 1
fi

# 2) Quick sanity checks (best-effort)
if [[ ! -f "$NGINX_CONF" ]]; then
  echo "WARN: $NGINX_CONF not found. Certbot --nginx will still try to locate the server block." >&2
fi

# Optional light email check
if ! [[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
  echo "ERROR: email appears invalid: $EMAIL" >&2
  exit 1
fi

# 3) Install Certbot + Nginx plugin
apt update -y
apt install -y certbot python3-certbot-nginx

# 4) Test Nginx configuration before touching it
nginx -t || { echo "ERROR: nginx config test failed" >&2; exit 1; }

# 5) Obtain/renew certificate via Certbot’s Nginx plugin
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
  -m "${EMAIL}"

# 6) Reload Nginx to pick up Certbot’s certificates
systemctl reload nginx

echo "✅ SSL enabled for ${DOMAIN} (email: ${EMAIL})."
echo "   Certificates live in /etc/letsencrypt/live/${DOMAIN}/"

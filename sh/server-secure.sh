#!/usr/bin/env bash
# server-secure.sh — Ubuntu server hardening for web workloads (NGINX/WordPress-friendly)
# Run as root: sudo bash server-secure.sh
set -euo pipefail

# =========================
# Configurable variables
# =========================
ADMIN_USER="${ADMIN_USER:-dev}"          # admin/sudo user to create/ensure
SSH_PORT="${SSH_PORT:-22}"               # change if you use a custom SSH port
ENABLE_LETSENCRYPT_GROUP="${ENABLE_LETSENCRYPT_GROUP:-1}"  # 1=add www-data to ssl-cert if present
HIDE_NGINX_TOKENS="${HIDE_NGINX_TOKENS:-1}"               # 1=create conf.d/hide_tokens.conf
ENABLE_FAIL2BAN_NGINX_JAILS="${ENABLE_FAIL2BAN_NGINX_JAILS:-1}" # 1=enable nginx-http-auth & nginx-botsearch

# =========================
# Helpers
# =========================
log()  { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err()  { echo -e "\033[1;31m[✗] $*\033[0m"; }
die()  { err "$*"; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"; }

backup_file() {
  local f="$1"
  [[ -f "$f" ]] && cp -a "$f" "${f}.$(date +%F_%H%M%S).bak" || true
}

append_once() {
  local line="$1" file="$2"
  grep -qxF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

normalize_ssh_kv() {
  local key="$1" value="$2" file="/etc/ssh/sshd_config"
  if grep -qiE "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -i "s|^[#[:space:]]*${key}[[:space:]]\\+.*|${key} ${value}|I" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi
}

# =========================
# 0) Preconditions
# =========================
require_root
export DEBIAN_FRONTEND=noninteractive

# =========================
# 1) System updates & unattended upgrades
# =========================
log "Updating packages and applying full upgrade…"
apt update
apt -y full-upgrade

log "Installing unattended-upgrades and apt-listchanges…"
apt -y install unattended-upgrades apt-listchanges >/dev/null || true
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

# =========================
# 2) Time sync
# =========================
log "Ensuring NTP time sync is enabled…"
timedatectl set-ntp true || true

# =========================
# 3) Remove legacy network clients
# =========================
log "Purging legacy clients (telnet, ftp, rsh, rlogin, talk)…"
apt -y purge telnet ftp rsh-client rlogin talk talkd 2>/dev/null || true
apt -y autoremove --purge || true

# =========================
# 4) AppArmor
# =========================
log "Checking AppArmor status…"
apt -y install apparmor apparmor-utils >/dev/null 2>&1 || true
aa-status || true

# =========================
# 5) Admin user & SSH keys
# =========================
log "Ensuring admin user '$ADMIN_USER' exists and is a sudoer…"
if ! id -u "$ADMIN_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$ADMIN_USER"
fi
usermod -aG sudo "$ADMIN_USER"

# 5a) SSH keys: copy root's authorized_keys to the admin user
log "Copying /root/.ssh/authorized_keys to ${ADMIN_USER}…"
if [[ -f /root/.ssh/authorized_keys ]]; then
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  cp -a /root/.ssh/authorized_keys "/home/$ADMIN_USER/.ssh/authorized_keys"
  chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"
  chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
  log "Authorized keys installed for ${ADMIN_USER}."
else
  warn "No /root/.ssh/authorized_keys found. Create one for root first or add a key to /home/${ADMIN_USER}/.ssh/authorized_keys."
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/$ADMIN_USER/.ssh"
  touch "/home/$ADMIN_USER/.ssh/authorized_keys"
  chown "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.ssh/authorized_keys"
  chmod 600 "/home/$ADMIN_USER/.ssh/authorized_keys"
fi

# =========================
# 6) SSH hardening
# =========================
log "Hardening SSH daemon…"
backup_file /etc/ssh/sshd_config

normalize_ssh_kv "Port" "$SSH_PORT"
normalize_ssh_kv "PasswordAuthentication" "no"
normalize_ssh_kv "PermitRootLogin" "no"
normalize_ssh_kv "PubkeyAuthentication" "yes"
normalize_ssh_kv "ChallengeResponseAuthentication" "no"
normalize_ssh_kv "X11Forwarding" "no"
normalize_ssh_kv "UsePAM" "yes"
append_once "AllowUsers $ADMIN_USER" /etc/ssh/sshd_config

if ! sshd -t; then
  die "sshd_config validation failed; restore backup and fix configuration."
fi
systemctl reload ssh || systemctl restart ssh

# =========================
# 7) UFW firewall
# =========================
log "Configuring UFW (deny inbound by default; allow SSH/HTTP/HTTPS; deny DB ports)…"
apt -y install ufw >/dev/null 2>&1 || true
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}"/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw deny 5432/tcp
ufw deny 3306/tcp
ufw --force enable
ufw status verbose || true

# =========================
# 8) Fail2Ban
# =========================
log "Installing and configuring Fail2Ban…"
apt -y install fail2ban >/dev/null 2>&1 || true
install -d -m 755 /etc/fail2ban/jail.d

cat >/etc/fail2ban/jail.d/10-sshd.conf <<'EOF'
[sshd]
enabled = true
maxretry = 5
bantime = 1h
EOF

if [[ "$ENABLE_FAIL2BAN_NGINX_JAILS" == "1" ]]; then
  cat >/etc/fail2ban/jail.d/20-nginx.conf <<'EOF'
[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
EOF
fi

systemctl restart fail2ban
fail2ban-client status || true

# =========================
# 9) NGINX install & hardening
# =========================
log "Installing NGINX and basic hardening…"
apt -y install nginx >/dev/null 2>&1 || true

if [[ "$HIDE_NGINX_TOKENS" == "1" ]]; then
  install -d -m 755 /etc/nginx/conf.d
  backup_file /etc/nginx/conf.d/hide_tokens.conf
  echo 'server_tokens off;' > /etc/nginx/conf.d/hide_tokens.conf
fi

nginx -t && systemctl reload nginx || true

# =========================
# 10) (REMOVED as requested)
# =========================

# =========================
# 11) Optional: Let’s Encrypt permissions for NGINX read-access
# =========================
if [[ "$ENABLE_LETSENCRYPT_GROUP" == "1" && -d /etc/letsencrypt ]]; then
  if getent group ssl-cert >/dev/null 2>&1; then
    log "Granting www-data read access to Let's Encrypt certs via ssl-cert group…"
    usermod -aG ssl-cert www-data || true
    chgrp -R ssl-cert /etc/letsencrypt/live /etc/letsencrypt/archive || true
    chmod -R 750 /etc/letsencrypt/live /etc/letsencrypt/archive || true
    find /etc/letsencrypt/archive -type f -name '*.pem' -exec chmod g+r {} \;
  fi
fi

# =========================
# 12) Final status
# =========================
log "Final status:"
echo "- SSH port: $SSH_PORT"
echo "- Admin user: $ADMIN_USER (sudo)"
echo "- UFW: $(ufw status | head -n1)"
echo "- Fail2Ban jails:"
fail2ban-client status 2>/dev/null | sed -n '1,4p' || true
echo "- NGINX: $(systemctl is-active nginx)"

log "All done. Verify you can open a NEW SSH session (key auth) before closing the current one."

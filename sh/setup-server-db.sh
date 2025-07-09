#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# Color definitions
# -------------------------------------------------------------------
# \e[32m = green, \e[0m = reset
GREEN=$'\e[32m'
RESET=$'\e[0m'

# Helper to print in green
print_green() {
  # -e to enable escape codes
  echo -e "${GREEN}$1${RESET}"
}

# -------------------------------------------------------------------
# Ensure script is run as root
# -------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  print_green "ERROR: This script must be run as root."
  exit 1
fi

# -------------------------------------------------------------------
# 1. System update & upgrade
# -------------------------------------------------------------------
print_green ">>> Updating package lists and upgrading installed packages..."
apt update -y
apt upgrade -y

# -------------------------------------------------------------------
# 2. Install core build tools & system utilities
# -------------------------------------------------------------------
print_green ">>> Installing core tools..."
apt install -y \
    build-essential \
    git \
    wget \
    curl

# -------------------------------------------------------------------
# 3. Install system services
# -------------------------------------------------------------------
print_green ">>> Installing system services..."
apt install -y \
    openssh-server \
    fail2ban \
    postgresql \
    postgresql-contrib \

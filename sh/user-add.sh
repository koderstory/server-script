#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# -------------------------------------------------------------------
# Color definitions
# -------------------------------------------------------------------
GREEN='\e[32m'
RESET='\e[0m'

# -------------------------------------------------------------------
# 1) Prompt for username
# -------------------------------------------------------------------
read -r -p "Enter new username:" USERNAME
if id "$USERNAME" &>/dev/null; then
  echo -e "⚠️  User '$USERNAME' already exists!" >&2
  exit 1
fi

# -------------------------------------------------------------------
# 2) Prompt for full name/comment
# -------------------------------------------------------------------
read -r -p "Enter full name/comment (e.g. John Doe):" COMMENT

# -------------------------------------------------------------------
# 3) Prompt for password (hidden)
# -------------------------------------------------------------------
read -r -s -p "Enter password for ${USERNAME}:" PASS
echo
read -r -s -p "Confirm password: " PASS2
echo

# -------------------------------------------------------------------
# 4) Make sure they match
# -------------------------------------------------------------------
if [[ "$PASS" != "$PASS2" ]]; then
  echo -e "${GREEN}❌  Passwords do not match!${RESET}" >&2
  exit 1
fi

# -------------------------------------------------------------------
# 5) Basic strength check
#    - at least 8 chars
#    - one uppercase, one lowercase, one digit, one special
# -------------------------------------------------------------------
if [[ ${#PASS} -lt 8 \
      || ! "$PASS" =~ [A-Z] \
      || ! "$PASS" =~ [a-z] \
      || ! "$PASS" =~ [0-9] \
      || ! "$PASS" =~ [^[:alnum:]] ]]; then
  echo -e "${GREEN}❌  Password is not strong enough!${RESET}" >&2
  echo -e "${GREEN}    It must be ≥8 chars and include uppercase, lowercase, a digit, and a special character.${RESET}" >&2
  exit 1
fi

# -------------------------------------------------------------------
# 6) Create the user (no sudo), set shell & home
# -------------------------------------------------------------------
useradd -m -c "$COMMENT" -s /bin/bash "$USERNAME"

# -------------------------------------------------------------------
# 7) Set the password
# -------------------------------------------------------------------
echo "${USERNAME}:${PASS}" | chpasswd

# -------------------------------------------------------------------
# 8) (Optional) Add to extra groups
# -------------------------------------------------------------------
read -r -p "Add ${USERNAME} to additional groups? (comma-separated, leave blank to skip):" GROUPS
if [[ -n "$GROUPS" ]]; then
  usermod -aG "${GROUPS// /}" "$USERNAME"
fi

# -------------------------------------------------------------------
# 9) Success!
# -------------------------------------------------------------------
echo -e "${GREEN}✅  User '$USERNAME' created successfully!${RESET}"

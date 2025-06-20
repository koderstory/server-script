#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<EOF
Usage: $0 <username>

Deletes the specified system user. You will be prompted to:
  • Confirm deletion
  • Remove the user's home directory and mail spool
  • Remove the user's primary group (if unused)

Example:
  $0 alice
EOF
  exit 1
}

# -------------------------------------------------------------------
# 1. Validate args
# -------------------------------------------------------------------
if [ $# -ne 1 ]; then
  usage
fi

USERNAME="$1"

# -------------------------------------------------------------------
# 2. Check if user exists
# -------------------------------------------------------------------
if ! id "$USERNAME" &>/dev/null; then
  echo "⚠️  User '$USERNAME' does not exist." >&2
  exit 1
fi

# -------------------------------------------------------------------
# 3. Confirm deletion
# -------------------------------------------------------------------
read -rp "Are you sure you want to delete user '$USERNAME'? [y/N]: " CONFIRM
CONFIRM=${CONFIRM,,}  # lowercase
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "yes" ]]; then
  echo "Aborted." 
  exit 0
fi

# -------------------------------------------------------------------
# 4. Ask whether to remove home directory & mail spool
# -------------------------------------------------------------------
read -rp "Remove home directory and mail spool for '$USERNAME'? [y/N]: " RMHOME
RMHOME=${RMHOME,,}

# -------------------------------------------------------------------
# 5. Gather primary group
# -------------------------------------------------------------------
PRIMARY_GROUP=$(id -gn "$USERNAME")

# -------------------------------------------------------------------
# 6. Delete the user
# -------------------------------------------------------------------
echo ">>> Deleting user '$USERNAME'..."
if [[ "$RMHOME" == "y" || "$RMHOME" == "yes" ]]; then
  userdel -r "$USERNAME"
else
  userdel "$USERNAME"
fi

# -------------------------------------------------------------------
# 7. Optionally remove the primary group if now empty
# -------------------------------------------------------------------
# Check if the group still exists and has no members
if getent group "$PRIMARY_GROUP" &>/dev/null; then
  GROUP_MEMBERS=$(getent group "$PRIMARY_GROUP" | awk -F: '{print $4}')
  if [[ -z "$GROUP_MEMBERS" ]]; then
    read -rp "Primary group '$PRIMARY_GROUP' is now empty. Remove it? [y/N]: " RMGROUP
    RMGROUP=${RMGROUP,,}
    if [[ "$RMGROUP" == "y" || "$RMGROUP" == "yes" ]]; then
      echo ">>> Removing group '$PRIMARY_GROUP'..."
      groupdel "$PRIMARY_GROUP"
    fi
  fi
fi

echo "✅ User '$USERNAME' deleted."

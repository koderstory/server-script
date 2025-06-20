#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <db_user> <db_name>

Drops the specified PostgreSQL database and role, if they exist.

  db_user   Name of the Postgres role to drop
  db_name   Name of the database to drop

Example:
  $0 alice alice_db
EOF
  exit 1
}

# 1) Validate args
if [[ $# -ne 2 ]]; then
  usage
fi

DB_USER="$1"
DB_NAME="$2"

# 2) Terminate connections to the database (needed for DROP DATABASE)
echo ">>> Terminating connections to database '$DB_NAME'..."
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = '$DB_NAME'
;"

# 3) Drop the database
echo ">>> Dropping database '$DB_NAME' if it exists..."
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "
  DROP DATABASE IF EXISTS \"$DB_NAME\";
"

# 4) Drop the role
echo ">>> Dropping role '$DB_USER' if it exists..."
sudo -u postgres psql -v ON_ERROR_STOP=1 -c "
  DROP ROLE IF EXISTS \"$DB_USER\";
"

echo "✅ Done. Database '$DB_NAME' and role '$DB_USER' have been removed (if they existed)."

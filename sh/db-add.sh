#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <db_user> <db_name> <db_password>

Creates a PostgreSQL role and database, then locks down the public schema
so only the new role can use/create objects there.

  db_user       Name of the new Postgres role (login user)
  db_name       Name of the new database to create
  db_password   Password for the new role

Example:
  $0 alice alice_db S3cr3tP@ssw0rd
EOF
  exit 1
}

# 1) Validate args
if [[ $# -ne 3 ]]; then
  usage
fi

DB_USER="$1"
DB_NAME="$2"
DB_PASS="$3"

# Helper to run psql as the postgres superuser
psql_postgres() {
  sudo -u postgres psql -v ON_ERROR_STOP=1 -qAt --username=postgres "$@"
}

echo ">>> Checking for role '$DB_USER'..."
if psql_postgres -c "SELECT 1 FROM pg_roles WHERE rolname = '$DB_USER';" | grep -q 1; then
  echo "    Role '$DB_USER' already exists, skipping CREATE ROLE."
else
  echo "    Creating role '$DB_USER'..."
  psql_postgres <<-SQL
    CREATE ROLE "$DB_USER"
      WITH LOGIN
           PASSWORD '$DB_PASS'
           NOSUPERUSER
           NOCREATEDB
           NOREPLICATION
           INHERIT;
SQL
fi

echo ">>> Checking for database '$DB_NAME'..."
if psql_postgres -c "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" | grep -q 1; then
  echo "    Database '$DB_NAME' already exists, skipping CREATE DATABASE."
else
  echo "    Creating database '$DB_NAME' owned by '$DB_USER'..."
  psql_postgres <<-SQL
    CREATE DATABASE "$DB_NAME"
      WITH OWNER = "$DB_USER"
           TEMPLATE = template0;
SQL
fi

echo ">>> Terminating any connections to '$DB_NAME'..."
sudo -u postgres psql -v ON_ERROR_STOP=1 -qAt --username=postgres -d postgres <<-SQL
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = '$DB_NAME';
SQL

echo ">>> Locking down schema in database '$DB_NAME'..."
sudo -u postgres psql -v ON_ERROR_STOP=1 -qAt --username=postgres -d "$DB_NAME" <<-SQL
  REVOKE ALL ON SCHEMA public FROM PUBLIC;
  GRANT USAGE, CREATE ON SCHEMA public TO "$DB_USER";
SQL

echo "✅ Done. Role '$DB_USER' and database '$DB_NAME' are ready."

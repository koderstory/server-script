#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./restore_db_first_locked.sh <db_user> <db_name> <db_pass> [sql_path]
#
# Example:
#   ./restore_db_first_locked.sh myuser mydb mypass /path/to/dump.sql
#
# Env overrides (optional):
#   PROJECT_ZIP=lam.zip PROJECT_DIR=lam_project PG_HOST=127.0.0.1 PG_PORT=5432 DROP_EXISTING=1

DB_USER="${1:?Usage: $0 <db_user> <db_name> <db_pass> [sql_path]}"
DB_NAME="${2:?Usage: $0 <db_user> <db_name> <db_pass> [sql_path]}"
DB_PASS="${3:?Usage: $0 <db_user> <db_name> <db_pass> [sql_path]}"
SQL_DUMP="${4:-${SQL_DUMP:-lambangazasmulia_com.sql}}"

PROJECT_ZIP="${PROJECT_ZIP:-lam.zip}"
PROJECT_DIR="${PROJECT_DIR:-lam_project}"

PG_HOST="${PG_HOST:-127.0.0.1}"
PG_PORT="${PG_PORT:-5432}"

DROP_EXISTING="${DROP_EXISTING:-0}"  # set to 1 to drop

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1"; exit 1; }; }

echo "==> Checking commands..."
need_cmd psql
need_cmd sed
need_cmd unzip
need_cmd python3

if [[ ! -f "$SQL_DUMP" ]]; then
  echo "ERROR: SQL dump not found: $SQL_DUMP"
  exit 1
fi

sql_escape() { printf "%s" "$1" | sed "s/'/''/g"; }

DB_USER_ESC="$(sql_escape "$DB_USER")"
DB_NAME_ESC="$(sql_escape "$DB_NAME")"
DB_PASS_ESC="$(sql_escape "$DB_PASS")"

lockdown_db_connect() {
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
REVOKE ALL ON DATABASE "${DB_NAME_ESC}" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE "${DB_NAME_ESC}" TO "${DB_USER_ESC}";
GRANT CREATE ON DATABASE "${DB_NAME_ESC}" TO "${DB_USER_ESC}";
SQL
}

lockdown_public_schema_and_objects() {
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d "$DB_NAME" <<SQL
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO "${DB_USER_ESC}";

REVOKE ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public FROM PUBLIC;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC;
REVOKE ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

ALTER DEFAULT PRIVILEGES FOR ROLE "${DB_USER_ESC}" IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE "${DB_USER_ESC}" IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE "${DB_USER_ESC}" IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM PUBLIC;
SQL
}

echo "==> (Optional) Dropping existing DB if requested..."
if [[ "$DROP_EXISTING" == "1" ]]; then
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
REVOKE CONNECT ON DATABASE "${DB_NAME_ESC}" FROM PUBLIC;
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname='${DB_NAME_ESC}' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS "${DB_NAME_ESC}";
SQL
fi

echo "==> Creating/Updating Postgres role + database..."
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER_ESC}') THEN
    CREATE ROLE "${DB_USER_ESC}" LOGIN PASSWORD '${DB_PASS_ESC}';
  ELSE
    ALTER ROLE "${DB_USER_ESC}" WITH LOGIN PASSWORD '${DB_PASS_ESC}';
  END IF;
END
\$\$;

SELECT format('CREATE DATABASE %I OWNER %I;', '${DB_NAME_ESC}', '${DB_USER_ESC}')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME_ESC}')
\gexec

GRANT ALL PRIVILEGES ON DATABASE "${DB_NAME_ESC}" TO "${DB_USER_ESC}";
SQL

echo "==> Locking down DB connect (PUBLIC blocked)..."
lockdown_db_connect

echo "==> Sanitizing dump: $SQL_DUMP"
SANITIZED_SQL="$(mktemp /tmp/pgdump_sanitized.XXXXXX.sql)"
cleanup() { rm -f "$SANITIZED_SQL"; }
trap cleanup EXIT

sed -E \
  -e '/^\\connect[[:space:]]+/Id' \
  -e '/^CREATE[[:space:]]+DATABASE[[:space:]]+/Id' \
  -e '/^ALTER[[:space:]]+DATABASE[[:space:]]+/Id' \
  -e '/^COMMENT[[:space:]]+ON[[:space:]]+DATABASE[[:space:]]+/Id' \
  -e '/^ALTER[[:space:]]+(TABLE|SEQUENCE|VIEW|FUNCTION|TYPE)[[:space:]].*OWNER[[:space:]]+TO[[:space:]]+/Id' \
  -e '/^GRANT[[:space:]]+/Id' \
  -e '/^REVOKE[[:space:]]+/Id' \
  -e '/^ALTER[[:space:]]+DEFAULT[[:space:]]+PRIVILEGES[[:space:]]+/Id' \
  "$SQL_DUMP" > "$SANITIZED_SQL"

echo "==> Restoring into ${DB_NAME} as ${DB_USER}..."
PGPASSWORD="$DB_PASS" psql \
  -v ON_ERROR_STOP=1 \
  -h "$PG_HOST" -p "$PG_PORT" \
  -U "$DB_USER" -d "$DB_NAME" \
  -f "$SANITIZED_SQL"

echo "==> Locking down public schema + object privileges (post-restore)..."
lockdown_public_schema_and_objects

echo "✅ Database restored and isolated to user: ${DB_USER}"
echo "   Source SQL: ${SQL_DUMP}"


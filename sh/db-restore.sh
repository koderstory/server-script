#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 <db_user> <db_name> <db_password> <backup_zip> [<odoo_conf>]

Restores an Odoo backup zip containing:
  - dump.sql
  - filestore/

Flow:
  1) Unzip into temp dir
  2) Place filestore into data_dir/filestore/<db_name>
  3) Drop & recreate DB + role via db-del.sh + db-add.sh (admin via postgres)
  4) (Optional) Pre-create extensions found in dump (as postgres)
  5) Sanitize dump to remove role/db-name specific statements (OWNER/GRANT/REVOKE/SET ROLE/\connect/etc)
  6) Restore sanitized dump as <db_user> (so ownership is correct)
EOF
  exit 1
}

if [[ $# -lt 4 || $# -gt 5 ]]; then
  usage
fi

DB_USER="$1"
DB_NAME="$2"
DB_PASS="$3"
ZIP_FILE="$4"
ODOO_CONF="${5:-/etc/odoo/odoo.conf}"

# ---- helpers ----
psql_postgres_db() {
  # Run psql as postgres against a specific database
  local db="$1"; shift
  sudo -u postgres psql -v ON_ERROR_STOP=1 -q --username=postgres -d "$db" "$@"
}

psql_postgres() {
  sudo -u postgres psql -v ON_ERROR_STOP=1 -q --username=postgres "$@"
}

# 1) Unzip backup
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "-> Unzipping $ZIP_FILE → $TMP_DIR"
unzip -q "$ZIP_FILE" -d "$TMP_DIR"

DUMP_FILE="$TMP_DIR/dump.sql"
FS_ROOT="$TMP_DIR/filestore"

[[ -f "$DUMP_FILE" ]] || { echo "ERROR: dump.sql not found"; exit 1; }
[[ -d "$FS_ROOT"  ]] || { echo "ERROR: filestore/ not found"; exit 1; }

# 1b) Handle filestore layout variants:
# Some backups store filestore/<old_db_name>/..., others store filestore/<hex buckets>/...
FS_SRC="$FS_ROOT"
shopt -s nullglob
subdirs=("$FS_ROOT"/*/)
if [[ ${#subdirs[@]} -eq 1 ]]; then
  base="$(basename "${subdirs[0]%/}")"
  if [[ ! "$base" =~ ^[0-9a-f]{2}$ ]]; then
    echo "-> Detected nested filestore layout: filestore/$base/"
    FS_SRC="${subdirs[0]%/}"
  fi
fi

# 2) Determine data_dir
if [[ -f "$ODOO_CONF" ]] && grep -q '^data_dir' "$ODOO_CONF"; then
  DATA_DIR=$(awk -F'=' '/^data_dir/ { gsub(/ /, "", $2); print $2 }' "$ODOO_CONF")
else
  DATA_DIR="/var/lib/odoo"
fi
echo "-> Using data_dir: $DATA_DIR"

# 3) Deploy filestore → data_dir/filestore/<db_name>
FS_PARENT_DIR="$DATA_DIR/filestore"
DEST_FS="$FS_PARENT_DIR/$DB_NAME"
sudo mkdir -p "$FS_PARENT_DIR"
read FS_OWNER FS_GROUP < <(stat -c '%U %G' "$FS_PARENT_DIR")
echo "-> filestore parent owned by: $FS_OWNER:$FS_GROUP"

echo "-> Deploy filestore → $DEST_FS"
sudo rm -rf "$DEST_FS"
sudo mkdir -p "$DEST_FS"
sudo rsync -a --delete "$FS_SRC"/ "$DEST_FS"/
sudo chown -R "$FS_OWNER":"$FS_GROUP" "$DEST_FS"

# 4) Clean up sessions & addons
for d in sessions addons; do
  [[ -d "$DATA_DIR/$d" ]] && { echo "-> Removing $DATA_DIR/$d"; sudo rm -rf "$DATA_DIR/$d"; }
done

# 5) Drop & recreate DB & role (admin via postgres)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEL_SCRIPT="$SCRIPT_DIR/db-del.sh"
ADD_SCRIPT="$SCRIPT_DIR/db-add.sh"

for f in "$DEL_SCRIPT" "$ADD_SCRIPT"; do
  [[ -x "$f" ]] || { echo "ERROR: Cannot execute $f"; exit 1; }
done

echo "-> Dropping old DB & role"
"$DEL_SCRIPT" "$DB_USER" "$DB_NAME"

echo "-> Creating role & database"
"$ADD_SCRIPT" "$DB_USER" "$DB_NAME" "$DB_PASS"

# 6) Pre-create extensions found in dump (as postgres) to avoid permission issues when restoring as DB_USER
# (This is safe: CREATE EXTENSION IF NOT EXISTS ...)
echo "-> Pre-creating extensions found in dump (as postgres)"
EXTS="$(grep -E '^[[:space:]]*CREATE[[:space:]]+EXTENSION' "$DUMP_FILE" \
  | sed -E "s/.*CREATE[[:space:]]+EXTENSION([[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS)?[[:space:]]+\"?([a-zA-Z0-9_]+)\"?.*/\2/" \
  | sort -u || true)"

if [[ -n "${EXTS:-}" ]]; then
  while read -r ext; do
    [[ -n "$ext" ]] || continue
    echo "   - CREATE EXTENSION IF NOT EXISTS \"$ext\""
    psql_postgres_db "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS \"$ext\";"
  done <<< "$EXTS"
else
  echo "   (none found)"
fi

# 7) Sanitize dump to remove statements that break restores across different users/db names
SAN_DUMP="$TMP_DIR/dump.sanitized.sql"
echo "-> Sanitizing dump.sql (strip OWNER/GRANT/REVOKE/SET ROLE/\\connect/db-level cmds/extensions comments)"

awk '
  # db switching / db-level stuff
  /^[[:space:]]*\\connect[[:space:]]+/ {next}
  /^[[:space:]]*CREATE[[:space:]]+DATABASE[[:space:]]+/ {next}
  /^[[:space:]]*ALTER[[:space:]]+DATABASE[[:space:]]+/ {next}
  /^[[:space:]]*DROP[[:space:]]+DATABASE[[:space:]]+/ {next}

  # privileges / role-specific statements
  /[[:space:]]OWNER[[:space:]]+TO[[:space:]]+/ {next}
  /^[[:space:]]*GRANT[[:space:]]+/ {next}
  /^[[:space:]]*REVOKE[[:space:]]+/ {next}
  /^[[:space:]]*ALTER[[:space:]]+DEFAULT[[:space:]]+PRIVILEGES[[:space:]]+/ {next}
  /^[[:space:]]*SET[[:space:]]+(ROLE|SESSION[[:space:]]+AUTHORIZATION)[[:space:]]+/ {next}

  # extensions: already pre-created as postgres; also strip comments/ownership on extensions
  /^[[:space:]]*CREATE[[:space:]]+EXTENSION[[:space:]]+/ {next}
  /^[[:space:]]*COMMENT[[:space:]]+ON[[:space:]]+EXTENSION[[:space:]]+/ {next}
  /^[[:space:]]*ALTER[[:space:]]+EXTENSION[[:space:]]+/ {next}

  {print}
' "$DUMP_FILE" > "$SAN_DUMP"

# 8) Restore sanitized dump as DB_USER (so objects are owned by DB_USER)
echo "-> Restoring SQL dump into $DB_NAME as $DB_USER"
export PGPASSWORD="$DB_PASS"
psql -h localhost -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 < "$SAN_DUMP"
unset PGPASSWORD

# 9) Drop leftover Odoo signaling sequences as DB_USER (no postgres needed)
echo "-> Dropping leftover base_*_signaling* sequences (as $DB_USER)"
export PGPASSWORD="$DB_PASS"
psql -h localhost -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT sequence_schema, sequence_name
      FROM information_schema.sequences
     WHERE sequence_name LIKE 'base\_%signaling%'
  LOOP
    EXECUTE format(
      'DROP SEQUENCE IF EXISTS %I.%I CASCADE',
      r.sequence_schema, r.sequence_name
    );
  END LOOP;
END
$$;
SQL
unset PGPASSWORD

echo
echo "✅ Restore complete."
echo "   Start Odoo with:"
echo "   /opt/odoo/odoo18-ce/odoo-bin -c $ODOO_CONF"

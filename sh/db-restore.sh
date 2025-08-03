#!/usr/bin/env bash
set -euo pipefail

# restore-db.sh: Unzip + restore an Odoo DB + filestore in one go.

usage() {
  cat <<EOF
Usage: $0 <db_user> <db_name> <db_password> <backup_zip> [<odoo_conf>]

  <backup_zip> must contain:
    • dump.sql
    • filestore/            (Odoo filestore folder)

  [<odoo_conf>] defaults to /etc/odoo/odoo.conf if not provided.

The script will:
  1. Unzip into a temp dir.
  2. Move filestore → data_dir/filestore/<db_name>, preserving parent-owner.
  3. Remove data_dir/sessions & data_dir/addons if present.
  4. Drop & recreate DB & role (via del-db.sh + db.sh).
  5. psql-restore dump.sql.
  6. Drop leftover base_*_signaling* sequences.
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

# 1) Unzip backup
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "-> Unzipping $ZIP_FILE → $TMP_DIR"
unzip -q "$ZIP_FILE" -d "$TMP_DIR"

DUMP_FILE="$TMP_DIR/dump.sql"
FS_SRC="$TMP_DIR/filestore"

[[ -f "$DUMP_FILE" ]] || { echo "ERROR: dump.sql not found"; exit 1; }
[[ -d "$FS_SRC"  ]] || { echo "ERROR: filestore/ not found"; exit 1; }

# 2) Determine data_dir
if [[ -f "$ODOO_CONF" ]] && grep -q '^data_dir' "$ODOO_CONF"; then
  DATA_DIR=$(awk -F'=' '/^data_dir/ { gsub(/ /, "", $2); print $2 }' "$ODOO_CONF")
else
  DATA_DIR="/var/lib/odoo"
fi
echo "-> Using data_dir: $DATA_DIR"

# 3) Prepare filestore paths and owner
FS_PARENT_DIR="$DATA_DIR/filestore"
DEST_FS="$FS_PARENT_DIR/$DB_NAME"
sudo mkdir -p "$FS_PARENT_DIR"
read FS_OWNER FS_GROUP < <(stat -c '%U %G' "$FS_PARENT_DIR")
echo "-> filestore parent owned by: $FS_OWNER:$FS_GROUP"

# 4) Deploy filestore
echo "-> Deploy filestore → $DEST_FS"
sudo rm -rf "$DEST_FS"
sudo mv "$FS_SRC" "$DEST_FS"
sudo chown -R "$FS_OWNER":"$FS_GROUP" "$DEST_FS"

# 5) Clean up sessions & addons
for d in sessions addons; do
  [[ -d "$DATA_DIR/$d" ]] && { echo "-> Removing $DATA_DIR/$d"; sudo rm -rf "$DATA_DIR/$d"; }
done

# 6) Drop & recreate DB & role
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEL_SCRIPT="$SCRIPT_DIR/del-db.sh"
DB_SCRIPT="$SCRIPT_DIR/db.sh"

for f in "$DEL_SCRIPT" "$DB_SCRIPT"; do
  [[ -x "$f" ]] || { echo "ERROR: Cannot execute $f"; exit 1; }
done

echo "-> Dropping old DB & role"
"$DEL_SCRIPT" "$DB_USER" "$DB_NAME"

echo "-> Creating role & database"
"$DB_SCRIPT" "$DB_USER" "$DB_NAME" "$DB_PASS"

# 7) Restore SQL dump
echo "-> Restoring SQL dump into $DB_NAME"
export PGPASSWORD="$DB_PASS"
psql -h localhost -U "$DB_USER" -d "$DB_NAME" -f "$DUMP_FILE"

# 8) Drop any leftover Odoo “signaling” sequences
echo "-> Dropping leftover base_*_signaling* sequences"
sudo -u postgres psql -d "$DB_NAME" <<'SQL'
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

echo
echo "✅  Restore complete. You can now start Odoo with:"
echo "    /opt/odoo/odoo18-ce/odoo-bin -c $ODOO_CONF"

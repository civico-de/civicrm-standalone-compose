#!/usr/bin/env bash
# Replaces database and files with a backup written by backup.sh. Dumps the current database
# to backups/pre-restore-<timestamp>.sql.gz first. Usage: ./restore.sh backups/<timestamp>
set -euo pipefail
source=$(cd "${1:?usage: ./restore.sh backups/<timestamp>}" && pwd)
cd "$(dirname "$0")"
for f in database.sql.gz files.tar.gz; do
  [ -f "$source/$f" ] || { echo "Missing $source/$f" >&2; exit 1; }
done
# Read both archives completely, and keep them open so a pruning backup cannot remove them.
gzip -t "$source/database.sql.gz"
tar -tzf "$source/files.tar.gz" > /dev/null
exec 3< "$source/database.sql.gz" 4< "$source/files.tar.gz"

if [ -n "${SKIP_PRE_RESTORE_DUMP:-}" ]; then
  current="nowhere (SKIP_PRE_RESTORE_DUMP was set)"
else
  current="backups/pre-restore-$(date +%Y-%m-%d_%H%M%S).sql.gz"
  mkdir -p backups
  docker compose exec -T db sh -c \
    'MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump --single-transaction --routines --triggers -u "$MARIADB_USER" "$MARIADB_DATABASE"' \
    | gzip > "$current" || {
    rm -f "$current"
    echo "Could not dump the current database, nothing changed. If it is beyond saving, run again with SKIP_PRE_RESTORE_DUMP=1." >&2
    exit 1
  }
fi

trap 'echo "Restore failed. CiviCRM stays stopped; fix the cause and run the restore again. The database before the restore is in $current." >&2' ERR
docker compose stop app cron
docker compose exec -T db sh -c \
  'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u "$MARIADB_USER" -e "DROP DATABASE $MARIADB_DATABASE; CREATE DATABASE $MARIADB_DATABASE"'
gunzip -c <&3 | docker compose exec -T db sh -c \
  'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u "$MARIADB_USER" "$MARIADB_DATABASE"'
docker compose run --rm --no-deps -T --user www-data --entrypoint sh app \
  -c 'find private public ext -mindepth 1 -delete && tar -xzf -' <&4
trap - ERR

docker compose start app cron
docker compose exec -T --user www-data app cv flush
echo "Restored $source"

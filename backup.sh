#!/usr/bin/env bash
# Writes backups/<timestamp>/ with a database dump and the private, public and ext files,
# then deletes backups older than KEEP_DAYS (default 14). Usage: ./backup.sh
set -euo pipefail
cd "$(dirname "$0")"

target="backups/$(date +%Y-%m-%d_%H%M%S)"
mkdir -p backups
# Without -p, so a second run in the same second stops here instead of sharing the directory.
mkdir "$target"
trap 'rm -rf "$target"; echo "Backup failed, nothing kept." >&2; exit 1' ERR INT TERM

docker compose exec -T db sh -c \
  'MYSQL_PWD="$MARIADB_PASSWORD" mariadb-dump --single-transaction --routines --triggers -u "$MARIADB_USER" "$MARIADB_DATABASE"' \
  | gzip > "$target/database.sql.gz"
docker compose exec -T app tar -C /var/www/html --exclude=private/cache --exclude=private/tmp \
  -czf - private public ext > "$target/files.tar.gz"
trap - ERR INT TERM

find backups -mindepth 1 -maxdepth 1 -type d -mtime +"${KEEP_DAYS:-14}" -exec rm -rf {} +
echo "$target"

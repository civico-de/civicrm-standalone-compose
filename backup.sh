#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 civico GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later
# Writes backups/<timestamp>/ with a database dump, the private, public and ext files and a
# copy of .env, then deletes backups older than KEEP_DAYS (default 14). Usage: ./backup.sh
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
docker compose exec -T app tar -C /var/www/html --exclude=private/cache --exclude=private/filecache --exclude=private/tmp \
  -czf - private public ext > "$target/files.tar.gz"
# CIVICRM_VERSION in it names the code the dump belongs to. COMPOSE_ENV_FILES is set by the tests.
cp "${COMPOSE_ENV_FILES:-.env}" "$target/env"
trap - ERR INT TERM

find backups -mindepth 1 -maxdepth 1 -type d -mtime +"${KEEP_DAYS:-14}" -exec rm -rf {} +
echo "$target"

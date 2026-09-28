#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 civico GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later
# Writes a backup, sets CIVICRM_VERSION in .env, pulls the images, updates the database while
# CiviCRM is stopped, then starts everything again.
# Usage: ./upgrade.sh [minor line, e.g. 6.19]; without one, the newest patch of the current line.
set -euo pipefail
cd "$(dirname "$0")"
env_file=${COMPOSE_ENV_FILES:-.env}

backup=$(./backup.sh)
echo "Backup written to $backup"
if [ -n "${1:-}" ]; then
  sed -i.bak "s/^CIVICRM_VERSION=.*/CIVICRM_VERSION=$1/" "$env_file" && rm -f "$env_file.bak"
fi

trap 'cp "$backup/env" "$env_file"; echo "Could not pull the images. Nothing changed." >&2' ERR
docker compose pull
trap 'echo "Upgrade failed. CiviCRM stays stopped. To go back to the version before, run ./restore.sh $backup" >&2' ERR
docker compose stop app cron
docker compose run --rm --no-deps -T --user www-data app cv upgrade:db
trap - ERR

docker compose up --detach --wait
echo "Upgraded. To go back to the version before, run ./restore.sh $backup"

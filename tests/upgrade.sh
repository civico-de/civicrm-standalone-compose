#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 civico GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later
# Installs an older CiviCRM, upgrades it with ./upgrade.sh to the version in tests/test.env,
# then goes back with ./restore.sh. Removes its containers and volumes when done.
# Usage: [MARIADB_FROM=<tag>] tests/upgrade.sh [from-version], default: the minor line before
# the pinned one. MARIADB_FROM installs on an older MariaDB, which the upgrade replaces.
set -euo pipefail
cd "$(dirname "$0")/.."
to=$(sed -n 's/^CIVICRM_VERSION=//p' tests/test.env)
from=${1:-${to%.*}.$((${to#*.} - 1))}
export COMPOSE_PROJECT_NAME=civicrm-standalone-compose-upgrade-test
export COMPOSE_FILE=compose.yaml:tests/compose.test.yaml
db_to=$(sed -n 's/^ *image: mariadb://p' compose.yaml)
db_from=${MARIADB_FROM:-$db_to}
older_db=$(mktemp)
printf 'services:\n  db:\n    image: mariadb:%s\n' "$db_from" > "$older_db"
# A settings file of its own, as .env is on a server: the upgrade edits it, the restore reverts it.
COMPOSE_ENV_FILES=$(mktemp) && export COMPOSE_ENV_FILES
sed "s/^CIVICRM_VERSION=.*/CIVICRM_VERSION=$from/" tests/test.env > "$COMPOSE_ENV_FILES"
failures=0
backup=""

cleanup() {
  docker compose down --volumes --remove-orphans > /dev/null 2>&1 || true
  [ -z "$backup" ] || rm -rf "$backup"
  rm -f "$COMPOSE_ENV_FILES" "$older_db"
}
trap cleanup EXIT
docker compose down --volumes --remove-orphans > /dev/null 2>&1

check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
}
# Prints the database version and the code version.
versions() { docker compose exec -T --user www-data app cv php:eval 'echo CRM_Core_BAO_Domain::version(), " ", CRM_Utils_System::version();'; }
db_server() { docker compose exec -T db mariadb --version | grep -o '[0-9]*\.[0-9]*\.[0-9]*' | head -1; }
on_line() { grep -c "^$1\." <<< "$2" || true; }
event_list() { curl -sk -o /dev/null -w '%{http_code}' https://localhost:8443/civicrm/event/list; }
backup_of() { sed -n 's/^Backup written to //p' <<< "$1"; }

COMPOSE_FILE=$COMPOSE_FILE:$older_db docker compose up --detach --wait
read -r db_version code_version <<< "$(versions)"
check "installed the older line $from" 1 "$(on_line "$from" "$code_version")"
check "installed MariaDB $db_from" 1 "$(on_line "$db_from" "$(db_server)")"

stopped=""
refused=$(./upgrade.sh no-such-version 2> /dev/null) || stopped=1
rm -rf "$(backup_of "$refused")"
check "a missing image stops the upgrade" 1 "$stopped"
check "the refused upgrade left the settings alone" "CIVICRM_VERSION=$from" "$(grep '^CIVICRM_VERSION=' "$COMPOSE_ENV_FILES")"
check "CiviCRM still runs after the refused upgrade" 200 "$(event_list)"

# Standard input stays open, as in a terminal: the upgrade must not wait for an answer.
output=$(./upgrade.sh "$to" < <(sleep 3600))
backup=$(backup_of "$output")
check "the upgrade wrote a complete backup first" 1 \
  "$([ -s "$backup/database.sql.gz" ] && [ -s "$backup/files.tar.gz" ] && [ -s "$backup/env" ] && echo 1)"
read -r db_version code_version <<< "$(versions)"
check "code runs the pinned line $to" 1 "$(on_line "$to" "$code_version")"
check "database matches the code" "$code_version" "$db_version"
check "MariaDB runs $db_to" 1 "$(on_line "$db_to" "$(db_server)")"
check "cron runs the new image" 1 "$(on_line "$to" "$(docker compose exec -T cron cv php:eval 'echo CRM_Utils_System::version();')")"
check "CiviCRM answers after the upgrade" 200 "$(event_list)"

read -r _ _ _ pre_restore_db _ pre_restore_env <<< "$(./restore.sh "$backup" | grep '^Before the restore: ')"
rm -f "$pre_restore_db" "$pre_restore_env"
read -r db_version code_version <<< "$(versions)"
check "restore brings back the older line $from" 1 "$(on_line "$from" "$code_version")"
check "restore brings back the matching database" "$code_version" "$db_version"
check "restore brings back the older version in the settings" "CIVICRM_VERSION=$from" "$(grep '^CIVICRM_VERSION=' "$COMPOSE_ENV_FILES")"
check "CiviCRM answers after going back" 200 "$(event_list)"

if [ "$failures" != 0 ]; then echo "$failures check(s) failed."; exit 1; fi
echo "All checks passed."

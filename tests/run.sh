#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 civico GmbH
# SPDX-License-Identifier: AGPL-3.0-or-later
# End-to-end check on https://localhost:8443: install, language, cron, public routes, every
# profile with an anonymous visitor, backup and restore. Removes its containers and volumes when done. Usage: tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export COMPOSE_PROJECT_NAME=civicrm-standalone-compose-test
export COMPOSE_FILE=compose.yaml:tests/compose.test.yaml
export COMPOSE_ENV_FILES=tests/test.env
base=https://localhost:8443
failures=0
backup=""
body=$(mktemp)
# The restore check edits tests/test.env; this copy puts it back whatever happens.
settings=$(mktemp) && cp tests/test.env "$settings"

cleanup() {
  docker compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  [ -z "$backup" ] || rm -rf "$backup"
  cp "$settings" tests/test.env
  rm -f "$body" "$settings"
}
trap cleanup EXIT
docker compose down --volumes --remove-orphans > /dev/null 2>&1

check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; failures=$((failures + 1)); fi
}
cv() { docker compose exec -T --user www-data app cv "$@"; }
# Prints "blocked" when Caddy refused the request, else the status CiviCRM answered with.
# Arguments: path, method (default GET), one extra header.
route() {
  local status args=(-sk --path-as-is -X "${2:-GET}" -H 'X-Requested-With: XMLHttpRequest')
  [ -z "${3:-}" ] || args+=(-H "$3")
  status=$(curl "${args[@]}" -o "$body" -w '%{http_code}' "$base$1")
  if [ "$status" = 403 ] && [ "$(cat "$body")" = Forbidden ]; then echo blocked; else echo "$status"; fi
}
# Opens a CiviCRM form as a new visitor, submits it with the given field=value pairs and
# prints the URL the visitor ends up on.
submit_form() {
  local url=$1 jar key args=()
  shift
  jar=$(mktemp)
  curl -sk -c "$jar" -o "$body" "$base$url"
  key=$(grep -oE 'name="qfKey"[^>]*value="[^"]+"' "$body" | sed -E 's/.*value="([^"]+)"/\1/')
  for field in "qfKey=$key" "$@"; do args+=(--data-urlencode "$field"); done
  curl -sk -b "$jar" -c "$jar" -L -o "$body" -w '%{url_effective}' "$base${url%%\?*}" "${args[@]}"
  rm -f "$jar"
}
# Prints 1 when the request got past Caddy, whatever CiviCRM answered.
reaches() { [ "$(route "$@")" != blocked ] && echo 1; }
count() { cv api4 "$1.get" "{\"select\":[\"id\"],\"where\":$2}" | grep -c '"id"' || true; }
signups() { count Contact '[["source","=","test-signup"]]'; }

docker compose up --detach --wait
check "second start skips the install" "CiviCRM is installed." "$(docker compose run --rm -T init)"
check "language" "1" "$(cv api4 Setting.get '{"select":["lcMessages"]}' | grep -c '"value": "de_DE"')"

for _ in $(seq 30); do grep -q 'cron run' <<< "$(docker compose logs cron)" && break; sleep 2; done
cron_log=$(docker compose logs cron)
check "cron container finished a run" 1 "$(grep -q 'cron run finished' <<< "$cron_log" && echo 1)"
check "cron container reports no failure" 0 "$(grep -c 'cron run failed' <<< "$cron_log" || true)"
check "scheduled jobs wrote a log" 1 "$(cv api4 JobLog.get '{"select":["id"],"where":[["name","=","CiviCRM Update Check"]],"limit":1}' | grep -c '"id"')"

check "cv uses the file cache" FileCache "$(cv ev 'echo CIVICRM_DB_CACHE_CLASS;')"
check "cron uses the file cache" FileCache "$(docker compose exec -T cron cv ev 'echo CIVICRM_DB_CACHE_CLASS;')"
# With cron paused, only the web request can fill the emptied cache directory.
docker compose pause cron > /dev/null
docker compose exec -T --user www-data app rm -rf private/filecache
route /civicrm/event/list > /dev/null
check "the web server uses the file cache" 1 \
  "$(docker compose exec -T app find private/filecache -name '*.txt' | grep -q . && echo 1)"
docker compose unpause cron > /dev/null

cv api4 Afform.create --in=json < tests/afform.json > /dev/null
docker compose cp tests/fixtures.php app:/tmp/fixtures.php
read -r event page processor price_field price_option self_service recur_link api_contact \
  < <(cv php:script /tmp/fixtures.php)
# The way docs/profiles.md sets an API key.
cv api4 Contact.update +w "id=$api_contact" +v api_key=test-api-key-0123456789 > /dev/null
for path in /civicrm/login /civicrm/dashboard /core/extern/soap.php /core/vendor/autoload.PHP \
  /core/extern/soap.php/x /core/vendor/autoload.php/ '/core/extern/soap%2Ephp/x' /ext/../private/civicrm.settings.php; do
  check "GET $path is blocked" blocked "$(route "$path")"
done
for path in /civicrm/ajax/rest /civicrm/ajax/api4/Contact/get /civicrm/ajax/api4/Afform/submit/x \
  /civicrm/ajax/api4/Afform/submit/../../Contact/get '/civicrm/ajax/api4/Afform%2Fsubmit%2F..%2F..%2FContact%2Fget' \
  //civicrm/ajax/api4/Contact/get /civicrm/form/../ajax/api4/Contact/get; do
  check "POST $path is blocked" blocked "$(route "$path" POST)"
done
check "form page is public" 200 "$(route /civicrm/form/test-signup)"
for path in /civicrm/ajax/api4/Afform/prefill /civicrm/ajax/api4/Afform/submitFile; do
  check "forms profile: POST $path reaches CiviCRM" 1 "$(reaches "$path" POST)"
done
for link in url open view unsubscribe optout confirm resubscribe; do
  check "civimail profile: /civicrm/mailing/$link reaches CiviCRM" 1 "$(reaches "/civicrm/mailing/$link")"
done
check "civimail profile: /civicrm/mosaico/img reaches CiviCRM" 1 "$(reaches /civicrm/mosaico/img)"

assets=$(curl -sk "$base/civicrm/form/test-signup" | grep -oE "(src|href)=\"$base/[^\"]+\"" |
  sed -E "s#^(src|href)=\"$base##; s/\"\$//; s/&amp;/\&/g" | sort -u)
check "form page references generated assets" 1 "$(grep -q '^/civicrm/asset/builder' <<< "$assets" && echo 1)"
check "every script and style the form page references loads" "" \
  "$(while read -r url; do [ "$(route "$url")" = 200 ] || echo "$url"; done <<< "$assets")"

before=$(signups)
curl -sk -X POST -H 'X-Requested-With: XMLHttpRequest' "$base/civicrm/ajax/api4/Afform/submit" --data-urlencode \
  'params={"name":"afformTestSignup","values":{"Individual1":[{"fields":{"first_name":"Form","last_name":"Test"},"joins":{"Email":[{"email":"form@example.org"}]}}]}}' > /dev/null
check "anonymous form submission creates a contact" "$((before + 1))" "$(signups)"

for path in /civicrm/event/list "/civicrm/event/info?reset=1&id=$event" "/civicrm/event/ical?reset=1&id=$event" \
  "/civicrm/event/register?reset=1&id=$event" "/civicrm/ajax/jqState?_value=1082"; do
  check "events profile: $path is public" 200 "$(route "$path")"
done
check "events profile: waitlist and approval links reach CiviCRM" 1 "$(reaches /civicrm/event/confirm)"
check "event participant lists stay closed" blocked "$(route /civicrm/event/participant)"
for form in SelfSvcUpdate SelfSvcTransfer; do
  path="/civicrm/event/$(tr '[:upper:]' '[:lower:]' <<< "$form")?reset=1&is_backoffice=0&$self_service"
  check "events profile: the mail link for $form opens its form" "200 1" "$(route "$path") $(grep -c "name=\"_qf_${form}_submit\"" "$body")"
done
before=$(count Participant "[[\"event_id\",\"=\",$event]]")
check "anonymous event registration reaches the thank-you page" 1 "$(submit_form "/civicrm/event/register?reset=1&id=$event" \
  email-Primary=visitor@example.org _qf_default=Register:upload _qf_Register_upload=1 | grep -c _qf_ThankYou_display)"
check "the registration was saved" "$((before + 1))" "$(count Participant "[[\"event_id\",\"=\",$event]]")"

check "contribution page is public" 200 "$(route "/civicrm/contribute/transact?reset=1&id=$page")"
check "billing block loads" 200 "$(route "/civicrm/payment/form?formName=Main&processor_id=$processor&currency=EUR")"
check "billing block asks for the card" 1 "$(grep -c 'name="credit_card_number"' "$body")"
check "payment notifications reach the processor" 200 "$(route "/civicrm/payment/ipn/$processor" POST)"
check "payment notifications by processor name reach it" 200 "$(route "/civicrm/payment/ipn?processor_name=Dummy" POST)"
for link in unsubscribe:CancelSubscription updatebilling:UpdateBilling updaterecur:UpdateSubscription; do
  check "contributions profile: the receipt link ${link%%:*} opens its form" "200 1" \
    "$(route "/civicrm/contribute/${link%%:*}?reset=1&$recur_link") $(grep -c "name=\"_qf_${link#*:}_submit\"" "$body")"
done
check "contributions profile: the subscription status page is public" 200 "$(route /civicrm/contribute/subscriptionstatus)"
for path in /civicrm/contribute /civicrm/payment/view /civicrm/payment/edit; do
  check "GET $path is blocked" blocked "$(route "$path")"
done
check "anonymous donation reaches the thank-you page" 1 "$(submit_form "/civicrm/contribute/transact?reset=1&id=$page" \
  email-5=donor@example.org "price_$price_field=$price_option" payment_processor_id=0 _qf_default=Main:upload _qf_Main_upload=1 |
  grep -c _qf_ThankYou_display)"
check "the donation was saved" 1 "$(count Contribution "[[\"contribution_page_id\",\"=\",$page]]")"

key='X-Civi-Auth: Bearer test-api-key-0123456789'
check "api profile: the key reads events" 200 "$(route /civicrm/ajax/api4/Event/get POST "$key")"
check "api profile: the answer holds the test event" 1 "$(grep -c "\"id\":$event," "$body")"
check "api profile: the key's role decides, not the proxy" 403 "$(route /civicrm/ajax/api4/Event/create POST "$key")"
check "api profile: a wrong key is refused" 401 "$(route /civicrm/ajax/api4/Event/get POST 'X-Civi-Auth: Bearer wrong')"
for header in 'X-Civi-Auth;' 'X-Civi-Auth: Bearer ' 'X-Civi-Auth: test-api-key-0123456789'; do
  check "api profile: header '$header' is blocked" blocked "$(route /civicrm/ajax/api4/Event/get POST "$header")"
done
check "api profile: APIv3 stays closed" blocked "$(route /civicrm/ajax/rest POST "$key")"

check "admin address reaches the login" 200 "$(docker compose exec -T caddy wget -q -S --no-check-certificate -O /dev/null "$base/civicrm/login" 2>&1 | awk '/HTTP\//{print $2}' | tail -1)"
cookies=$(curl -sk -D - -o /dev/null "$base/civicrm/form/test-signup" | grep -i '^set-cookie:')
check "form page sets the session cookie" 1 "$(grep -c '^[Ss]et-[Cc]ookie: SESSCIVISO=' <<< "$cookies")"
check "every cookie is Secure" 0 "$(grep -vci '; secure' <<< "$cookies" || true)"

PUBLIC_PROFILES=events docker compose up --detach --wait caddy
check "events alone: state lists are public" 200 "$(route "/civicrm/ajax/jqState?_value=1082")"
check "events alone: county lists reach CiviCRM" 1 "$(reaches /civicrm/ajax/jqCounty)"
check "events alone: contribution pages are blocked" blocked "$(route "/civicrm/contribute/transact?reset=1&id=$page")"
PUBLIC_PROFILES=contributions docker compose up --detach --wait caddy
check "contributions alone: state lists are public" 200 "$(route "/civicrm/ajax/jqState?_value=1082")"
check "contributions alone: county lists reach CiviCRM" 1 "$(reaches /civicrm/ajax/jqCounty)"
check "contributions alone: event pages are blocked" blocked "$(route "/civicrm/event/info?reset=1&id=$event")"
PUBLIC_PROFILES=forms docker compose up --detach --wait caddy
check "civimail profile off: mail links are blocked" blocked "$(route /civicrm/mailing/view)"
check "events profile off: event pages are blocked" blocked "$(route "/civicrm/event/info?reset=1&id=$event")"
check "contributions profile off: contribution pages are blocked" blocked "$(route "/civicrm/contribute/transact?reset=1&id=$page")"
check "api profile off: the key gets nowhere" blocked "$(route /civicrm/ajax/api4/Event/get POST "$key")"
PUBLIC_PROFILES='' docker compose up --detach --wait caddy
check "no profiles: forms are blocked" blocked "$(route /civicrm/form/test-signup)"
PUBLIC_PROFILES=nosuchprofile docker compose up --detach --wait --wait-timeout 15 caddy 2> /dev/null || true
caddy_log=$(docker compose logs caddy)
check "unknown profile stops Caddy" 1 "$(grep -q 'File to import not found: .*nosuchprofile.caddy' <<< "$caddy_log" && echo 1)"
docker compose up --detach --wait caddy

before=$(signups)
backup=$(./backup.sh)
check "the backup holds the settings" "" "$(diff "$backup/env" tests/test.env)"
check "the backup leaves out the file cache" 0 "$(tar -tzf "$backup/files.tar.gz" | grep -c '^private/filecache' || true)"
cv api4 Contact.create '{"values":{"contact_type":"Individual","first_name":"After","last_name":"Backup","source":"test-signup"}}' > /dev/null
echo "# changed after the backup" >> tests/test.env
broken="$backup-broken" && mkdir "$broken" && cp "$backup/files.tar.gz" "$backup/env" "$broken/"
head -c 20000 "$backup/database.sql.gz" > "$broken/database.sql.gz"
check "restore refuses a truncated backup" 1 "$(./restore.sh "$broken" > /dev/null 2>&1 || echo 1)"
rm -rf "$broken"
check "refused restore left the data alone" "$((before + 1))" "$(signups)"
check "refused restore left the settings alone" 1 "$(grep -c '^# changed after the backup$' tests/test.env)"
read -r _ _ _ pre_restore_db _ pre_restore_env <<< "$(./restore.sh "$backup" | grep '^Before the restore: ')"
check "restore returns to the backed-up state" "$before" "$(signups)"
check "restore puts the backed-up settings back" "" "$(diff "$backup/env" tests/test.env)"
check "restore kept the replaced database" 1 "$(gunzip -c "$pre_restore_db" | grep -c 'Dump completed')"
check "restore kept the replaced settings" 1 "$(grep -c '^# changed after the backup$' "$pre_restore_env")"
rm -f "$pre_restore_db" "$pre_restore_env"
check "form page works after restore" 200 "$(route /civicrm/form/test-signup)"

if [ "$failures" != 0 ]; then echo "$failures check(s) failed."; exit 1; fi
echo "All checks passed."

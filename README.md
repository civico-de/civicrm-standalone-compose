# civicrm-standalone-compose

Self-host CiviCRM Standalone with Docker Compose. One command installs CiviCRM in the
language you choose, serves it over HTTPS, runs the scheduled jobs and opens exactly the
public routes you enable. Three scripts write and restore backups and upgrade CiviCRM.

There is no image of its own and no build step: the setup is a Compose file, some Caddy and
Apache configuration and three shell scripts on top of the `civicrm/civicrm`, `mariadb` and
`caddy` images.

## Quick start

You need a server with Docker, a DNS name pointing at it and ports 80 and 443 open.

```sh
git clone https://github.com/civico-de/civicrm-standalone-compose.git civicrm && cd civicrm
cp .env.example .env
$EDITOR .env                  # DOMAIN, ADMIN_IPS, ADMIN_PASSWORD, DB_PASSWORD
docker compose up -d
```

The first start installs CiviCRM, which takes about half a minute. Then open
`https://<DOMAIN>/civicrm/login` from an address in `ADMIN_IPS`.

## What runs

| Service | Image | Job |
|---|---|---|
| `db` | `mariadb:11.4` | The database |
| `init` | `civicrm/civicrm` | Installs CiviCRM on the first start, then exits. Later starts find the settings file and skip. |
| `app` | `civicrm/civicrm` | CiviCRM behind Apache. Has no public port. |
| `cron` | `civicrm/civicrm` | Runs `cv core:cron` every five minutes: mailings, reminders, clean-up |
| `caddy` | `caddy:2` | TLS from Let's Encrypt, and the only way in |

Persistent data lives in named volumes: `db` for the database, and `private`, `public` and
`ext` for settings, uploads and extensions.

## Configuration

Everything is in `.env`. Compose refuses to start while a required value is missing.

| Variable | Meaning |
|---|---|
| `DOMAIN` | Host name. Caddy requests the certificate for it. |
| `ADMIN_IPS` | Addresses that reach login, back office and APIv3, as CIDRs separated by spaces. `0.0.0.0/0 ::/0` opens them to everyone. |
| `PUBLIC_PROFILES` | Features open to everyone, see below. Empty means none. |
| `CIVICRM_VERSION` | Tag of `civicrm/civicrm`. A minor line such as `6.18` receives its patch releases. |
| `CIVICRM_LANG` | Language of the installation, for example `de_DE`, `fr_FR` or `en_US`. The installer downloads the translation. |
| `ADMIN_USER`, `ADMIN_EMAIL`, `ADMIN_PASSWORD` | The first administrator |
| `DB_PASSWORD` | Database password. Use `openssl rand -hex 24`: the installer writes it into a database URL, where some special characters break. |

`CIVICRM_LANG` and the admin values are read only by the first start. The installer also
writes `DOMAIN` and `DB_PASSWORD` into `private/civicrm.settings.php`. To change either
later, edit that file as well.

## Public access

Caddy lets through the static files and the routes of the profiles in `PUBLIC_PROFILES`.
Everything else, including the login, answers only to `ADMIN_IPS`. Anonymous visitors
reach single APIv4 actions at most, and APIv3 stays closed to everyone outside `ADMIN_IPS`.

| Profile | Opens | Use it for |
|---|---|---|
| `forms` | Pages under `/civicrm/form/` and the APIv4 actions FormBuilder forms submit to | Public FormBuilder forms: sign-ups, contact forms, petitions |
| `civimail` | Tracking, view in browser, unsubscribe, opt-out and confirmation links, Mosaico images | Sending mailings with CiviMail |
| `events` | Event list and pages, registration, iCalendar feed, the links in event mails | Online event registration |
| `contributions` | Contribution pages, billing block, payment notifications, links for recurring contributions | Online donations and payments |
| `api` | All of APIv4, only for requests with an `X-Civi-Auth: Bearer <API key>` header | Other systems that read or write through the API |

A profile only decides which requests reach CiviCRM; CiviCRM's permissions still decide
what a visitor may do. Event and contribution forms with profiles need the permission
*profile create* for anonymous visitors, which Standalone does not grant by default.

A profile is one short file in `caddy/profiles/`, so you can add your own, for example
one that opens a single APIv4 action. [docs/profiles.md](docs/profiles.md) describes each
profile, what to set up in CiviCRM, and how to write and test your own.

## Operations

```sh
docker compose logs -f app                           # Apache and PHP
docker compose exec -u www-data app cv api4 System.check   # any cv command
docker compose restart caddy                         # after editing caddy/
docker compose up -d                                 # after editing .env
```

### Backups

`./backup.sh` writes `backups/<timestamp>/` with `database.sql.gz`, `files.tar.gz`
(`private`, `public`, `ext`) and `env`, a copy of `.env`, and deletes backups older than 14 days (`KEEP_DAYS`). If a
step fails, nothing is kept and the script exits non-zero. Run it nightly from the host's
crontab:

```
30 2 * * * cd /path/to/civicrm && ./backup.sh > /dev/null
```

CiviCRM keeps running during a backup. The database is dumped first and the files are
archived right after, so an upload or deletion in those seconds can leave one attachment out
of step with the database.

`./restore.sh backups/<timestamp>` reads both archives completely and keeps the current
database and `.env` as `backups/pre-restore-<timestamp>.sql.gz` and `.env`, so data entered
since the backup is not lost for good. Files uploaded since the backup are replaced without a
copy. Then it stops CiviCRM, replaces the database, the files and `.env`, starts CiviCRM again
with the images that `.env` names and flushes the caches. If a
step fails, CiviCRM stays stopped and the script says why. When the current database cannot
be dumped at all, `SKIP_PRE_RESTORE_DUMP=1` skips that step.

The backups stay on the same server. Copy `backups/` somewhere else, and keep that copy as
safe as `.env` itself: every backup holds its passwords.

### Upgrades

```sh
./upgrade.sh          # newest patch of the minor line in .env
./upgrade.sh 6.19     # the next minor line
```

`upgrade.sh` writes a backup, sets `CIVICRM_VERSION` in `.env` if you name a line, and pulls
the images. If an image cannot be pulled, it puts `.env` back and stops; CiviCRM keeps
running. Otherwise it stops CiviCRM, updates the database with `cv upgrade:db` and starts
everything again. If the database update fails, CiviCRM stays stopped. Either way the script
names the backup that `./restore.sh` takes you back to the version before.

Change `CIVICRM_VERSION` through `upgrade.sh` rather than by hand, so each backup records the
version its database belongs to. Read the release notes before you change the minor line, and
move one line at a time.

## Tests

`tests/run.sh` starts the stack on `https://localhost:8443` with `tests/test.env`, then
checks:

- the install, the language and the cron container;
- blocked and open routes, including path and encoding tricks;
- the scripts and styles a public form references;
- every profile, switched on and off, with an anonymous visitor, who submits a form,
  registers for an event and makes a donation;
- the API with a valid key, a wrong key and malformed headers;
- cookies marked Secure;
- a backup and restore round trip.

`tests/fixtures.php` creates the records these checks use. `tests/upgrade.sh` installs the
minor line before the pinned one, upgrades it with `upgrade.sh` and goes back with
`restore.sh`. Both scripts remove their containers and volumes afterwards.

GitHub Actions runs them on every push and weekly, against the pinned `CIVICRM_VERSION` and
against `latest`. Dependabot proposes newer versions of the other images and of the actions.

## No warranty: running it is up to you

This setup comes without any warranty, and we accept no liability for its use, as far as
the law allows. Sections 15 and 16 of the [license](LICENSE) apply. You run it at your own
risk.

Keeping it up to date is your job. Nothing updates itself: CiviCRM security releases and
new versions of MariaDB and Caddy reach your server only when you run `./upgrade.sh`
(see [Upgrades](#upgrades)). Follow [CiviCRM's security announcements](https://civicrm.org/security)
to know when one is due. The server's operating system, Docker and firewall are yours to
maintain as well.

It is also deliberately basic. It does not copy backups off the server, test restores,
watch the instance, filter request bodies, put the back office behind a VPN, or rehearse
upgrades on a copy of the data first.

For production data, work with an experienced hosting partner such as
[civico](https://civico.de), who takes care of all of this for you.

## License

Copyright © 2026 civico GmbH. Licensed under the [GNU Affero General Public License
v3.0 or later](LICENSE).

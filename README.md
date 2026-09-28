# civicrm-compose

CiviCRM Standalone with Docker Compose, built only from official images: `civicrm/civicrm`,
`mariadb` and `caddy`. One command installs CiviCRM in the language you choose, serves it
over HTTPS, runs the scheduled jobs and opens exactly the public routes you enable. Two
scripts write and restore backups.

It is meant to be read. Every file is short, and nothing is built.

## Quick start

You need a server with Docker, a DNS name pointing at it and ports 80 and 443 open.

```sh
git clone <this repository> civicrm && cd civicrm
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

`./backup.sh` writes `backups/<timestamp>/` with `database.sql.gz` and `files.tar.gz`
(`private`, `public`, `ext`) and deletes backups older than 14 days (`KEEP_DAYS`). If a
step fails, nothing is kept and the script exits non-zero. Run it nightly from the host's
crontab:

```
30 2 * * * cd /path/to/civicrm && ./backup.sh > /dev/null
```

CiviCRM keeps running during a backup. The database is dumped first and the files are
archived right after, so an upload or deletion in those seconds can leave one attachment out
of step with the database.

`./restore.sh backups/<timestamp>` reads both archives completely and dumps the current
database to `backups/pre-restore-<timestamp>.sql.gz`, so data entered since the backup is not
lost for good. Files uploaded since the backup are replaced without a copy. Then it stops CiviCRM, replaces the database and the files, starts it again and
flushes the caches. If a step fails, CiviCRM stays stopped and the script says why. When the
current database cannot be dumped at all, `SKIP_PRE_RESTORE_DUMP=1` skips that step.

The backups stay on the same server. Copy `backups/` somewhere else, together with `.env`:
the restored settings file expects the same `DOMAIN` and `DB_PASSWORD`.

### Upgrades

```sh
./backup.sh
$EDITOR .env                                         # CIVICRM_VERSION=<next minor>
docker compose pull
docker compose stop app cron                         # no requests against the old schema
docker compose run --rm --no-deps --user www-data app cv upgrade:db
docker compose up -d
```

Read the release notes before you change the minor line, and move one line at a time.

## Tests

`tests/run.sh` starts the stack on `https://localhost:8443` with `tests/test.env`, then
checks:

- the install, the language and the cron container;
- blocked and open routes, including path and encoding tricks;
- the scripts and styles a public form references;
- every profile, switched on and off, with an anonymous visitor, who submits a form,
  registers for an event and makes a donation;
- the API with a valid key, a wrong key and malformed headers;
- Secure cookies;
- a backup and restore round trip.

`tests/fixtures.php` creates the records these checks use. The script
removes its containers and volumes afterwards.

## No warranty: running it is up to you

This setup comes without any warranty, and we accept no liability for its use, as far as
the law allows. Sections 15 and 16 of the [license](LICENSE) apply. You run it at your own
risk.

Keeping it up to date is your job. Nothing updates itself: CiviCRM security releases and
new versions of MariaDB and Caddy reach your server only when you run the steps under
[Upgrades](#upgrades), for a patch release with `CIVICRM_VERSION` unchanged. Follow
[CiviCRM's security announcements](https://civicrm.org/security) to know when one is due.
The server's operating system, Docker and firewall are yours to maintain as well.

It is also deliberately basic. It does not copy backups off the server, test restores,
watch the instance, filter request bodies, put the back office behind a VPN, or rehearse
upgrades on a copy of the data first.

For production data, work with an experienced hosting partner such as
[civico](https://civico.de), who takes care of all of this for you.

## License

[AGPL-3.0](LICENSE)

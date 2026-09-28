# civicrm-standalone-compose

Self-host CiviCRM Standalone with Docker Compose. One command installs CiviCRM in the
language you choose, serves it over HTTPS, runs the scheduled jobs and opens exactly the
public routes you enable. Three scripts write and restore backups and upgrade CiviCRM.

There is no image of its own and no build step: the setup is a Compose file, some Caddy,
Apache and PHP configuration and three shell scripts on top of the `civicrm/civicrm`,
`mariadb` and `caddy` images.

## Why Standalone

Standalone is CiviCRM without a content management system: no Drupal, WordPress, Joomla or
Backdrop underneath. That takes a large attack surface out of the stack. A CMS brings its own
logins, plugins and themes, each with its own security releases: in 2025 alone,
[Patchstack counted 11,334 new vulnerabilities](https://patchstack.com/whitepaper/state-of-wordpress-security-in-2026/)
in the WordPress ecosystem, 91% of them in plugins. With Standalone:

- One system to run and patch instead of two, with no CMS updates, modules or conflicts
  between two release cycles.
- Users, roles, permissions and two-factor login are built in.
- Public forms, event registration and donation pages come from FormBuilder and CiviCRM
  itself.
- Upgrades are supported, and regressions are fixed as on the CMS versions.
- It is what the official `civicrm/civicrm` Docker image ships.

Your website runs separately on its own CMS and usually exchanges data with CiviCRM through
APIv4 (see the `api` profile below), so a hole in the website no longer sits next to your
contact data. Sign-up, event and donation forms can also come straight from CiviCRM.

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

PHP settings and CiviCRM constants that `.env` does not cover live in `php/`, see
[docs/php.md](docs/php.md). One of them makes CiviCRM keep its caches in files, not in the
database; [docs/caching.md](docs/caching.md) explains why.

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

`./backup.sh` writes the database, the files and a copy of `.env` to `backups/<timestamp>/`
and deletes backups older than 14 days. Run it nightly from the host's crontab:

```
30 2 * * * cd /path/to/civicrm && ./backup.sh > /dev/null
```

`./restore.sh backups/<timestamp>` puts all three back and keeps the state it replaces in
`backups/pre-restore-<timestamp>.*`.

The backups stay on the same server. Copy `backups/` somewhere else, and keep that copy as
safe as `.env` itself: every backup holds its passwords.

### Upgrades

```sh
./upgrade.sh          # newest patch of the minor line in .env
./upgrade.sh 6.19     # the next minor line
```

`upgrade.sh` writes a backup first, then pulls the images and updates the database while
CiviCRM is stopped. It names the backup that `./restore.sh` takes you back with. Change
`CIVICRM_VERSION` through `upgrade.sh` rather than by hand, read the release notes before you
change the minor line, and move one line at a time.

## Tests

`tests/run.sh` checks the whole setup end to end on `https://localhost:8443`, from the install
through every profile to a backup and restore. `tests/upgrade.sh` upgrades from the previous
minor line and goes back. GitHub Actions runs both on every push and weekly.

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

## Documentation

| File | Covers |
|---|---|
| [docs/profiles.md](docs/profiles.md) | Each public profile, what to set up in CiviCRM for it, and how to write and test your own |
| [docs/php.md](docs/php.md) | The two files in `php/`: PHP settings and CiviCRM constants beyond `.env` |
| [docs/caching.md](docs/caching.md) | Why CiviCRM caches in files, the known bugs of both cache backends, and how to go back |
| [docs/backups.md](docs/backups.md) | What backups hold, each step of restore and upgrade, and moving MariaDB to a new LTS line |
| [docs/testing.md](docs/testing.md) | What the tests check, their options, and what runs in CI |

## License

Copyright © 2026 civico GmbH. Licensed under the [GNU Affero General Public License
v3.0 or later](LICENSE).

# Testing

Both test scripts need Docker with Compose, run under their own project names and remove
their containers and volumes afterwards. Run them in a checkout, not beside a live
installation: they write to `backups/`, and `backup.sh` deletes old backups there.

## tests/run.sh

Starts the stack on `https://localhost:8443` with `tests/test.env`, then checks:

- the install, the language and the cron container;
- the file cache in the web server, in `cv` and in cron;
- blocked and open routes, including path and encoding tricks;
- the scripts and styles a public form references;
- every profile, switched on and off, with an anonymous visitor, who submits a form,
  registers for an event and makes a donation;
- the API with a valid key, a wrong key and malformed headers;
- cookies marked Secure;
- a backup and restore round trip, including a refused restore of a broken backup.

`tests/fixtures.php` creates the records these checks use.

## tests/upgrade.sh

Installs the minor line before the one in `tests/test.env`, upgrades it with `upgrade.sh` and
goes back with `restore.sh`. On the way it checks that a missing image stops the upgrade
without changing anything, and that the upgrade does not wait for input.

`tests/upgrade.sh 6.16` starts from another line. `MARIADB_FROM=<tag>` starts on an older
MariaDB, which the upgrade replaces with the one in `compose.yaml`.

## Continuous integration

GitHub Actions runs shellcheck, `tests/run.sh` against the pinned `CIVICRM_VERSION` and
against `latest`, and `tests/upgrade.sh`, on every push and weekly: the image tags move, so
new patch releases arrive without a commit. Dependabot proposes newer Caddy and action
versions. It leaves MariaDB's LTS line alone, and `CIVICRM_VERSION` sits in files it does not
read.

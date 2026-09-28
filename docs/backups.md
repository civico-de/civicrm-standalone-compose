# Backups, restores and upgrades

## What a backup holds

`./backup.sh` writes `backups/<timestamp>/` with:

- `database.sql.gz`, a dump of the CiviCRM database;
- `files.tar.gz` with `private`, `public` and `ext`, without caches and temporary files;
- `env`, a copy of `.env`, so the backup names the `CIVICRM_VERSION` its database belongs to.

It then deletes backups older than `KEEP_DAYS` days (default 14). If a step fails, nothing is
kept and the script exits non-zero.

CiviCRM keeps running during a backup. The database is dumped first and the files are
archived right after, so an upload or deletion in those seconds can leave one attachment out
of step with the database.

Every backup holds the passwords from `.env`. Keep the copy you take off the server as safe
as `.env` itself.

## Restoring

`./restore.sh backups/<timestamp>`:

1. checks that the backup is complete and reads both archives through;
2. keeps the current database and `.env` as `backups/pre-restore-<timestamp>.sql.gz` and
   `.env`, so data entered since the backup is not lost for good;
3. stops CiviCRM and replaces the database, the files and `.env`;
4. starts CiviCRM again with the images the restored `.env` names, and flushes the caches.

Files uploaded since the backup are replaced without a copy. If step 1 or 2 fails, nothing
has changed. If a later step fails, CiviCRM stays stopped and the script names the files
that hold the state before the restore. When the current database cannot be dumped at all,
`SKIP_PRE_RESTORE_DUMP=1` skips step 2.

## Upgrading CiviCRM

`./upgrade.sh` takes the newest patch of the minor line in `.env`; `./upgrade.sh 6.19` moves to
another line. The script:

1. writes a backup;
2. sets `CIVICRM_VERSION` in `.env`, if you named a line, and pulls the images. If an image
   cannot be pulled, it puts `.env` back and stops; CiviCRM keeps running;
3. stops CiviCRM and updates the database with `cv upgrade:db`. CiviCRM's pre-upgrade notes
   appear in the output; the script does not wait for an answer. If the update fails,
   CiviCRM stays stopped;
4. starts everything again.

Either way it names the backup, and `./restore.sh` with that backup takes you back to the
version before, code and database together. Change `CIVICRM_VERSION` only through
`upgrade.sh`: a backup taken after editing `.env` by hand would name a version its database
does not belong to.

## MariaDB and Caddy

`mariadb:11.4` is a long-term support line. Its patch releases arrive with every
`./upgrade.sh`, and `MARIADB_AUTO_UPGRADE` updates MariaDB's system tables when the server
version changes; without that, `mariadb-dump`, and so every backup, fails after a change.

Moving to the next LTS line is a change to the tag in `compose.yaml`. Before you make it, run
`MARIADB_FROM=11.4 tests/upgrade.sh` with the new tag in place: it installs on the old line,
upgrades and restores. `restore.sh` puts the data back into the MariaDB that is running; it
does not take MariaDB itself back to an older line.

`caddy:2` receives every Caddy 2 release with `./upgrade.sh`.

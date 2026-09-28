# PHP settings and CiviCRM constants

Two files in `php/` belong to this setup, not to CiviCRM or the `civicrm/civicrm` image. They
cover what `.env` cannot. Compose mounts them read-only into `init`, `app` and `cron`:

| File | In the container |
|---|---|
| `php/overrides.ini` | `/usr/local/etc/php/conf.d/zz-civicrm-standalone-compose.ini` |
| `php/constants.php` | `/opt/civicrm-standalone-compose/constants.php` |

After changing either, run `docker compose restart app cron`.

## php/overrides.ini

PHP settings. PHP reads this file after the image's own `civicrm.ini`, so a value here wins,
for example:

```ini
memory_limit = 512M
upload_max_filesize = 128M
post_max_size = 128M
```

Keep its `auto_prepend_file` line: it loads `php/constants.php`.

## php/constants.php

CiviCRM reads some of its configuration only from PHP constants, not from the environment.
This file defines them before every web request, `cv` call and cron run, so before
CiviCRM loads `private/civicrm.settings.php`. It sets `CIVICRM_DB_CACHE_CLASS`, see
[caching.md](caching.md).

The settings file sets most constants only `if (!defined(...))`, so a value here wins. A
constant it sets without that check cannot be changed here: PHP then warns "Constant already
defined" on every request. Look before you add one:

```sh
docker compose exec app grep -n -B1 "define('CIVICRM_MAIL_LOG'" private/civicrm.settings.php
```

For a test copy, for example, `define('CIVICRM_MAIL_LOG', '/var/www/html/private/mail.log');`
writes all outgoing mail to that file and sends none.

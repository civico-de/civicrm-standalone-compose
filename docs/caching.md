# Caching

CiviCRM keeps its longer-lived caches as files in `private/filecache`, on the volume that
`app` and `cron` share, instead of in the database table `civicrm_cache`. PHP's OPcache is
on in the `civicrm/civicrm` image. There is no Redis.

## Why files and not the database

CiviCRM ships two cache backends that need no extra service. Both have known bugs, all rare
race conditions when two processes write the same entry:

- File cache: occasional `unserialize()` notices while cron runs
  ([dev/core#5753](https://lab.civicrm.org/dev/core/-/work_items/5753), closed without a fix).
  CiviCRM treats the broken entry as missing and builds it again.
- Database cache: a failed lock ends the request with HTTP 500
  ([dev/core#6657](https://lab.civicrm.org/dev/core/-/work_items/6657)), and a duplicate cache
  entry can break an event registration
  ([civicrm-core#36802](https://github.com/civicrm/civicrm-core/pull/36802)).

A file cache error costs one cache entry; a database cache error can cost a form submission.
Redis avoids both, at the price of another service to run and back up.

## How it is set

CiviCRM reads the cache backend only from the PHP constant `CIVICRM_DB_CACHE_CLASS`, not from
the environment, so `php/constants.php` defines it (see [php.md](php.md)). The settings file
CiviCRM wrote at installation keeps that value, and it applies to existing installations as
well. `backup.sh` leaves `private/filecache` out; `restore.sh` flushes the caches anyway.

Each cache directory carries the CiviCRM version in its name, so an upgraded CiviCRM starts
with an empty cache. The older version's directories stay behind unused and can be deleted.

## Going back to the database cache

Delete the `CIVICRM_DB_CACHE_CLASS` line from `php/constants.php` and run
`docker compose restart app cron`.

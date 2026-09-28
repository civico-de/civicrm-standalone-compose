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
the environment. `php/filecache.php` defines it, and `php/filecache.ini` loads that file
before every PHP request and every `cv` call, through PHP's `auto_prepend_file`. The settings
file CiviCRM wrote at installation defines the constant only when it is still undefined, so
it stays as it is, and the setting applies to existing installations as well.

`backup.sh` leaves `private/filecache` out; `restore.sh` flushes the caches anyway.

## Going back to the database cache

Delete the two lines that mount `php/` in `compose.yaml` and run `docker compose up -d`.

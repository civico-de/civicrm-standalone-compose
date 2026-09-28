<?php
// SPDX-FileCopyrightText: 2026 civico GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

// Part of civicrm-standalone-compose, not of CiviCRM. Defines constants CiviCRM does not read from
// the environment, before civicrm.settings.php; only ones it sets with "if (!defined(...))". See docs/php.md.

// See docs/caching.md.
define('CIVICRM_DB_CACHE_CLASS', 'FileCache');

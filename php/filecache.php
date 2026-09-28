<?php
// SPDX-FileCopyrightText: 2026 civico GmbH
// SPDX-License-Identifier: AGPL-3.0-or-later

// Runs before civicrm.settings.php, which keeps a constant defined here. CiviCRM does not read
// CIVICRM_DB_CACHE_CLASS from the environment, so it is set in PHP. See docs/caching.md.
define('CIVICRM_DB_CACHE_CLASS', 'FileCache');

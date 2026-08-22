// WordPress constants injected into wp-config.php on Railway.
//
// The upstream image runs `eval(getenv_docker('WORDPRESS_CONFIG_EXTRA', ''))`,
// so this file is a bare statement list with NO opening `<?php` tag — adding one
// would make eval() emit it as literal output. Lint it with:
//     (echo '<?php'; cat wp-config-extra.php) | php -l
//
// The entrypoint exports this file's contents as WORDPRESS_CONFIG_EXTRA unless
// that variable is already set, so it lives in the repo — reviewable, diffable
// and out of the template's variable list — while an operator can still replace
// the whole block with a Railway variable.
//
// wp-config.php itself is written once, on first boot, but every value in it is
// read back through getenv_docker() per request and this block is re-eval'd per
// request, so editing here and redeploying takes effect on an existing install.

// Pin the canonical URL to the Railway domain. WooCommerce builds checkout,
// payment-return and email links from it, and a host-based mismatch breaks all
// three. Not hardcoded: it re-resolves each boot, so attaching a custom domain is
// a variable change rather than a database edit.
$railway_host = getenv('RAILWAY_PUBLIC_DOMAIN');
if ($railway_host) {
    define('WP_HOME', 'https://' . $railway_host);
    define('WP_SITEURL', 'https://' . $railway_host);
}

// The image already promotes X-Forwarded-Proto to $_SERVER['HTTPS'], so this
// costs no redirect loop, and a store taking payment details has no business
// serving its admin over plain HTTP.
define('FORCE_SSL_ADMIN', true);

// No editing plugin or theme PHP from the browser: on a public store that turns
// one stolen admin session into arbitrary code execution. Plugin and theme
// *installation* stays enabled — DISALLOW_FILE_MODS is deliberately not set.
define('DISALLOW_FILE_EDIT', true);

// The container runs a real scheduler loop, so WordPress must not also fire cron
// from page requests: that would double every Action Scheduler batch.
define('DISABLE_WP_CRON', true);

define('WP_MEMORY_LIMIT', '256M');
define('WP_MAX_MEMORY_LIMIT', '512M');
define('WP_ENVIRONMENT_TYPE', 'production');
define('WP_AUTO_UPDATE_CORE', 'minor');

// Redis object cache. WooCommerce is unusually option- and meta-query-heavy, so
// this is a real throughput difference rather than decoration.
//
// The client is Predis, not phpredis: the official WordPress image ships no redis
// extension and cannot gain one without compiling it, because the base image
// purges its build dependencies. Redis Object Cache bundles Predis, which is pure
// PHP and needs nothing added.
if (getenv('WP_REDIS_HOST')) {
    define('WP_REDIS_HOST', getenv('WP_REDIS_HOST'));
    define('WP_REDIS_PORT', (int) (getenv('WP_REDIS_PORT') ?: 6379));
    define('WP_REDIS_CLIENT', 'predis');
    define('WP_REDIS_PREFIX', 'wc:');
    define('WP_REDIS_DATABASE', 0);
    define('WP_REDIS_TIMEOUT', 2);
    define('WP_REDIS_READ_TIMEOUT', 2);
    if (getenv('WP_REDIS_PASSWORD')) {
        define('WP_REDIS_PASSWORD', getenv('WP_REDIS_PASSWORD'));
    }
}

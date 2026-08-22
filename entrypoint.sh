#!/usr/bin/env bash
#
# WooCommerce on Railway — boot wrapper.
#
# Everything here exists because a Railway template deploy has no manual steps:
# whatever the WordPress five-step installer, the WooCommerce onboarding wizard
# and a DBA would normally do by hand has to happen in the container instead.
#
# Runs in two halves. Synchronously, before Apache starts: PHP limits, the MPM
# fix, and the proxy trust list — all of which must be in place for the very
# first request. Then, in the background behind `exec`: the database account,
# `wp core install`, and the store configuration, which need a reachable database
# and would otherwise burn the health-check window.

set -Eeuo pipefail

WP_PATH=/var/www/html
log() { echo "[railway] $*" >&2; }
wpc() { wp --path="${WP_PATH}" --allow-root "$@"; }

# ---------------------------------------------------------------------------
# 1. PHP limits
#
# upload_max_filesize and post_max_size are PHP_INI_PERDIR, so ini_set() cannot
# reach them and WordPress would keep PHP's 2 MB default — which is below most
# product photographs. WooCommerce's settings screens also post more than PHP's
# default 1000 input variables once a store has several shipping zones.
# ---------------------------------------------------------------------------
cat > /usr/local/etc/php/conf.d/zz-railway.ini <<EOF
upload_max_filesize = ${PHP_UPLOAD_MAX_FILESIZE:-64M}
post_max_size = ${PHP_POST_MAX_SIZE:-64M}
memory_limit = ${PHP_MEMORY_LIMIT:-512M}
max_execution_time = ${PHP_MAX_EXECUTION_TIME:-300}
max_input_vars = ${PHP_MAX_INPUT_VARS:-5000}
EOF
log "php limits written: $(tr '\n' ' ' < /usr/local/etc/php/conf.d/zz-railway.ini)"

# ---------------------------------------------------------------------------
# 2. Apache MPM
#
# Recent php:8.x-apache builds leave mpm_event and mpm_worker enabled alongside
# the mpm_prefork that mod_php requires, and Apache refuses to start:
#   AH00534: apache2: Configuration error: More than one MPM loaded.
# The container then crash-loops while the deployment can still read SUCCESS.
# ---------------------------------------------------------------------------
a2dismod mpm_event mpm_worker >/dev/null 2>&1 || true
rm -f /etc/apache2/mods-enabled/mpm_event.* /etc/apache2/mods-enabled/mpm_worker.*
a2enmod mpm_prefork >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 3. Client IP
#
# Railway's edge reaches containers from the CGNAT range. The image enables
# mod_remoteip but trusts only RFC1918, loopback and link-local, so without this
# every order, login attempt and comment records the proxy as the client.
# ---------------------------------------------------------------------------
REMOTEIP_CONF=/etc/apache2/conf-available/remoteip.conf
if [ -f "${REMOTEIP_CONF}" ] && ! grep -q '100.64.0.0/10' "${REMOTEIP_CONF}"; then
    {
        echo 'RemoteIPInternalProxy 100.64.0.0/10'
        echo 'RemoteIPInternalProxy fd00::/8'
    } >> "${REMOTEIP_CONF}"
    log 'mod_remoteip now trusts 100.64.0.0/10 and fd00::/8'
fi

apache2ctl -t

# ---------------------------------------------------------------------------
# 4. wp-config.php constants
#
# The upstream image eval()s WORDPRESS_CONFIG_EXTRA inside wp-config.php. Keeping
# that block in a repo file rather than a Railway variable makes it reviewable and
# diffable, and keeps a ~2 KB value out of the published template — where large
# variable contents are replaced with placeholder text. An operator setting the
# variable themselves still wins.
# ---------------------------------------------------------------------------
if [ -z "${WORDPRESS_CONFIG_EXTRA:-}" ] && [ -s /usr/local/share/railway/wp-config-extra.php ]; then
    WORDPRESS_CONFIG_EXTRA="$(cat /usr/local/share/railway/wp-config-extra.php)"
    export WORDPRESS_CONFIG_EXTRA
    log 'WORDPRESS_CONFIG_EXTRA loaded from the image'
else
    log 'WORDPRESS_CONFIG_EXTRA supplied by the environment; the repo default is not used'
fi

# ---------------------------------------------------------------------------
# 5. Deferred setup, behind the exec
# ---------------------------------------------------------------------------
setup() {
    # The upstream entrypoint copies WordPress out of /usr/src/wordpress and
    # writes wp-config.php. Nothing below can run until it has.
    local i
    for i in $(seq 1 150); do
        if [ -s "${WP_PATH}/wp-includes/version.php" ] && [ -s "${WP_PATH}/wp-config.php" ]; then
            break
        fi
        sleep 2
    done
    if [ ! -s "${WP_PATH}/wp-config.php" ]; then
        log 'ERROR: wp-config.php never appeared; the upstream entrypoint did not run. Setup abandoned.'
        return 1
    fi

    # Must-use plugins are refreshed on every boot, unlike wp-content, so a
    # rebuilt image actually ships them.
    mkdir -p "${WP_PATH}/wp-content/mu-plugins"
    cp -f /usr/local/share/railway/mu-plugins/*.php "${WP_PATH}/wp-content/mu-plugins/"
    chown -R www-data:www-data "${WP_PATH}/wp-content/mu-plugins"
    log "mu-plugins installed: $(ls -m "${WP_PATH}/wp-content/mu-plugins")"

    # Least-privilege database account. Idempotent; retries internally while the
    # managed database is still starting.
    if ! php /usr/local/share/railway/bootstrap-db.php; then
        log 'WARNING: database bootstrap did not complete. Continuing — WordPress will retry next boot.'
    fi

    if wpc core is-installed >/dev/null 2>&1; then
        log 'WordPress is already installed.'
    else
        local url="${WORDPRESS_SITE_URL:-https://${RAILWAY_PUBLIC_DOMAIN:-localhost}}"
        log "running the WordPress installer against ${url}"
        # `wp core install` is what replaces the five-step browser wizard. It is
        # the one moment WORDPRESS_ADMIN_PASSWORD is read; changing the variable
        # afterwards does nothing, because the hash is now a database row.
        if wpc core install \
            --url="${url}" \
            --title="${WORDPRESS_SITE_TITLE:-My Store}" \
            --admin_user="${WORDPRESS_ADMIN_USER:-storeadmin}" \
            --admin_password="${WORDPRESS_ADMIN_PASSWORD:?WORDPRESS_ADMIN_PASSWORD must be set}" \
            --admin_email="${WORDPRESS_ADMIN_EMAIL:-admin@example.dev}" \
            --skip-email; then
            log 'WordPress installed.'
        else
            log 'ERROR: wp core install failed. Setup abandoned; it will retry on the next boot.'
            return 1
        fi

        # Pretty permalinks. WooCommerce product and shop URLs are unusable
        # without them, and the default is plain ?p=N.
        wpc rewrite structure '/%postname%/' --hard >/dev/null 2>&1 || true
        wpc rewrite flush --hard >/dev/null 2>&1 || true
        # Discourage nothing: a live store must be indexable.
        wpc option update blog_public 1 >/dev/null 2>&1 || true
    fi

    # WooCommerce. Activation is what creates its tables and its Shop, Cart,
    # Checkout and My Account pages.
    if wpc plugin is-active woocommerce >/dev/null 2>&1; then
        log "WooCommerce $(wpc plugin get woocommerce --field=version 2>/dev/null) is active."
    else
        if ! wpc plugin is-installed woocommerce >/dev/null 2>&1; then
            # Only reachable when the volume already held WordPress from an
            # older build of this image, so the staged copy was skipped.
            wpc plugin install woocommerce >/dev/null 2>&1 || true
        fi
        wpc plugin activate woocommerce && log 'WooCommerce activated.'
    fi

    # Redis object cache. WooCommerce is exceptionally option- and
    # meta-query-heavy, so this is not decoration.
    if [ -n "${WP_REDIS_HOST:-}" ]; then
        wpc plugin is-active redis-cache >/dev/null 2>&1 || wpc plugin activate redis-cache || true
        if [ ! -f "${WP_PATH}/wp-content/object-cache.php" ]; then
            wpc redis enable >/dev/null 2>&1 && log 'Redis object cache drop-in enabled.' \
                || log 'WARNING: could not enable the Redis object cache drop-in.'
        fi
    fi

    configure_store

    chown -R www-data:www-data "${WP_PATH}/wp-content"
    log 'setup complete.'
}

# Store configuration is seeded once and then left alone. Re-applying it on every
# boot would silently revert whatever the operator changed in the admin, which is
# the classic non-idempotent boot-time setter.
configure_store() {
    if [ "$(wpc option get railway_store_seeded 2>/dev/null || true)" = 'done' ]; then
        log 'store settings already seeded; leaving the operator'"'"'s configuration alone.'
        return 0
    fi
    wpc plugin is-active woocommerce >/dev/null 2>&1 || return 0

    log 'seeding store settings'
    wpc option update woocommerce_store_address   "${WOOCOMMERCE_STORE_ADDRESS:-1 Market Street}" >/dev/null 2>&1 || true
    wpc option update woocommerce_store_city      "${WOOCOMMERCE_STORE_CITY:-San Francisco}"      >/dev/null 2>&1 || true
    wpc option update woocommerce_store_postcode  "${WOOCOMMERCE_STORE_POSTCODE:-94105}"          >/dev/null 2>&1 || true
    wpc option update woocommerce_default_country "${WOOCOMMERCE_STORE_COUNTRY:-US:CA}"           >/dev/null 2>&1 || true
    wpc option update woocommerce_currency        "${WOOCOMMERCE_CURRENCY:-USD}"                  >/dev/null 2>&1 || true
    wpc option update woocommerce_allow_tracking  no                                              >/dev/null 2>&1 || true

    # Skip the onboarding wizard: a template deployer should land on a working
    # store, not on a six-screen profiler.
    wpc option update woocommerce_onboarding_profile \
        '{"skipped":true,"completed":true}' --format=json >/dev/null 2>&1 || true
    wpc option update woocommerce_task_list_hidden yes           >/dev/null 2>&1 || true
    wpc option update woocommerce_task_list_appearance_hidden yes >/dev/null 2>&1 || true
    wpc transient delete _wc_activation_redirect                  >/dev/null 2>&1 || true

    # Cash on delivery is the one payment method that works with no gateway
    # account, so checkout is completable the moment the template finishes
    # deploying. Real gateways are the documented upgrade.
    wpc option update woocommerce_cod_settings \
        '{"enabled":"yes","title":"Cash on delivery","description":"Pay with cash upon delivery.","instructions":"Pay with cash upon delivery.","enable_for_methods":[],"enable_for_virtual":"yes"}' \
        --format=json >/dev/null 2>&1 || true

    # Without a shipping method in the catch-all zone, checkout refuses to
    # proceed for any physical product.
    wpc wc shipping_zone_method create 0 --method_id=free_shipping --user=1 >/dev/null 2>&1 \
        && log 'free shipping added to the "Rest of the World" zone' || true

    if [ "${WOOCOMMERCE_SEED_SAMPLE_PRODUCTS:-true}" = 'true' ]; then
        seed_sample_products
    fi

    wpc option update railway_store_seeded done >/dev/null 2>&1 || true
}

# A store with no products renders every template as an empty state, which reads
# as a broken deployment. These are ordinary published products — delete them in
# Products → All Products, or set WOOCOMMERCE_SEED_SAMPLE_PRODUCTS=false.
seed_sample_products() {
    local created=0
    while IFS='|' read -r name sku price desc; do
        [ -n "${name}" ] || continue
        if wpc wc product create --user=1 \
            --name="${name}" \
            --sku="${sku}" \
            --type=simple \
            --regular_price="${price}" \
            --status=publish \
            --catalog_visibility=visible \
            --manage_stock=false \
            --short_description="${desc}" \
            --description="${desc}" </dev/null >/dev/null 2>&1; then
            created=$((created + 1))
        fi
    done <<'PRODUCTS'
Ceramic Pour-Over Set|RW-POUR-01|48.00|A two-piece stoneware dripper and carafe for single-origin filter coffee.
Cold Brew Carafe|RW-CARAFE-02|32.00|One litre of borosilicate glass with a stainless steel filter basket.
Burr Hand Grinder|RW-GRIND-03|89.00|Conical stainless burrs with forty click-stopped grind settings.
Espresso Tamper|RW-TAMP-04|24.00|Solid walnut handle on a flat 58 mm stainless base.
House Blend, 1kg|RW-BEAN-05|27.50|A chocolate-forward blend of washed Colombian and natural Ethiopian beans.
Insulated Travel Mug|RW-MUG-06|29.00|Vacuum-sealed 350 ml tumbler that holds temperature for six hours.
PRODUCTS
    log "sample catalogue seeded (${created} products)"
}

# WordPress fires its scheduler from incoming page requests, which on a quiet
# store means order emails, stock sync and every Action Scheduler job stall until
# somebody browses. Railway drops deploy.cronSchedule from a published template,
# so a Railway cron service could not carry over; this ticker can. It calls
# wp-cron.php over the loopback so the work runs as www-data under Apache, and
# forwards the public host so WordPress builds correct links in the mail it sends.
cron_ticker() {
    local interval="${WP_CRON_INTERVAL_SECONDS:-60}"
    local host="${RAILWAY_PUBLIC_DOMAIN:-localhost}"
    sleep 30
    while true; do
        curl -sS -o /dev/null --max-time 120 \
            -H "Host: ${host}" \
            -H 'X-Forwarded-Proto: https' \
            "http://127.0.0.1/wp-cron.php?doing_wp_cron=$(date +%s)" \
            || log 'wp-cron tick failed'
        sleep "${interval}"
    done
}

if [ "${1-}" = 'apache2-foreground' ] || [ "${1-}" = 'apache2' ]; then
    ( setup || log 'setup exited non-zero' ) &
    if [ "${WP_CRON_DISABLE_TICKER:-false}" != 'true' ]; then
        cron_ticker &
    fi
fi

# Restating the upstream entrypoint is mandatory, not cosmetic: it is what copies
# WordPress onto an empty volume and writes wp-config.php. Community fixes for the
# MPM error end at `apache2-foreground` and silently produce an empty document root.
log "handing off to docker-entrypoint.sh $*"
exec docker-entrypoint.sh "$@"

# WooCommerce on Railway.
#
# Thin wrapper over the Docker Official WordPress image. The application is never
# rebuilt — this layer only adds what a Railway deployment needs and the stock
# image cannot express through environment variables:
#
#   * WP-CLI, so the container can install WordPress and configure the store at
#     boot instead of shipping a manual setup wizard;
#   * WooCommerce and Redis Object Cache staged in /usr/src/wordpress, which the
#     upstream entrypoint copies onto an empty volume on first boot;
#   * must-use plugins (SMTP transport, REST user hardening) refreshed every boot.
#
# WordPress core is pinned to the 7.0 line, not `latest`. WooCommerce 11.x
# declares "Tested up to: 7.0.4"; WordPress 7.1.0 shipped 2026-08-20 and
# WooCommerce has not certified it. `7.0-php8.4-apache` still floats across 7.0.x
# patch releases, so security fixes keep arriving.
FROM wordpress:7.0-php8.4-apache

ARG WP_CLI_VERSION=2.12.0

# `unzip` is needed to stage the plugins below; `less` is what WP-CLI shells out
# to for its own output and it warns on every invocation without it.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl unzip less; \
    rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    curl -fsSL -o /usr/local/bin/wp \
        "https://github.com/wp-cli/wp-cli/releases/download/v${WP_CLI_VERSION}/wp-cli-${WP_CLI_VERSION}.phar"; \
    chmod +x /usr/local/bin/wp; \
    wp --allow-root --info

# Stage the plugins where the upstream entrypoint will find them. It copies
# /usr/src/wordpress into the volume only while the volume holds neither
# index.php nor wp-includes/version.php, and it skips any wp-content/*/*/ path
# that already exists there — so a plugin the operator has since updated is never
# reverted by a redeploy. Runtime updates come from WordPress's own updater, not
# from rebuilding this image.
RUN set -eux; \
    mkdir -p /usr/src/wordpress/wp-content/plugins; \
    for plugin in woocommerce redis-cache; do \
        curl -fsSL -o "/tmp/${plugin}.zip" \
            "https://downloads.wordpress.org/plugin/${plugin}.latest-stable.zip"; \
        unzip -q "/tmp/${plugin}.zip" -d /usr/src/wordpress/wp-content/plugins; \
        rm "/tmp/${plugin}.zip"; \
    done; \
    test -f /usr/src/wordpress/wp-content/plugins/woocommerce/woocommerce.php; \
    test -f /usr/src/wordpress/wp-content/plugins/redis-cache/redis-cache.php; \
    chown -R www-data:www-data /usr/src/wordpress/wp-content

# Must-use plugins are re-copied onto the volume on every boot so that rebuilding
# this image actually ships them, unlike the one-shot wp-content copy above.
COPY mu-plugins/ /usr/local/share/railway/mu-plugins/
COPY bootstrap-db.php /usr/local/share/railway/bootstrap-db.php
COPY entrypoint.sh /usr/local/bin/railway-entrypoint.sh
RUN chmod +x /usr/local/bin/railway-entrypoint.sh

# Railway replaces the ENTRYPOINT with the start command when one is set, so this
# wrapper is also declared as the image ENTRYPOINT for anyone running it directly.
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
CMD ["apache2-foreground"]

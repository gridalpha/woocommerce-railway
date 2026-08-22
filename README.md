# WooCommerce on Railway

A deploy-and-it-works WooCommerce store: WordPress with WooCommerce installed,
activated and configured by the container itself, so there is no five-step
installer and no onboarding wizard between clicking Deploy and having a shop.

This is a thin wrapper over the [Docker Official WordPress
image](https://hub.docker.com/_/wordpress). The application is never rebuilt.

## What the wrapper adds

| | Why it cannot be a Railway variable |
|---|---|
| Apache MPM repair | Recent `php:8.x-apache` builds leave `mpm_event`/`mpm_worker` enabled next to the `mpm_prefork` that `mod_php` needs, and Apache exits with `AH00534: … More than one MPM loaded`. |
| PHP limits | `upload_max_filesize` and `post_max_size` are `PHP_INI_PERDIR`; `ini_set()` cannot reach them, so the container would keep PHP's 2 MB upload ceiling. |
| `mod_remoteip` trust list | Railway's edge fronts containers from `100.64.0.0/10`, which the image does not trust, so every order and login would record the proxy as the client. |
| Scoped MySQL account | Railway's managed MySQL hands out root. `bootstrap-db.php` creates a database-scoped user at boot, idempotently. |
| `wp core install` + WooCommerce setup | A template deploy has no manual steps, so the installer and the store configuration run in the container. |
| Must-use plugins | SMTP transport for `wp_mail()`, and hardening that closes anonymous user enumeration. |
| WP-Cron ticker | WordPress fires its scheduler from page requests; a quiet store would stall order email and Action Scheduler. Railway drops `deploy.cronSchedule` from a published template, so the loop lives in the container. |

## Version policy

WordPress core is pinned to the **7.0 line**, not `latest`. WooCommerce 11.x
declares `Tested up to: 7.0.4`; WordPress 7.1.0 shipped 2026-08-20 and WooCommerce
has not certified it. The `7.0-php8.4-apache` tag still floats across 7.0.x patch
releases, so security fixes keep arriving.

WooCommerce and Redis Object Cache are staged into `/usr/src/wordpress` at build
time so the upstream entrypoint copies them onto an empty volume. After that
first boot they are updated by WordPress's own updater, not by rebuilding this
image — the entrypoint deliberately never overwrites an existing plugin
directory.

## Configuration

Every variable has a working default. See `deployments/*/woocommerce/README.md`
in the deployment repo for the full table.

The ones worth knowing:

- `WORDPRESS_ADMIN_USER` / `WORDPRESS_ADMIN_PASSWORD` / `WORDPRESS_ADMIN_EMAIL` —
  read **once**, while the installer runs. Changing them later does nothing;
  change the password in the WordPress admin instead.
- `WORDPRESS_SMTP_HOST` / `_PORT` / `_USER` / `_PASSWORD` / `_SECURE` — point at
  any SMTP relay. `_SECURE` defaults to `none` because Mailpit's plain 1025
  listener advertises no STARTTLS and PHPMailer's auto-TLS would abort the send.
- `WOOCOMMERCE_SEED_SAMPLE_PRODUCTS` — `true` by default; set `false` for an
  empty catalogue. The seeded products are ordinary published products and can be
  deleted from the admin.
- `WOOCOMMERCE_STORE_*`, `WOOCOMMERCE_CURRENCY` — seeded **once**, then left
  alone so the admin stays authoritative.
- `WORDPRESS_HARDENING=off` — re-opens `/wp-json/wp/v2/users`, author archives
  and XML-RPC.

## Licence

WordPress and WooCommerce are GPL-2.0-or-later. The files in this repository are
deployment glue and carry the same licence.

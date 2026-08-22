<?php
/**
 * Plugin Name: Railway hardening
 * Description: Closes the two disclosure surfaces a public WordPress store leaves open by default — anonymous user enumeration through the REST API, and XML-RPC.
 * Version: 1.0.0
 * Author: Railway deployment
 *
 * Set WORDPRESS_HARDENING=off to disable everything here.
 */

defined('ABSPATH') || exit;

if (strtolower((string) getenv('WORDPRESS_HARDENING')) === 'off') {
    return;
}

/**
 * Stock WordPress serves /wp-json/wp/v2/users to anonymous callers, listing the
 * username of everyone with a published post — which on a store means the
 * administrator. wp-config.php cannot filter it: the filters do not exist that
 * early in the boot. Authenticated callers are unaffected, so the block editor,
 * WooCommerce Admin and the REST-backed WP-CLI commands keep working.
 */
add_filter('rest_endpoints', function ($endpoints) {
    if (is_user_logged_in()) {
        return $endpoints;
    }
    foreach (['/wp/v2/users', '/wp/v2/users/(?P<id>[\d]+)'] as $route) {
        if (isset($endpoints[$route])) {
            unset($endpoints[$route]);
        }
    }
    return $endpoints;
});

/**
 * ?author=1 answers with a 301 to /author/<username>/, which leaks the same
 * username in the Location header. Redirect anonymous author queries to the
 * front page instead — at priority 1, ahead of core's redirect_canonical, which
 * also runs on template_redirect at 10 and would otherwise win the race.
 */
add_action('template_redirect', function () {
    if (is_author() && !is_user_logged_in()) {
        wp_safe_redirect(home_url('/'), 301);
        exit;
    }
}, 1);

/**
 * XML-RPC is unused by WooCommerce (which speaks REST) and is the endpoint
 * password-guessing tools reach for, because system.multicall lets them try many
 * passwords per request.
 */
add_filter('xmlrpc_enabled', '__return_false');
add_filter('xmlrpc_methods', function () {
    return [];
});

/**
 * Do not advertise the exact core version to unauthenticated scanners.
 */
remove_action('wp_head', 'wp_generator');
add_filter('the_generator', '__return_empty_string');

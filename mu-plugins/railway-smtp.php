<?php
/**
 * Plugin Name: Railway SMTP transport
 * Description: Routes wp_mail() through the SMTP host given in the environment. WooCommerce's core flow is transactional email, and the container has no local MTA, so PHP mail() silently drops every order confirmation.
 * Version: 1.0.0
 * Author: Railway deployment
 *
 * Must-use plugin: loaded on every request, cannot be deactivated from the admin.
 * Configuration is read from the environment on each send rather than stored in
 * the database, so changing a Railway variable takes effect on the next deploy
 * without an admin visit.
 */

defined('ABSPATH') || exit;

function railway_smtp_env(string $key, string $default = ''): string {
    $value = getenv($key);
    return ($value === false || $value === '') ? $default : $value;
}

add_action('phpmailer_init', function ($phpmailer) {
    $host = railway_smtp_env('WORDPRESS_SMTP_HOST');
    if ($host === '') {
        return; // fall through to PHP mail(); nothing to configure
    }

    $phpmailer->isSMTP();
    $phpmailer->Host = $host;
    $phpmailer->Port = (int) railway_smtp_env('WORDPRESS_SMTP_PORT', '1025');

    $user = railway_smtp_env('WORDPRESS_SMTP_USER');
    $pass = railway_smtp_env('WORDPRESS_SMTP_PASSWORD');
    if ($user !== '') {
        $phpmailer->SMTPAuth = true;
        $phpmailer->Username = $user;
        $phpmailer->Password = $pass;
    } else {
        $phpmailer->SMTPAuth = false;
    }

    // Mailpit's plain 1025 listener advertises no STARTTLS. PHPMailer's
    // SMTPAutoTLS would still try to negotiate it and abort the send, so the
    // default here is explicitly "no encryption" and a real relay opts in.
    $secure = strtolower(railway_smtp_env('WORDPRESS_SMTP_SECURE', 'none'));
    if ($secure === 'ssl' || $secure === 'tls') {
        $phpmailer->SMTPSecure = $secure;
        $phpmailer->SMTPAutoTLS = true;
    } else {
        $phpmailer->SMTPSecure = '';
        $phpmailer->SMTPAutoTLS = false;
    }

    $phpmailer->Timeout = 15;
}, 10, 1);

add_filter('wp_mail_from', function ($from) {
    $configured = railway_smtp_env('WORDPRESS_MAIL_FROM');
    return $configured !== '' ? $configured : $from;
});

add_filter('wp_mail_from_name', function ($name) {
    $configured = railway_smtp_env('WORDPRESS_MAIL_FROM_NAME');
    return $configured !== '' ? $configured : $name;
});

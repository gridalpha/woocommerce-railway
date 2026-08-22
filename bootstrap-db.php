<?php
/**
 * Provision a least-privilege MySQL account for WordPress, idempotently, at boot.
 *
 * Railway's managed MySQL hands out root. WordPress with WooCommerce is a large
 * plugin-driven attack surface, so the application connects as a scoped user that
 * can only touch its own schema. A template deploy has no manual steps, so this
 * runs from the container on every boot rather than being a documented one-off.
 *
 * Reads MYSQL_URL (root, a ${{MySQL.MYSQL_URL}} reference) and the
 * WORDPRESS_DB_* values the application itself uses. Does nothing when MYSQL_URL
 * is absent or when the application is already configured to connect as the
 * MYSQL_URL user — an operator pointing this at their own database keeps control.
 *
 * mysqli is used rather than the mysql client binary: the official WordPress
 * image ships no client, and Debian's would be MariaDB's, which verifies TLS
 * certificates and rejects Railway's self-signed managed MySQL.
 */

function out(string $msg): void {
    fwrite(STDERR, "[bootstrap-db] {$msg}\n");
}

$rootUrl = getenv('MYSQL_URL') ?: '';
if ($rootUrl === '') {
    out('MYSQL_URL is not set — skipping (the application will connect with WORDPRESS_DB_* as given).');
    exit(0);
}

$parts = parse_url($rootUrl);
if ($parts === false || !isset($parts['host'], $parts['user'])) {
    out('MYSQL_URL could not be parsed — skipping.');
    exit(0);
}

$rootUser = urldecode($parts['user']);
$rootPass = isset($parts['pass']) ? urldecode($parts['pass']) : '';
$rootHost = $parts['host'];
$rootPort = isset($parts['port']) ? (int) $parts['port'] : 3306;

$appUser = getenv('WORDPRESS_DB_USER') ?: 'wordpress';
$appPass = getenv('WORDPRESS_DB_PASSWORD') ?: '';
$appDb   = getenv('WORDPRESS_DB_NAME') ?: 'wordpress';

if ($appPass === '') {
    out('WORDPRESS_DB_PASSWORD is empty — refusing to create a passwordless account.');
    exit(1);
}
if ($appUser === $rootUser) {
    out("WORDPRESS_DB_USER is the MYSQL_URL user ({$rootUser}) — nothing to provision.");
    exit(0);
}
if (!preg_match('/^[A-Za-z0-9_]+$/', $appUser) || !preg_match('/^[A-Za-z0-9_]+$/', $appDb)) {
    out('WORDPRESS_DB_USER and WORDPRESS_DB_NAME must be alphanumeric/underscore.');
    exit(1);
}

// Railway has no service dependency ordering, so the database is routinely still
// starting when this container boots. Retry rather than failing the deployment.
mysqli_report(MYSQLI_REPORT_OFF);
$link = null;
for ($attempt = 1; $attempt <= 40; $attempt++) {
    $link = @mysqli_connect($rootHost, $rootUser, $rootPass, '', $rootPort);
    if ($link instanceof mysqli) {
        break;
    }
    out("waiting for MySQL at {$rootHost}:{$rootPort} (attempt {$attempt}/40): " . mysqli_connect_error());
    $link = null;
    sleep(5);
}
if ($link === null) {
    out('MySQL never became reachable — giving up. WordPress will retry on the next boot.');
    exit(1);
}

$q = function (string $sql) use ($link): void {
    if (!mysqli_query($link, $sql)) {
        // Print the statement shape, never the statement — it carries the password.
        $head = strtok($sql, "\n");
        $head = preg_replace("/IDENTIFIED BY '.*/", "IDENTIFIED BY '***'", $head);
        throw new RuntimeException("{$head} failed: " . mysqli_error($link));
    }
};

$escUser = mysqli_real_escape_string($link, $appUser);
$escPass = mysqli_real_escape_string($link, $appPass);

try {
    $q("CREATE DATABASE IF NOT EXISTS `{$appDb}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci");
    $q("CREATE USER IF NOT EXISTS '{$escUser}'@'%' IDENTIFIED BY '{$escPass}'");
    // Keep the stored password in step with the variable, so rotating it is a
    // redeploy rather than a manual ALTER.
    $q("ALTER USER '{$escUser}'@'%' IDENTIFIED BY '{$escPass}'");
    // Deliberately no REVOKE first: on Railway's managed MySQL 9.x,
    // `REVOKE ALL PRIVILEGES ON *.*` also drops the database-scoped grants below
    // and leaves the account with USAGE only.
    $q(
        "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, INDEX, " .
        "CREATE TEMPORARY TABLES, LOCK TABLES, REFERENCES ON `{$appDb}`.* TO '{$escUser}'@'%'"
    );
    $q('FLUSH PRIVILEGES');
} catch (RuntimeException $e) {
    out($e->getMessage());
    mysqli_close($link);
    exit(1);
}

$grants = [];
if ($res = mysqli_query($link, "SHOW GRANTS FOR '{$escUser}'@'%'")) {
    while ($row = mysqli_fetch_row($res)) {
        $grants[] = $row[0];
    }
}
mysqli_close($link);

out("database `{$appDb}` and scoped user '{$appUser}'@'%' are provisioned.");
foreach ($grants as $grant) {
    out('  ' . $grant);
}
exit(0);

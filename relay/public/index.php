<?php

declare(strict_types=1);

// Every request comes here (FallbackResource on the server, the built-in server's fallback locally). The sources are
// required directly: the server gets no vendor/ directory, as the relay needs no library at run time.

namespace Ferry\Relay;

use PDO;

foreach (['Http', 'Es256', 'Vapid', 'Store', 'Apns', 'Relay'] as $file) {
    require_once __DIR__ . "/../src/$file.php";
}
$config = require __DIR__ . '/../config.php';

$pdo = new PDO('sqlite:' . $config['db']);
$pdo->exec('PRAGMA journal_mode = WAL');
$pdo->exec('PRAGMA busy_timeout = 5000');
$store = new Store($pdo);
$apns = $config['apns'] === 'simctl'
    ? new SimctlApns($config['simulator'], $config['topic'])
    : new CurlApns($config['key_id'], $config['team_id'], $config['key_path'], $config['topic'], $store);

(new Relay($store, $apns, rtrim($config['origin'], '/'), static fn (): int => time()))
    ->handle(Request::fromGlobals())
    ->emit();

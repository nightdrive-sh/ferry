<?php

declare(strict_types=1);

// The relay's settings, from the environment (the PHP-FPM pool's env[] lines on the server). The APNs key stays
// outside the code; only its path is given.
return [
    'origin' => getenv('FERRY_RELAY_ORIGIN') ?: 'https://push.nightdrive.sh',
    'db' => getenv('FERRY_RELAY_DB') ?: __DIR__ . '/data/relay.sqlite',
    'apns' => getenv('FERRY_RELAY_APNS') ?: 'curl',          // 'curl', or 'simctl' for a development simulator
    'simulator' => getenv('FERRY_RELAY_SIMULATOR') ?: 'booted',
    'key_id' => getenv('APNS_KEY_ID') ?: '',
    'team_id' => getenv('APNS_TEAM_ID') ?: '279G2UNHPN',
    'key_path' => getenv('APNS_KEY_PATH') ?: '',
    'topic' => 'fi.feature.ferry',
];

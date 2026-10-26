<?php

declare(strict_types=1);

namespace Ferry\Relay;

use PDO;

/**
 * Everything the relay keeps: the addresses (id → APNs token, its environment, the computer's VAPID key, the secret's
 * hash) and rate counters. No content and no senders: an IP appears only as a salted hash in a counter, pruned as its
 * window ends.
 */
final class Store
{
    public function __construct(private readonly PDO $pdo)
    {
        $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
        $pdo->exec('CREATE TABLE IF NOT EXISTS addresses (id TEXT PRIMARY KEY, token TEXT NOT NULL, env TEXT NOT NULL,
                    vapid TEXT NOT NULL, secret_hash TEXT NOT NULL, created INTEGER NOT NULL, last_push INTEGER)');
        $pdo->exec('CREATE TABLE IF NOT EXISTS counters (key TEXT NOT NULL, window INTEGER NOT NULL, count INTEGER NOT NULL,
                    expires INTEGER NOT NULL, PRIMARY KEY (key, window))');
        $pdo->exec('CREATE TABLE IF NOT EXISTS meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)');
    }

    public function addAddress(string $id, string $token, string $env, string $vapid, string $secretHash, int $now): void
    {
        $this->pdo->prepare('INSERT INTO addresses (id, token, env, vapid, secret_hash, created) VALUES (?, ?, ?, ?, ?, ?)')
            ->execute([$id, $token, $env, $vapid, $secretHash, $now]);
    }

    /** @return array{id: string, token: string, env: string, vapid: string, secret_hash: string, created: int, last_push: ?int}|null */
    public function address(string $id): ?array
    {
        $q = $this->pdo->prepare('SELECT * FROM addresses WHERE id = ?');
        $q->execute([$id]);
        $row = $q->fetch(PDO::FETCH_ASSOC);
        if ($row === false) {
            return null;
        }
        $row['created'] = (int) $row['created'];
        $row['last_push'] = $row['last_push'] === null ? null : (int) $row['last_push'];
        return $row;
    }

    public function deleteAddress(string $id): void
    {
        $this->pdo->prepare('DELETE FROM addresses WHERE id = ?')->execute([$id]);
    }

    public function touch(string $id, int $now): void
    {
        $this->pdo->prepare('UPDATE addresses SET last_push = ? WHERE id = ?')->execute([$now, $id]);
    }

    /** Counts one more in `key`'s current window of `seconds` and returns the window's count, this one included. */
    public function hit(string $key, int $seconds, int $now): int
    {
        $window = intdiv($now, $seconds);
        $this->pdo->prepare('DELETE FROM counters WHERE expires <= ?')->execute([$now]);
        $this->pdo->prepare('INSERT INTO counters (key, window, count, expires) VALUES (?, ?, 1, ?)
                             ON CONFLICT (key, window) DO UPDATE SET count = count + 1')
            ->execute([$key, $window, ($window + 1) * $seconds]);
        $q = $this->pdo->prepare('SELECT count FROM counters WHERE key = ? AND window = ?');
        $q->execute([$key, $window]);
        return (int) $q->fetchColumn();
    }

    /** Throws when the database can't be read. */
    public function check(): void
    {
        $this->pdo->query('SELECT 1 FROM addresses LIMIT 1');
    }

    public function meta(string $name): ?string
    {
        $q = $this->pdo->prepare('SELECT value FROM meta WHERE name = ?');
        $q->execute([$name]);
        $v = $q->fetchColumn();
        return $v === false ? null : (string) $v;
    }

    public function setMeta(string $name, string $value): void
    {
        $this->pdo->prepare('INSERT INTO meta (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value')
            ->execute([$name, $value]);
    }

    /** An IP as it appears in a counter: hashed with a salt made on first use, never stored as such. */
    public function ipKey(string $ip): string
    {
        $salt = $this->meta('salt');
        if ($salt === null) {
            $salt = bin2hex(random_bytes(32));
            $this->setMeta('salt', $salt);
        }
        return 'ip:' . hash_hmac('sha256', $ip, $salt);
    }
}

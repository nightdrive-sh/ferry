<?php

declare(strict_types=1);

namespace Ferry\Relay;

use Closure;
use Throwable;

/**
 * Ferry's push relay. The phone registers an address per computer; the computer sends its encrypted notification there
 * as Web Push (RFC 8030/8291/8292), exactly as it would to a browser's push service; the relay passes the bytes it
 * can't read on to APNs. Its API is in relay/README.md.
 */
final class Relay
{
    public const MAX_PUSH = 2800;          // base64 in the APNs payload stays under its 4096-byte limit
    public const MAX_REGISTER = 1024;
    public const PUSHES_PER_MINUTE = 30;   // per address
    public const PUSHES_PER_HOUR = 600;    // per sending IP
    public const REGISTERS_PER_HOUR = 30;  // per IP

    /** APNs reasons that mean the token will never work again. */
    private const DEAD_TOKEN = ['BadDeviceToken', 'DeviceTokenNotForTopic', 'Unregistered'];

    /** @param Closure(): int $now */
    public function __construct(
        private readonly Store $store,
        private readonly ApnsSender $apns,
        private readonly string $origin,
        private readonly Closure $now,
    ) {
    }

    public function handle(Request $r): Response
    {
        try {
            if ($r->path === '/health') {   // for the uptime monitor: PHP runs and the database answers
                if ($r->method !== 'GET') {
                    return Response::text(405, 'Method not allowed');
                }
                $this->store->check();
                return Response::text(200, 'ok');
            }
            if ($r->path === '/v1/register' && $r->method === 'POST') {
                return $this->register($r);
            }
            if (preg_match('#^/push/([A-Za-z0-9_-]{1,64})$#', $r->path, $m) === 1) {
                return match ($r->method) {
                    'POST' => $this->push($r, $m[1]),
                    'GET' => $this->exists($r, $m[1]),
                    'DELETE' => $this->delete($r, $m[1]),
                    default => Response::text(405, 'Method not allowed'),
                };
            }
            return Response::text(404, 'Not found');
        } catch (Throwable $e) {
            error_log('ferry relay: ' . $e->getMessage());
            return Response::text(500, 'Something went wrong');
        }
    }

    private function register(Request $r): Response
    {
        if (strlen($r->body) > self::MAX_REGISTER) {
            return Response::text(413, 'Too large');
        }
        if ($this->store->hit($this->store->ipKey($r->ip) . ':register', 3600, ($this->now)()) > self::REGISTERS_PER_HOUR) {
            return Response::text(429, 'Too many registrations, try again later');
        }
        $in = json_decode($r->body, true);
        $token = is_array($in) ? ($in['token'] ?? null) : null;
        $env = is_array($in) ? ($in['env'] ?? null) : null;
        $vapid = is_array($in) ? ($in['vapid'] ?? null) : null;
        if (!is_string($token) || preg_match('/^[0-9a-fA-F]{16,512}$/', $token) !== 1
            || !in_array($env, ['production', 'sandbox'], true)
            || !is_string($vapid) || Es256::publicKey($vapid) === null) {
            return Response::text(400, 'Expected {"token": hex, "env": "production"|"sandbox", "vapid": a P-256 key}');
        }
        $id = Es256::b64u(random_bytes(16));
        $secret = Es256::b64u(random_bytes(24));
        $this->store->addAddress($id, strtolower($token), $env, $vapid, hash('sha256', $secret), ($this->now)());
        return Response::json(201, ['endpoint' => "{$this->origin}/push/$id", 'secret' => $secret]);
    }

    private function exists(Request $r, string $id): Response
    {
        $a = $this->store->address($id);
        if ($a === null) {
            return Response::text(404, 'No such address');
        }
        return $this->authorized($r, $a['secret_hash']) ? new Response(204) : Response::text(403, 'Wrong secret');
    }

    private function delete(Request $r, string $id): Response
    {
        $a = $this->store->address($id);
        if ($a === null) {
            return new Response(204);
        }
        if (!$this->authorized($r, $a['secret_hash'])) {
            return Response::text(403, 'Wrong secret');
        }
        $this->store->deleteAddress($id);
        return new Response(204);
    }

    private function push(Request $r, string $id): Response
    {
        $now = ($this->now)();
        // Every attempt counts against its IP, signed or not: that is what keeps a flood off APNs and the database
        if ($this->store->hit($this->store->ipKey($r->ip) . ':push', 3600, $now) > self::PUSHES_PER_HOUR) {
            return Response::text(429, 'Too many notifications, try again later');
        }
        $a = $this->store->address($id);
        if ($a === null) {
            return Response::text(404, 'No such address');   // the computer drops the subscription
        }
        if (strtolower($r->header('Content-Encoding')) !== 'aes128gcm') {
            return Response::text(400, 'Expected Content-Encoding: aes128gcm');
        }
        if (strlen($r->body) > self::MAX_PUSH) {
            return Response::text(413, 'Too large');
        }
        if (!Vapid::verify($r->header('Authorization'), $a['vapid'], $this->origin, $now)) {
            return Response::text(403, 'Not signed by the computer this address belongs to');
        }
        if ($this->store->hit("addr:$id", 60, $now) > self::PUSHES_PER_MINUTE) {
            return Response::text(429, 'Too many notifications, try again later');
        }
        $headers = ['apns-push-type' => 'alert',
                    'apns-priority' => in_array(strtolower($r->header('Urgency')), ['', 'high'], true) ? '10' : '5'];
        $ttl = (int) $r->header('TTL');
        if ($ttl > 0) {
            $headers['apns-expiration'] = (string) ($now + $ttl);
        }
        $payload = ['aps' => ['alert' => ['title-loc-key' => 'PUSH_FALLBACK_TITLE', 'loc-key' => 'PUSH_FALLBACK_BODY'],
                              'mutable-content' => 1, 'sound' => 'default'],
                    'a' => $id, 'm' => base64_encode($r->body)];
        $result = $this->apns->send($a['token'], $a['env'], $payload, $headers);
        if ($result->status === 200) {
            $this->store->touch($id, $now);
            return new Response(201);
        }
        if ($result->status === 410 || ($result->status === 400 && in_array($result->reason, self::DEAD_TOKEN, true))) {
            $this->store->deleteAddress($id);
            return Response::text(410, 'The phone is gone');   // the computer drops the subscription
        }
        error_log("ferry relay: APNs {$result->status} {$result->reason}");
        return Response::text(502, 'APNs refused it');
    }

    private function authorized(Request $r, string $secretHash): bool
    {
        $given = preg_match('/^Bearer\s+(\S+)$/', $r->header('Authorization'), $m) === 1 ? $m[1] : '';
        return $given !== '' && hash_equals($secretHash, hash('sha256', $given));
    }
}

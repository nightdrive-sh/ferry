<?php

declare(strict_types=1);

namespace Ferry\Relay\Tests;

use Ferry\Relay\ApnsResult;
use Ferry\Relay\ApnsSender;
use Ferry\Relay\Es256;
use Ferry\Relay\Relay;
use Ferry\Relay\Request;
use Ferry\Relay\Response;
use Ferry\Relay\Store;
use OpenSSLAsymmetricKey;
use PDO;
use PHPUnit\Framework\TestCase;

/** APNs in memory: records what it was asked and answers what the test set. */
final class FakeApns implements ApnsSender
{
    /** @var list<array{token: string, env: string, payload: array<string, mixed>, headers: array<string, string>}> */
    public array $sent = [];
    public ApnsResult $answer;

    public function __construct()
    {
        $this->answer = new ApnsResult(200);
    }

    public function send(string $token, string $env, array $payload, array $headers): ApnsResult
    {
        $this->sent[] = compact('token', 'env', 'payload', 'headers');
        return $this->answer;
    }
}

abstract class RelayTestCase extends TestCase
{
    protected const ORIGIN = 'https://push.nightdrive.sh';
    protected const TOKEN = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    protected Store $store;
    protected FakeApns $apns;
    protected Relay $relay;
    protected int $now = 1_800_000_000;

    protected function setUp(): void
    {
        ini_set('error_log', '/dev/null');   // the relay logs APNs failures; the tests provoke them
        $this->store = new Store(new PDO('sqlite::memory:'));
        $this->apns = new FakeApns();
        $this->relay = new Relay($this->store, $this->apns, self::ORIGIN, fn (): int => $this->now);
    }

    /** @param array<string, string> $headers */
    protected function call(string $method, string $path, string $body = '', array $headers = [], string $ip = '198.51.100.7'): Response
    {
        return $this->relay->handle(new Request($method, $path, array_change_key_case($headers), $body, $ip));
    }

    /** @return array{0: OpenSSLAsymmetricKey, 1: string} a computer's VAPID key and its public point, base64url */
    protected function vapidKey(): array
    {
        $key = openssl_pkey_new(['curve_name' => 'prime256v1', 'private_key_type' => OPENSSL_KEYTYPE_EC]);
        $ec = openssl_pkey_get_details($key)['ec'];
        $point = "\x04" . str_pad($ec['x'], 32, "\0", STR_PAD_LEFT) . str_pad($ec['y'], 32, "\0", STR_PAD_LEFT);
        return [$key, Es256::b64u($point)];
    }

    /** The Authorization header bin/ferry's vapid_auth() writes. */
    protected function vapidHeader(OpenSSLAsymmetricKey $key, string $point, ?string $aud = null, ?int $exp = null): string
    {
        $head = Es256::b64u((string) json_encode(['typ' => 'JWT', 'alg' => 'ES256']));
        $claims = Es256::b64u((string) json_encode(['aud' => $aud ?? self::ORIGIN, 'exp' => $exp ?? $this->now + 3600,
                                                    'sub' => 'https://github.com/nightdrive-sh/ferry']));
        $signing = "$head.$claims";
        return "vapid t=$signing." . Es256::b64u(Es256::sign($signing, $key)) . ", k=$point";
    }

    /** @return array{endpoint: string, secret: string, id: string} */
    protected function register(string $vapid, string $ip = '198.51.100.7'): array
    {
        $r = $this->call('POST', '/v1/register', (string) json_encode(['token' => self::TOKEN, 'env' => 'sandbox', 'vapid' => $vapid]),
                         ip: $ip);
        $this->assertSame(201, $r->status, $r->body);
        $a = json_decode($r->body, true);
        $a['id'] = basename($a['endpoint']);
        return $a;
    }
}

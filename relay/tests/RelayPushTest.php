<?php

declare(strict_types=1);

namespace Ferry\Relay\Tests;

use Ferry\Relay\ApnsResult;

final class RelayPushTest extends RelayTestCase
{
    /** @return array{0: array{endpoint: string, secret: string, id: string}, 1: string} the address and a valid header */
    private function address(): array
    {
        [$key, $point] = $this->vapidKey();
        return [$this->register($point), $this->vapidHeader($key, $point)];
    }

    /** @param array<string, string> $extra */
    private function push(string $id, string $auth, string $body, array $extra = [], string $ip = '192.0.2.4'): int
    {
        return $this->call('POST', "/push/$id", $body, $extra + ['Authorization' => $auth, 'Content-Encoding' => 'aes128gcm',
                                                                'Content-Type' => 'application/octet-stream', 'TTL' => '604800',
                                                                'Urgency' => 'high'], $ip)->status;
    }

    public function testPushForwardsToApns(): void
    {
        [$a, $auth] = $this->address();
        $body = random_bytes(500);
        $this->assertSame(201, $this->push($a['id'], $auth, $body));
        $this->assertCount(1, $this->apns->sent);
        $sent = $this->apns->sent[0];
        $this->assertSame(self::TOKEN, $sent['token']);
        $this->assertSame('sandbox', $sent['env']);
        $this->assertSame('alert', $sent['headers']['apns-push-type']);
        $this->assertSame('10', $sent['headers']['apns-priority']);
        $this->assertSame(base64_encode($body), $sent['payload']['m']);
        $this->assertSame($a['id'], $sent['payload']['a']);
        $this->assertSame(1, $sent['payload']['aps']['mutable-content']);
        $this->assertSame('PUSH_FALLBACK_BODY', $sent['payload']['aps']['alert']['loc-key']);
        $this->assertSame('PUSH_FALLBACK_TITLE', $sent['payload']['aps']['alert']['title-loc-key']);
        $this->assertLessThanOrEqual(4096, strlen((string) json_encode($sent['payload'])));
        $this->assertSame($this->now, $this->store->address($a['id'])['last_push']);
    }

    public function testTheLargestBodyFitsInApns(): void
    {
        [$a, $auth] = $this->address();
        $this->assertSame(201, $this->push($a['id'], $auth, random_bytes(2800)));
        $this->assertLessThanOrEqual(4096, strlen((string) json_encode($this->apns->sent[0]['payload'], JSON_UNESCAPED_SLASHES)));
    }

    public function testTtlAndUrgency(): void
    {
        [$a, $auth] = $this->address();
        $this->push($a['id'], $auth, 'x', ['TTL' => '60', 'Urgency' => 'low']);
        $this->assertSame((string) ($this->now + 60), $this->apns->sent[0]['headers']['apns-expiration']);
        $this->assertSame('5', $this->apns->sent[0]['headers']['apns-priority']);
    }

    public function testPushRejects(): void
    {
        [$a, $auth] = $this->address();
        [$key, $point] = $this->vapidKey();
        $this->assertSame(404, $this->push('unknown', $auth, 'x'));
        $this->assertSame(403, $this->push($a['id'], $this->vapidHeader($key, $point), 'x'));
        $this->assertSame(403, $this->push($a['id'], '', 'x'));
        $this->assertSame(413, $this->push($a['id'], $auth, random_bytes(2801)));
        $this->assertSame(400, $this->push($a['id'], $auth, 'x', ['Content-Encoding' => 'aesgcm']));
        $this->assertSame([], $this->apns->sent);
    }

    public function testPushRateLimitedPerAddress(): void
    {
        [$a, $auth] = $this->address();
        for ($i = 0; $i < 30; $i++) {
            $this->assertSame(201, $this->push($a['id'], $auth, 'x'));
        }
        $this->assertSame(429, $this->push($a['id'], $auth, 'x'));
        $this->now += 61;
        $this->assertSame(201, $this->push($a['id'], $auth, 'x'));
    }

    public function testPushRateLimitedPerIp(): void
    {
        $addresses = [];
        for ($i = 0; $i < 21; $i++) {   // 30 a minute per address: 21 addresses for 601 pushes
            $addresses[] = $this->address();
            $this->now += 121;   // registration is limited too: 30 an hour per IP
        }
        $sent = 0;
        foreach ($addresses as [$a, $auth]) {
            for ($j = 0; $j < 30 && $sent < 600; $j++, $sent++) {
                $this->assertSame(201, $this->push($a['id'], $auth, 'x'));
            }
        }
        [$a, $auth] = $addresses[20];
        $this->assertSame(429, $this->push($a['id'], $auth, 'x'));
        $this->assertSame(201, $this->push($a['id'], $auth, 'x', ip: '192.0.2.200'));
    }

    public function testDeadTokenIs410AndForgotten(): void
    {
        foreach ([new ApnsResult(410, 'Unregistered'), new ApnsResult(400, 'BadDeviceToken'),
                  new ApnsResult(400, 'DeviceTokenNotForTopic')] as $answer) {
            [$a, $auth] = $this->address();
            $this->apns->answer = $answer;
            $this->assertSame(410, $this->push($a['id'], $auth, 'x'), $answer->reason);
            $this->assertNull($this->store->address($a['id']));
        }
    }

    public function testApnsFailureIs502AndKept(): void
    {
        [$a, $auth] = $this->address();
        $this->apns->answer = new ApnsResult(500, 'InternalServerError');
        $this->assertSame(502, $this->push($a['id'], $auth, 'x'));
        $this->assertNotNull($this->store->address($a['id']));
    }
}

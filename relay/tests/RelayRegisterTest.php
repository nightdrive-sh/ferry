<?php

declare(strict_types=1);

namespace Ferry\Relay\Tests;

final class RelayRegisterTest extends RelayTestCase
{
    public function testRegisterReturnsEndpointAndSecret(): void
    {
        [, $point] = $this->vapidKey();
        $a = $this->register($point);
        $this->assertStringStartsWith('https://push.nightdrive.sh/push/', $a['endpoint']);
        $this->assertMatchesRegularExpression('/^[A-Za-z0-9_-]{22}$/', $a['id']);
        $this->assertGreaterThanOrEqual(22, strlen($a['secret']));
        $row = $this->store->address($a['id']);
        $this->assertNotNull($row);
        $this->assertSame(self::TOKEN, $row['token']);
        $this->assertSame('sandbox', $row['env']);
        $this->assertSame($point, $row['vapid']);
        $this->assertNotSame($a['secret'], $row['secret_hash']);   // kept as a hash
        $this->assertStringNotContainsString($a['secret'], json_encode($row));
    }

    public function testRegisterRejectsBadInput(): void
    {
        [, $point] = $this->vapidKey();
        $bad = [
            ['token' => 'not hex!', 'env' => 'sandbox', 'vapid' => $point],
            ['token' => self::TOKEN, 'env' => 'staging', 'vapid' => $point],
            ['token' => self::TOKEN, 'env' => 'sandbox', 'vapid' => 'BAAA'],
            ['token' => self::TOKEN, 'env' => 'sandbox', 'vapid' => str_repeat('A', 87)],   // 65 bytes, not a point
            ['token' => self::TOKEN, 'env' => 'sandbox'],
        ];
        foreach ($bad as $body) {
            $this->assertSame(400, $this->call('POST', '/v1/register', (string) json_encode($body))->status, json_encode($body));
        }
        $this->assertSame(400, $this->call('POST', '/v1/register', 'not json')->status);
        $this->assertSame(413, $this->call('POST', '/v1/register', str_repeat(' ', 1025))->status);
    }

    public function testRegisterRateLimitedPerIp(): void
    {
        [, $point] = $this->vapidKey();
        for ($i = 0; $i < 30; $i++) {
            $this->register($point);
        }
        $body = (string) json_encode(['token' => self::TOKEN, 'env' => 'sandbox', 'vapid' => $point]);
        $this->assertSame(429, $this->call('POST', '/v1/register', $body)->status);
        $this->assertSame(201, $this->call('POST', '/v1/register', $body, ip: '203.0.113.9')->status);   // another IP
        $this->now += 3601;
        $this->assertSame(201, $this->call('POST', '/v1/register', $body)->status);   // an hour later
    }

    public function testGetAndDeleteNeedTheSecret(): void
    {
        [, $point] = $this->vapidKey();
        $a = $this->register($point);
        $path = '/push/' . $a['id'];
        $this->assertSame(204, $this->call('GET', $path, headers: ['Authorization' => "Bearer {$a['secret']}"])->status);
        $this->assertSame(403, $this->call('GET', $path, headers: ['Authorization' => 'Bearer wrong'])->status);
        $this->assertSame(403, $this->call('GET', $path)->status);
        $this->assertSame(404, $this->call('GET', '/push/unknown', headers: ['Authorization' => 'Bearer x'])->status);
        $this->assertSame(403, $this->call('DELETE', $path, headers: ['Authorization' => 'Bearer wrong'])->status);
        $this->assertSame(204, $this->call('DELETE', $path, headers: ['Authorization' => "Bearer {$a['secret']}"])->status);
        $this->assertSame(404, $this->call('GET', $path, headers: ['Authorization' => "Bearer {$a['secret']}"])->status);
        $this->assertSame(204, $this->call('DELETE', '/push/unknown', headers: ['Authorization' => 'Bearer x'])->status);
    }

    public function testUnknownRoutesAre404(): void
    {
        $this->assertSame(404, $this->call('GET', '/')->status);
        $this->assertSame(404, $this->call('GET', '/v1/register')->status);
        $this->assertSame(404, $this->call('GET', '/data/relay.sqlite')->status);
    }
}

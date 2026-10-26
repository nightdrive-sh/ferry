<?php

declare(strict_types=1);

namespace Ferry\Relay\Tests;

use Ferry\Relay\Relay;
use Ferry\Relay\Request;
use Ferry\Relay\Store;
use PDO;

/** What the uptime monitor asks: answers only when PHP and the database both work. */
final class RelayHealthTest extends RelayTestCase
{
    public function testHealthIsOk(): void
    {
        $r = $this->call('GET', '/health');
        $this->assertSame(200, $r->status);
        $this->assertSame('ok', $r->body);
        $this->assertSame(405, $this->call('POST', '/health')->status);
    }

    public function testHealthFailsWithoutTheDatabase(): void
    {
        $pdo = new PDO('sqlite::memory:');
        $relay = new Relay(new Store($pdo), $this->apns, self::ORIGIN, fn (): int => $this->now);
        $pdo->exec('DROP TABLE addresses');
        $this->assertSame(500, $relay->handle(new Request('GET', '/health', [], '', '198.51.100.7'))->status);
    }
}

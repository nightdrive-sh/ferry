<?php

declare(strict_types=1);

namespace Ferry\Relay\Tests;

use Ferry\Relay\Vapid;

final class VapidTest extends RelayTestCase
{
    public function testAcceptsValid(): void
    {
        [$key, $point] = $this->vapidKey();
        $this->assertTrue(Vapid::verify($this->vapidHeader($key, $point), $point, self::ORIGIN, $this->now));
    }

    public function testRejectsWrongK(): void
    {
        [$key, $point] = $this->vapidKey();
        [, $other] = $this->vapidKey();
        $this->assertFalse(Vapid::verify($this->vapidHeader($key, $point), $other, self::ORIGIN, $this->now));
    }

    public function testRejectsASignatureByAnotherKey(): void   // k claims the bound key, but another key signed
    {
        [, $point] = $this->vapidKey();
        [$otherKey] = $this->vapidKey();
        $this->assertFalse(Vapid::verify($this->vapidHeader($otherKey, $point), $point, self::ORIGIN, $this->now));
    }

    public function testRejectsAnotherAudience(): void
    {
        [$key, $point] = $this->vapidKey();
        $h = $this->vapidHeader($key, $point, aud: 'https://web.push.apple.com');
        $this->assertFalse(Vapid::verify($h, $point, self::ORIGIN, $this->now));
    }

    public function testRejectsExpired(): void
    {
        [$key, $point] = $this->vapidKey();
        $h = $this->vapidHeader($key, $point, exp: $this->now - 1);
        $this->assertFalse(Vapid::verify($h, $point, self::ORIGIN, $this->now));
    }

    public function testRejectsMissingOrMalformed(): void
    {
        [, $point] = $this->vapidKey();
        foreach (['', 'Bearer abc', 'vapid t=abc, k=' . $point, 'vapid t=a.b.c, k=' . $point, "vapid k=$point"] as $h) {
            $this->assertFalse(Vapid::verify($h, $point, self::ORIGIN, $this->now), $h);
        }
    }
}

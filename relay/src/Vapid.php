<?php

declare(strict_types=1);

namespace Ferry\Relay;

/**
 * VAPID (RFC 8292) as a computer sends it: `Authorization: vapid t=<JWT>, k=<public key>`. The relay accepts a push
 * only when it is signed by the key its address was bound to, so an address that leaks is no use to anyone else.
 */
final class Vapid
{
    public static function verify(string $header, string $boundKey, string $origin, int $now): bool
    {
        if (preg_match('/^vapid\s+(.*)$/i', trim($header), $m) !== 1) {
            return false;
        }
        $params = [];
        foreach (explode(',', $m[1]) as $part) {
            [$k, $v] = array_pad(explode('=', trim($part), 2), 2, '');
            $params[strtolower($k)] = $v;
        }
        $jwt = explode('.', $params['t'] ?? '');
        if (($params['k'] ?? '') !== $boundKey || count($jwt) !== 3) {
            return false;
        }
        $key = Es256::publicKey($boundKey);
        $head = json_decode((string) Es256::unb64u($jwt[0]), true);
        $claims = json_decode((string) Es256::unb64u($jwt[1]), true);
        $signature = Es256::unb64u($jwt[2]);
        return $key !== null && is_array($head) && ($head['alg'] ?? '') === 'ES256'
            && is_array($claims) && ($claims['aud'] ?? '') === $origin
            && is_int($claims['exp'] ?? null) && $claims['exp'] > $now
            && $signature !== null && Es256::verify("$jwt[0].$jwt[1]", $signature, $key);
    }
}

<?php

declare(strict_types=1);

namespace Ferry\Relay;

use OpenSSLAsymmetricKey;

/**
 * ES256 for JWTs with OpenSSL alone: a JWT carries the signature as raw r‖s (64 bytes), OpenSSL wants DER, and a VAPID
 * key arrives as a bare P-256 point. No library: the relay has nothing to install on the server.
 */
final class Es256
{
    /** SubjectPublicKeyInfo for an uncompressed P-256 point, minus the point itself. */
    private const SPKI_PREFIX = '3059301306072a8648ce3d020106082a8648ce3d030107034200';

    public static function b64u(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }

    public static function unb64u(string $s): ?string
    {
        if (preg_match('/^[A-Za-z0-9_-]*$/', $s) !== 1) {
            return null;
        }
        $d = base64_decode(strtr($s, '-_', '+/'), true);
        return $d === false ? null : $d;
    }

    /** The public key for a base64url uncompressed point, or null when it isn't one on the curve. */
    public static function publicKey(string $point): ?OpenSSLAsymmetricKey
    {
        $raw = self::unb64u($point);
        if ($raw === null || strlen($raw) !== 65 || $raw[0] !== "\x04") {
            return null;
        }
        $pem = "-----BEGIN PUBLIC KEY-----\n"
            . chunk_split(base64_encode(hex2bin(self::SPKI_PREFIX) . $raw), 64, "\n")
            . "-----END PUBLIC KEY-----\n";
        $key = openssl_pkey_get_public($pem);
        return $key === false ? null : $key;
    }

    /** A raw r‖s signature. */
    public static function sign(string $data, OpenSSLAsymmetricKey $key): string
    {
        openssl_sign($data, $der, $key, OPENSSL_ALGO_SHA256);
        return self::derToRaw($der);
    }

    public static function verify(string $data, string $raw, OpenSSLAsymmetricKey $key): bool
    {
        return strlen($raw) === 64 && openssl_verify($data, self::rawToDer($raw), $key, OPENSSL_ALGO_SHA256) === 1;
    }

    private static function derToRaw(string $der): string
    {
        // SEQUENCE { INTEGER r, INTEGER s }, each possibly with a leading zero or shorter than 32 bytes
        $pos = 2 + (ord($der[1]) & 0x80 ? ord($der[1]) & 0x7f : 0);
        $out = '';
        for ($i = 0; $i < 2; $i++) {
            $len = ord($der[$pos + 1]);
            $int = ltrim(substr($der, $pos + 2, $len), "\0");
            $out .= str_pad($int, 32, "\0", STR_PAD_LEFT);
            $pos += 2 + $len;
        }
        return $out;
    }

    private static function rawToDer(string $raw): string
    {
        $ints = '';
        foreach (str_split($raw, 32) as $part) {
            $part = ltrim($part, "\0");
            if ($part === '' || ord($part[0]) & 0x80) {
                $part = "\0" . $part;   // DER integers are signed
            }
            $ints .= "\x02" . chr(strlen($part)) . $part;
        }
        return "\x30" . chr(strlen($ints)) . $ints;
    }
}

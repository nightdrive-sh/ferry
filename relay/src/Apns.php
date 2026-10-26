<?php

declare(strict_types=1);

namespace Ferry\Relay;

use RuntimeException;

final class ApnsResult
{
    public function __construct(public readonly int $status, public readonly string $reason = '')
    {
    }
}

interface ApnsSender
{
    /**
     * @param array<string, mixed> $payload
     * @param array<string, string> $headers
     */
    public function send(string $token, string $env, array $payload, array $headers): ApnsResult;
}

/**
 * APNs over HTTP/2 with a provider token: HTTP/2 isn't optional (APNs doesn't speak HTTP/1.1), and one token serves
 * ~50 minutes (Apple accepts it for an hour and refuses renewals more often than every 20 minutes).
 */
final class CurlApns implements ApnsSender
{
    private const HOSTS = ['production' => 'https://api.push.apple.com', 'sandbox' => 'https://api.sandbox.push.apple.com'];
    private const TOKEN_TTL = 3000;

    public function __construct(
        private readonly string $keyId,
        private readonly string $teamId,
        private readonly string $keyPath,
        private readonly string $topic,
        private readonly Store $store,
    ) {
    }

    public function send(string $token, string $env, array $payload, array $headers): ApnsResult
    {
        $lines = ['authorization: bearer ' . $this->providerToken(), "apns-topic: {$this->topic}",
                  'content-type: application/json'];
        foreach ($headers as $k => $v) {
            $lines[] = "$k: $v";
        }
        $ch = curl_init(self::HOSTS[$env] . '/3/device/' . $token);
        curl_setopt_array($ch, [
            CURLOPT_HTTP_VERSION => CURL_HTTP_VERSION_2_0,
            CURLOPT_POST => true,
            CURLOPT_POSTFIELDS => json_encode($payload, JSON_UNESCAPED_SLASHES),
            CURLOPT_HTTPHEADER => $lines,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 10,
        ]);
        $body = curl_exec($ch);
        $status = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        if ($body === false) {
            return new ApnsResult(0, curl_error($ch));
        }
        return new ApnsResult($status, (string) (json_decode((string) $body, true)['reason'] ?? ''));
    }

    private function providerToken(): string
    {
        $cached = json_decode($this->store->meta('apns-token') ?? '', true);
        if (is_array($cached) && $cached['kid'] === $this->keyId && $cached['iat'] > time() - self::TOKEN_TTL) {
            return $cached['token'];
        }
        $key = is_readable($this->keyPath) ? openssl_pkey_get_private((string) file_get_contents($this->keyPath)) : false;
        if ($key === false || $this->keyId === '') {
            throw new RuntimeException('The APNs key is missing (APNS_KEY_ID / APNS_KEY_PATH)');
        }
        $iat = time();
        $signing = Es256::b64u((string) json_encode(['alg' => 'ES256', 'kid' => $this->keyId]))
            . '.' . Es256::b64u((string) json_encode(['iss' => $this->teamId, 'iat' => $iat]));
        $token = $signing . '.' . Es256::b64u(Es256::sign($signing, $key));
        $this->store->setMeta('apns-token', (string) json_encode(['kid' => $this->keyId, 'iat' => $iat, 'token' => $token]));
        return $token;
    }
}

/** For development: hands the push to a simulator with `xcrun simctl push`, which needs no Apple key at all. */
final class SimctlApns implements ApnsSender
{
    public function __construct(private readonly string $simulator, private readonly string $topic)
    {
    }

    public function send(string $token, string $env, array $payload, array $headers): ApnsResult
    {
        $file = tempnam(sys_get_temp_dir(), 'ferry-push');
        file_put_contents($file, json_encode($payload + ['Simulator Target Bundle' => $this->topic], JSON_UNESCAPED_SLASHES));
        $cmd = 'DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun simctl push '
            . escapeshellarg($this->simulator) . ' ' . escapeshellarg($this->topic) . ' ' . escapeshellarg($file) . ' 2>&1';
        exec($cmd, $out, $code);
        unlink($file);
        return $code === 0 ? new ApnsResult(200) : new ApnsResult(500, implode(' ', $out));
    }
}

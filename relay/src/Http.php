<?php

declare(strict_types=1);

namespace Ferry\Relay;

final class Request
{
    /** @param array<string, string> $headers lowercase names */
    public function __construct(
        public readonly string $method,
        public readonly string $path,
        public readonly array $headers,
        public readonly string $body,
        public readonly string $ip,
    ) {
    }

    public function header(string $name): string
    {
        return $this->headers[strtolower($name)] ?? '';
    }

    public static function fromGlobals(): self
    {
        $headers = [];
        foreach ($_SERVER as $k => $v) {
            if (str_starts_with($k, 'HTTP_')) {
                $headers[strtolower(str_replace('_', '-', substr($k, 5)))] = (string) $v;
            }
        }
        foreach (['CONTENT_TYPE' => 'content-type', 'CONTENT_LENGTH' => 'content-length'] as $k => $name) {
            if (isset($_SERVER[$k])) {
                $headers[$name] = (string) $_SERVER[$k];
            }
        }
        // One byte over the largest body a route takes is enough to refuse it
        $body = (string) stream_get_contents(fopen('php://input', 'rb'), Relay::MAX_PUSH + 1);
        return new self((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET'),
                        (string) parse_url((string) ($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH),
                        $headers, $body, (string) ($_SERVER['REMOTE_ADDR'] ?? ''));
    }
}

/** An answer: JSON, or a plain-text error written for a person, like Ferry's own protocol. */
final class Response
{
    /** @param array<string, string> $headers */
    public function __construct(public readonly int $status, public readonly string $body = '', public readonly array $headers = [])
    {
    }

    /** @param array<string, mixed> $data */
    public static function json(int $status, array $data): self
    {
        return new self($status, (string) json_encode($data, JSON_UNESCAPED_SLASHES), ['Content-Type' => 'application/json']);
    }

    public static function text(int $status, string $text): self
    {
        return new self($status, $text, ['Content-Type' => 'text/plain; charset=utf-8']);
    }

    public function emit(): void
    {
        http_response_code($this->status);
        foreach ($this->headers as $k => $v) {
            header("$k: $v");
        }
        echo $this->body;
    }
}

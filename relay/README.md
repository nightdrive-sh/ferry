# Ferry's push relay

The small service at `https://push.nightdrive.sh` that lets a computer running Ferry notify the iPhone app. Apple's push
key can't be given to every computer, so the relay holds it, and passes on what it can't read:

- The phone registers an address per computer, bound to that computer's VAPID key (`POST /v1/register`).
- The computer sends its notification there as Web Push (RFC 8030/8291/8292): encrypted for the phone, signed with its
  VAPID key, exactly what it would send a browser's push service.
- The relay checks the signature, size and rate, and hands the encrypted bytes to APNs. The app's notification extension
  decrypts them.
- `GET /health` answers `200 ok` when PHP and the database work, for the uptime monitor.

It keeps only `address → APNs token, environment, VAPID key, the secret's hash` and rate counters (IPs as salted hashes):
no content, and nothing expires until the app deletes the address or Apple says its token is dead. Feature Design Oy runs
it.

## API

Every answer is JSON, every error a status with a plain-text body, like Ferry's own protocol (`docs/protocol.md`).

**`POST /v1/register`**, from the app:
```json
{"token": "<APNs device token, hex>", "env": "production" | "sandbox", "vapid": "<the computer's VAPID public key, base64url>"}
```
→ `201 {"endpoint": "https://push.nightdrive.sh/push/<id>", "secret": "<random>"}`. The `id` is 128 random bits, the
secret is kept only as a hash. `env` comes from the app's own signing (its `aps-environment`), not from Debug or
Release: a wrong one gives `BadDeviceToken`, which deletes the address. 400 for a malformed token or key, 413 over 1 KiB,
429 over 30 registrations an hour per IP.

**`GET /push/<id>`** with `Authorization: Bearer <secret>`, from the app: 204 if the address exists, 404 if not, so
the app notices an address the relay dropped and registers again.

**`DELETE /push/<id>`** with `Authorization: Bearer <secret>`, from the app, when a computer is removed, notifications
are turned off or the token changed: 204, for an unknown id too.

**`POST /push/<id>`**, from a computer: a Web Push message (RFC 8030/8291/8292), what it would send a browser's push
service.
- `Authorization: vapid t=<JWT>, k=<key>`: `k` must be the key the address was made for, and the JWT must verify with
  it (ES256), name the relay's origin as `aud` and not have expired. Else 403.
- `Content-Encoding: aes128gcm`, and a body of 2800 bytes at most (base64 in the APNs payload must stay under its
  4096-byte limit), else 413. The encrypted body is the plaintext plus 103 bytes.
- `TTL` becomes `apns-expiration`; `Urgency: high` (or none) priority 10, anything lower priority 5.
- 201 when Apple has it. 404 for an unknown address and 410 when Apple says the token is dead (the address is then
  deleted): either drops the computer's subscription. 429 over 30 pushes a minute per address or 600 an hour per
  sending IP, 502 when Apple refuses it otherwise.

**What the phone gets:**
```json
{"aps": {"alert": {"title-loc-key": "PUSH_FALLBACK_TITLE", "loc-key": "PUSH_FALLBACK_BODY"},
         "mutable-content": 1, "sound": "default"},
 "a": "<address id>", "m": "<the encrypted body, base64>"}
```
The fallback is given as localisation keys, so it shows in the phone's language; the notification extension decrypts
`m` with the keys of the computer it finds from `a`.

## Running it

Plain PHP 8.4 with `pdo_sqlite`, `openssl` and `curl`. No library at run time; Composer brings only PHPUnit.

```
composer install
vendor/bin/phpunit
FERRY_RELAY_DB=/tmp/relay.sqlite FERRY_RELAY_ORIGIN=http://127.0.0.1:47280 FERRY_RELAY_APNS=simctl \
  FERRY_RELAY_SIMULATOR=<simulator id> php -S 127.0.0.1:47280 -t public
```

| Variable | |
| --- | --- |
| `FERRY_RELAY_ORIGIN` | The relay's own origin, which a VAPID JWT's `aud` must name. Default `https://push.nightdrive.sh` |
| `FERRY_RELAY_DB` | The SQLite file. Default `data/relay.sqlite` beside `public/` |
| `FERRY_RELAY_APNS` | `curl` (APNs) or `simctl` (hands pushes to a simulator with `xcrun simctl push`, no key needed) |
| `FERRY_RELAY_SIMULATOR` | simctl: the simulator's id (default `booted`) |
| `APNS_KEY_ID`, `APNS_KEY_PATH`, `APNS_TEAM_ID` | The team's APNs key (`.p8`), kept outside the code. Team defaults to `279G2UNHPN` |

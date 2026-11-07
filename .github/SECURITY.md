# Security

Ferry carries text, passwords copied to the clipboard and files between your devices, runs a server on each computer
that Tailscale publishes to your tailnet, and puts what arrives on the clipboard or in Downloads, so a security
problem in it matters. Thank you for reporting one.

## Supported versions

| Version                                                         | Supported          |
| --------------------------------------------------------------- | ------------------ |
| The latest release (the newest `vX.Y.Z` tag), on every platform | Yes                |
| The latest beta (`vX.Y.Z-beta.N`), for those who run betas      | Yes                |
| `dev`                                                           | Yes                |
| Older releases                                                  | No: update (below) |

Fixes are made in `dev` and reach users in the next release, sooner if the problem is serious. To update: the Mac app
updates itself (or **Check for Updates…** in its popover's menu); on Linux, `ferry update`, or `nightdrive update` where
Nightdrive installed Ferry; the iPhone app from the App Store or TestFlight.

A Linux release's files are listed with their sha256 in its `SHA256SUMS`: check a download with
`sha256sum -c SHA256SUMS --ignore-missing`. The Mac's `.dmg` is Developer ID signed and notarized by Apple, and its
updates are signed with Ferry's own key.

## Reporting a vulnerability

Please don't open a public issue or discussion for a vulnerability.

- **On GitHub:** this repository's **Security** tab › **Report a vulnerability**. Only the maintainer sees the report.
- **By email**, if you can't use GitHub: security@nightdrive.sh.

Tell what you found, how to reproduce it and what it lets someone do. The version (`ferry version` on Linux, the
Mac app's Settings, the iPhone app's Settings) and your system help.

## What happens next

- You get a reply within a week.
- Once the problem is confirmed, it is fixed and released, and you hear when.
- The fix is announced in the release notes, with your name if you'd like.

How soon a fix is released, counted from the confirmation:

| Severity                                                                                                      | Fix released                           |
| ------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| Critical: someone outside your tailnet, or another of its users, reaches your devices or what you send, or runs code on them, with no step of yours | Within 7 days, in a release of its own |
| High: the same, but it needs a step of yours, or it reaches only what Ferry itself can                        | Within 30 days                         |
| Medium and low                                                                                                | In the next release                    |

A one-person project can miss these: if it does, you hear why and when instead.

## The EU's Cyber Resilience Act and NIS2

Ferry is free, open-source software, made and given away without payment, sales, paid support or data collection.
As we understand them, the Cyber Resilience Act (EU 2024/2847) doesn't apply to free software that isn't supplied in
the course of a commercial activity, and NIS2 (EU 2022/2555) concerns organisations in its sectors, not software like
this. Ferry therefore makes no CRA declaration of conformity. It still handles vulnerabilities as above, which is
what the Act asks of those it applies to. This is our reading, not legal advice.

# Changelog

All important changes to Upbar are in this file. The format is from [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Upbar uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Upbar reads Coolify webhooks: the app name, the environment, success or failure, and a link to the deployment. README section 9.3 shows the setup.
- Request traces: the editor shows the DNS, connect, TLS and server time of the last request, with the protocol, TLS version and IP address.
- Upbar shows when the TLS certificate expires and sends a notification 14 days before.
- The editor counts the incidents of the last 24 hours and shows the mean time to recovery (MTTR).
- The release workflow can sign the app with a Developer ID certificate and send it to Apple for notarization.
- The editor has a **Test now** button. It shows the status code and the response time of the endpoint.
- Upbar keeps the check results of the last 24 hours on disk. The editor shows the uptime and the p50, p95 and p99 response times.
- The window groups the endpoints by website. Click a website to fold it.
- Events: Upbar can receive events from deploys, CI jobs and scripts on port 4747. It shows them in an Events list and sends a notification. No other server is involved. The receiver is off by default and needs a token.

### Changed

- The receiver token is in a private file, not in the Keychain. Updates no longer ask for your password. Upbar makes a new token once, so copy the test command again.
- The Events tab has a **Receiving** switch to turn the receiver off.
- When another app holds port 4747, Upbar says so and tries again every 5 seconds.
- The test command uses the Tailscale address of the Mac when Tailscale is on.
- The editor uses grouped sections and a title bar with **Cancel** and **Save**.
- The window has a solid background and one fixed size. The list and the editor scroll inside it.
- The Events tab and empty lists use native empty states.
- New look: a status ring and tint in the header, pill tabs, website cards with letter tiles, and a 24-hour response time chart in the editor. Upbar has no new dependencies; the chart uses Swift Charts.
- The response-time bars use 2 times the median as the full height. Thus, small changes are visible.

### Fixed

- Idle CPU is 0%. The "checked N seconds ago" text re-laid out the window every second, also while it was closed (5% CPU). Times now update once a minute.
- Typing in the editor no longer sorts the history and redraws the chart on each keystroke.
- A request with a negative `Content-Length` crashed the receiver.
- The receiver drops a connection that sends no complete request in 10 seconds.
- The receiver rebinds port 4747 right after a restart, without waiting for the old socket to time out.

## [0.1.1] - 2026-10-04

### Fixed

- Upbar stopped immediately after it started when it was built with Swift 6.1. The notification and network callbacks no longer run on the wrong thread.

### Added

- The CI and release workflows start the app and make sure that it keeps running.

## [0.1.0] - 2026-10-04

### Added

- Menu bar icon that shows the response times of the last 7 checks.
- Window with the status, the response time and the check history of each endpoint.
- Notifications when an endpoint goes down and when it is up again.
- Procedures to add, edit and delete endpoints, with an expected status code for each endpoint.
- Checks with `HEAD` requests. A `GET` request confirms each unexpected status code.
- Automatic stop of all checks while the Mac is offline.
- Open at Login setting.
- Installation script that does not use `sudo` and that compares a SHA-256 checksum.

[Unreleased]: https://github.com/josephgoksu/upbar/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/josephgoksu/upbar/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/josephgoksu/upbar/releases/tag/v0.1.0

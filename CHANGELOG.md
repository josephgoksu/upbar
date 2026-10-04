# Changelog

All important changes to Upbar are in this file. The format is from [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Upbar uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.2] - 2026-10-04

### Added

- Detail page: click an endpoint to see the status, uptime, failed checks, mean, p50, p90, p95, p99, fastest and slowest check, a 24-hour chart, incidents with MTTR and the last request.
- Request trace: DNS, connect, TLS and server time, protocol, TLS version and IP address.
- Certificate expiry date, with a notification 14 days before.
- Events: Upbar receives events from deploys, CI jobs and scripts on port 4747. The receiver is off by default and needs a token.
- Coolify webhooks show the app name, the environment, the result and a link to the deployment.
- Website groups that you can fold.
- **Test now** in the editor.
- The **⋯** menu shows the CPU and memory use of Upbar.
- The release workflow can sign and notarize the app with a Developer ID.

### Changed

- New design: status ring, pill tabs, website cards and one fixed window size.
- A click on an endpoint opens the detail page. The compass icon and the right-click menu open the URL in the browser.
- Upbar keeps the check results of the last 24 hours on disk.
- The receiver token is in a private file, not in the Keychain. Updates do not ask for your password.

### Fixed

- Idle CPU use was 5%. A relative time redrew the window every second. Now it is 0% between checks.
- A request with a negative `Content-Length` stopped the receiver.
- The receiver closes a connection after 10 seconds without a complete request.
- When another app uses port 4747, Upbar shows a message and tries again every 5 seconds.

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

[Unreleased]: https://github.com/josephgoksu/upbar/compare/v0.1.2...HEAD
[0.1.2]: https://github.com/josephgoksu/upbar/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/josephgoksu/upbar/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/josephgoksu/upbar/releases/tag/v0.1.0

# Changelog

All important changes to Upbar are in this file. The format is from [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Upbar uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The release workflow can sign the app with a Developer ID certificate and send it to Apple for notarization.

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

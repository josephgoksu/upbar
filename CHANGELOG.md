# Changelog

All important changes to Upbar are in this file. The format is from [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Upbar uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

[Unreleased]: https://github.com/josephgoksu/upbar/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/josephgoksu/upbar/releases/tag/v0.1.0

# Security policy

## 1. Supported versions

Only the latest release gets security fixes.

## 2. Report a vulnerability

> [!CAUTION]
> Do not report a vulnerability in a public issue.

1. Go to the [Security tab](https://github.com/josephgoksu/upbar/security) of the repository.
2. Click **Report a vulnerability**.
3. Describe the problem, the affected version and the steps to reproduce it.
4. Submit the report.

Result: You get a response in 7 days. When a fix is available, we publish a release and a security advisory.

## 3. Scope

Upbar sends requests only to the URLs that the user adds. Upbar keeps one credential: the receiver token, in `~/Library/Application Support/Upbar/receiver-token` with mode 0600. These items are in scope:

- The app (`Sources/`)
- The event receiver on port 4747 (`Sources/Upbar/Events.swift`)
- The installation script (`install.sh`)
- The build and release workflows (`build.sh`, `.github/workflows/`)

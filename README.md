<p align="center"><img src="docs/icon.png" width="128" alt="Upbar icon"></p>

<h1 align="center">Upbar</h1>

<p align="center">Uptime checks in your macOS menu bar.</p>

<p align="center">
  <a href="https://github.com/josephgoksu/upbar/releases/latest"><img src="https://img.shields.io/github/v/release/josephgoksu/upbar" alt="Latest release"></a>
  <a href="https://github.com/josephgoksu/upbar/actions/workflows/ci.yml"><img src="https://github.com/josephgoksu/upbar/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14 or later">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/josephgoksu/upbar" alt="MIT license"></a>
</p>

<p align="center"><img src="docs/screenshot.png" width="340" alt="The Upbar window shows six endpoints. One endpoint is down."></p>

## 1. General

Upbar is a macOS menu bar app. It monitors the HTTP endpoints that you add. Upbar sends a notification when an endpoint goes down. It sends a notification when the endpoint is up again.

Features:

- The menu bar icon shows the response times of the last 7 checks.
- Each endpoint shows the response times of its last 30 checks.
- You can set the HTTP status code that each endpoint must return.
- Upbar uses a small quantity of memory, CPU and network. Refer to [section 6](#6-resource-use).
- Upbar does not collect data. Refer to [section 7](#7-privacy).
- The source code is one Swift file. It has no dependencies.

## 2. Requirements

| Item | Requirement |
|---|---|
| Operating system | macOS 14 (Sonoma) or later |
| Processor | Apple silicon or Intel |
| Permissions | No administrator password is necessary |

## 3. Installation

### 3.1 Install with Terminal (recommended)

1. Open the Terminal app.
2. Type this command:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/josephgoksu/upbar/main/install.sh | sh
   ```

3. Push the Return key.

Result: Upbar is in `~/Applications`. The Upbar icon shows in the menu bar.

> [!NOTE]
> The script does not use `sudo`. It compares the download with a SHA-256 checksum before it installs the app.

### 3.2 Install from a browser download

1. Download `Upbar.zip` from the [latest release](https://github.com/josephgoksu/upbar/releases/latest).
2. Open `Upbar.zip`.
3. Move `Upbar.app` to the Applications folder.
4. Right-click `Upbar.app`, then select **Open**.
5. In the dialog box, click **Open**.

> [!NOTE]
> Do steps 4 and 5 one time only. Apple does not notarize Upbar at this time. Thus, macOS blocks the first start of an app that you download with a browser.

### 3.3 Allow notifications

When Upbar starts for the first time, macOS shows a notification request.

1. In the request, click **Allow**.

## 4. Operation

### 4.1 Open the Upbar window

1. Click the Upbar icon in the menu bar.

### 4.2 Add an endpoint

1. Open the Upbar window.
2. Click **+ Add**. The keyboard shortcut is ⌘N.
3. In the **URL** field, type or paste the URL of the endpoint.
4. Optional: In the **Name** field, type a name. If you do not type a name, Upbar uses the host name.
5. Optional: In the **Expect** field, type the HTTP status code that the endpoint must return. The default is 200.
6. Click **Save**.

Result: Upbar checks the endpoint immediately. Then it checks the endpoint every 60 seconds.

> [!NOTE]
> If the URL does not start with `http://` or `https://`, Upbar adds `https://`.

### 4.3 Edit an endpoint

1. Open the Upbar window.
2. Move the pointer onto the endpoint.
3. Click the pencil icon. Alternatively, right-click the endpoint, then select **Edit**.
4. Change the URL, the name or the expected status code.
5. Click **Save**.

> [!NOTE]
> If you change only the name, Upbar keeps the check history. If you change the URL or the expected status code, Upbar removes the check history.

### 4.4 Delete an endpoint

> [!CAUTION]
> You cannot undo this procedure.

1. Open the Upbar window.
2. Move the pointer onto the endpoint.
3. Click the pencil icon.
4. Click **Delete**.
5. Click **Click again to delete**.

Alternatively, right-click the endpoint, then select **Delete**.

### 4.5 Check all endpoints now

1. Open the Upbar window.
2. Click the arrow icon at the top right. The keyboard shortcut is ⌘R.

### 4.6 Open an endpoint in the browser

1. Open the Upbar window.
2. Click the endpoint.

### 4.7 Start Upbar when you log in

1. Open the Upbar window.
2. Click the **⋯** icon at the bottom right.
3. Select **Open at Login**.

### 4.8 Stop Upbar

1. Open the Upbar window.
2. Click the **⋯** icon at the bottom right.
3. Select **Quit Upbar**.

## 5. Indications

### 5.1 Menu bar icon

| Indication | Meaning |
|---|---|
| 7 bars in the menu bar color | All endpoints are up. The height of a bar shows the median response time of one check. |
| An orange bar | A check failed during that minute. No endpoint is down now. |
| Red bars and a number | The number shows how many endpoints are down. |
| Gray dots | Upbar has not completed 7 checks since it started. |

### 5.2 Endpoint status

| Indication | Meaning |
|---|---|
| Green dot | The endpoint is up. |
| Red dot and red text | The endpoint is down. The text shows the cause and the time since the endpoint went down. |
| Gray dot | Upbar has not checked the endpoint yet. |
| Orange response time | The response time is more than 1 second. |
| Red bar in the history | One check failed. |

### 5.3 Window header

| Indication | Meaning |
|---|---|
| **All systems operational** | All endpoints are up. |
| **2 of 6 down** | 2 endpoints are down. |
| **Offline** | The Mac has no network connection. Upbar stops all checks until the connection is available again. |

## 6. Resource use

These values are from a Mac with 10 endpoints.

| Resource | Value |
|---|---|
| Memory | Approximately 20 MB |
| CPU, between checks | 0% |
| Network, each minute | Approximately 60 KB for 10 endpoints |

Upbar decreases resource use in these ways:

- Each check is a `HEAD` request. Thus, the server does not send the page body.
- Upbar uses the same connection again for the next check.
- Upbar does not keep a cache or cookies.
- Upbar stops all checks while the Mac is offline.
- macOS can move a check by up to 10 seconds. This lets macOS do the check together with other tasks.

## 7. Privacy

- Upbar does not collect data.
- Upbar sends requests only to the endpoints that you add.
- Upbar keeps the list of endpoints on your Mac, in the `com.josephgoksu.upbar` preferences.
- Upbar does not keep cookies, a cache or the response bodies.

## 8. How Upbar checks an endpoint

1. Every 60 seconds, Upbar sends a `HEAD` request to each endpoint.
2. If the status code is the expected status code, the endpoint is up.
3. If the status code is different, Upbar sends a `GET` request. Upbar stops the request after it receives the headers.
4. If the status code of the `GET` request is different, the check fails.
5. After 2 failed checks in sequence, the endpoint is down. Upbar sends a notification.
6. When a check of a down endpoint is successful, the endpoint is up. Upbar sends a notification.

Rules:

- Upbar does not follow redirects. If an endpoint sends status 301, the status code is 301.
- A request that does not receive data for 10 seconds fails.
- A request that does not complete in 15 seconds fails.
- A connection error is a failed check.

## 9. Troubleshooting

| Problem | Possible cause | Action |
|---|---|---|
| Upbar sends no notifications. | Notifications for Upbar are off. | Open **System Settings > Notifications > Upbar**. Turn on **Allow notifications**. |
| macOS does not open Upbar. | You downloaded Upbar with a browser. | Do the procedure in [section 3.2](#32-install-from-a-browser-download). |
| An endpoint shows **HTTP 301** or **HTTP 302**. | The endpoint sends a redirect. Upbar does not follow redirects. | Use the final URL. Alternatively, set **Expect** to the redirect status code. |
| An `http://` endpoint shows the status of the `https://` page. | The site uses HSTS. macOS sends the request with `https://`. | Use the `https://` URL. |
| The header shows **Offline**. | The Mac has no network connection. | Connect the Mac to a network. Upbar starts the checks again automatically. |
| **Open at Login** does not stay on. | macOS must approve the login item. | Open **System Settings > General > Login Items**. Turn on **Upbar**. |
| The **Save** button is not available. | The URL or the expected status code is not correct. | Read the red text below the fields. Correct the value. |

## 10. Removal

1. Stop Upbar. Refer to [section 4.8](#48-stop-upbar).
2. In Terminal, type this command, then push the Return key:

   ```sh
   rm -rf ~/Applications/Upbar.app
   ```

3. Optional: To remove the list of endpoints, type this command, then push the Return key:

   ```sh
   defaults delete com.josephgoksu.upbar
   ```

## 11. Build from the source code

You must have Xcode 16 or the Command Line Tools with Swift 6.

| Command | Result |
|---|---|
| `swift run` | Builds and starts Upbar without an app bundle. Notifications show in Terminal. |
| `swift test` | Runs the tests. |
| `./build.sh` | Builds `dist/Upbar.app` for Apple silicon and Intel, and `dist/Upbar.zip`. |
| `./build.sh install` | Builds Upbar, installs it in `~/Applications`, and starts it. |
| `swift scripts/icon.swift` | Draws the app icon and the images in `docs/`. |

Files:

| Path | Content |
|---|---|
| `Sources/Upbar/Upbar.swift` | All of the app |
| `Tests/UpbarTests/` | Tests |
| `Resources/` | `Info.plist` and the app icon |
| `scripts/icon.swift` | The program that draws the icon |

## 12. Contribution, security and license

- To contribute, read [CONTRIBUTING.md](CONTRIBUTING.md).
- To report a security problem, read [SECURITY.md](SECURITY.md).
- For the list of changes, read [CHANGELOG.md](CHANGELOG.md).
- To make a release, read [docs/releasing.md](docs/releasing.md).
- Upbar has the [MIT license](LICENSE).

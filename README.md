# SparkBar

Native macOS menu-bar companion for [sparkDash](https://github.com/) that keeps the dashboard’s DGX Spark metrics one glance away.

SparkBar is deliberately read-only: it consumes `GET /api/sparks` for connection validation and a single `WS /ws` stream for live snapshots. It does not SSH, run shell commands, enumerate local processes, or administer a DGX Spark.

## Requirements

- macOS 14 Sonoma or newer
- Xcode 26.6 / Swift 6.3 or a compatible Swift 6 toolchain
- A sparkDash endpoint reachable from the Mac (the default development endpoint is `http://100.101.194.105:5555`)

## Build and test

```sh
swift build
swift test
./scripts/build-app.sh
open .build/Release/SparkBar.app
```

The package intentionally keeps the pure networking, decoding, selection, formatting, history, and alert logic in `SparkBarCore` so it can be tested without launching AppKit. The app target provides the native `NSStatusItem`, SwiftUI popover/settings window, launch-at-login integration, and notifications.

## Live smoke test

The endpoint can be checked without launching the app:

```sh
curl -i http://100.101.194.105:5555/api/sparks
curl -i http://100.101.194.105:5555/api/settings
swift run SparkBarSmoke http://100.101.194.105:5555
```

SparkBar’s UI accepts any `http://`, `https://`, `ws://`, or `wss://` base URL. HTTP maps to WS and HTTPS maps to WSS automatically.

HTTP is enabled in the app bundle because sparkDash is commonly reached over a trusted LAN or Tailscale network. SparkBar is read-only and restricts itself to the monitoring REST endpoints and `/ws`; use HTTPS/WSS or an authenticated reverse proxy when the endpoint is not on a trusted private network.

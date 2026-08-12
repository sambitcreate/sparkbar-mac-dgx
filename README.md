# SparkBar

Native macOS menu-bar companion for [sparkDash](https://github.com/MiaAI-Lab/sparkDash) that keeps the dashboard’s DGX Spark metrics one glance away.

SparkBar is deliberately read-only: it consumes `GET /api/sparks` for connection validation and a single `WS /ws` stream for live snapshots. It does not SSH, run shell commands, enumerate local processes, or administer a DGX Spark.

## Dependency: sparkDash

SparkBar depends on a running [sparkDash](https://github.com/MiaAI-Lab/sparkDash) instance. sparkDash performs the DGX Spark collection and exposes the REST/WebSocket API that SparkBar monitors. If it is not already running, install the recommended Docker deployment:

```sh
git clone https://github.com/MiaAI-Lab/sparkDash.git
cd sparkDash
docker compose up --build -d
```

Then connect SparkBar to `http://<sparkDash-host>:5555`. For a development checkout, use `npm install` followed by `npm run dev` instead. See the [sparkDash quick start](https://github.com/MiaAI-Lab/sparkDash#quick-start) for the complete setup and DGX configuration steps.

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

## CI, pull requests, and releases

This repository is configured for public contributions:

- `CI` runs on pull requests and pushes to `main` using a macOS 26 runner. It runs the Swift test suite, builds the packaged app, and validates the app bundle.
- `Release macOS` runs on every push to `main` (including merges), builds version `0.1.<run number>`, uploads the app as a workflow artifact, and publishes a GitHub release with a SHA-256 checksum.
- CI releases are ad-hoc signed for packaging. This repository does not yet contain a Developer ID certificate or notarization credentials, so downloaded builds may require Gatekeeper approval. Developer ID signing and notarization can be added later without changing the CI contract.
- `Pullfrog` is available through a manual workflow dispatch. Add at least one provider key, such as `OPENAI_API_KEY`, as a repository Actions secret before running it. It is intentionally not attached to `pull_request`, so provider secrets are not exposed to arbitrary fork code.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the local verification commands and pull request expectations.

## Live smoke test

The endpoint can be checked without launching the app:

```sh
curl -i http://100.101.194.105:5555/api/sparks
curl -i http://100.101.194.105:5555/api/settings
swift run SparkBarSmoke http://100.101.194.105:5555
```

SparkBar’s UI accepts any `http://`, `https://`, `ws://`, or `wss://` base URL. HTTP maps to WS and HTTPS maps to WSS automatically.

HTTP is enabled in the app bundle because sparkDash is commonly reached over a trusted LAN or Tailscale network. SparkBar is read-only and restricts itself to the monitoring REST endpoints and `/ws`; use HTTPS/WSS or an authenticated reverse proxy when the endpoint is not on a trusted private network.

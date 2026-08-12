# Contributing to SparkBar

Thanks for helping improve SparkBar. Changes should preserve the app's read-only monitoring boundary and keep the sparkDash API contract explicit.

## Local setup

Use a Mac with macOS 14 or newer and a compatible Swift 6 toolchain. The normal verification commands are:

```sh
swift test
./scripts/build-app.sh
```

The build script creates `.build/Release/SparkBar.app`. A live sparkDash endpoint is not required for the unit tests or packaged-app build.

## Pull requests

- Explain the user-visible or operational impact in the PR description.
- Include tests for changes to `SparkBarCore` behavior.
- Run `swift test` and `./scripts/build-app.sh` before requesting review.
- Do not commit API keys, certificates, provisioning profiles, or private endpoint credentials.
- Keep networking read-only: SparkBar should not SSH, execute remote commands, enumerate processes, or administer a DGX Spark.

Pull requests run the macOS CI workflow automatically. Maintainers can run Pullfrog manually from the Actions tab after configuring a provider secret.

Signed distribution is maintainer-only. Never put Developer ID `.p12` files, App Store Connect `.p8` keys, passwords, or API credentials in the repository; configure them as GitHub Actions secrets for the release workflow.

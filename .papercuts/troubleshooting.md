# Troubleshooting / Papercuts

- 2026-08-11: The skill catalog listed `swiftui-expert-skill` with an `r0` alias, but that path was unavailable; the active copy resolved under `r1`.
- 2026-08-11: The workspace contained only the PRD and no git/Xcode project, so implementation must bootstrap the app and test harness from scratch.
- 2026-08-11: macOS resolved the built app through `.build/arm64-apple-macosx/release` instead of the `.build/Release` alias used by the first process check; exact-path matching missed two launched instances until `ps`/`pgrep` was used.
- 2026-08-12: The first ATS patch context missed because the test declaration and function name share one line; re-read the exact file shape and applied smaller hunks.

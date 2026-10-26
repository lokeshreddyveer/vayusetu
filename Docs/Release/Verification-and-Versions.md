# Verifying a release, and where the version lives

## One command

```sh
macos/tools/verify-release.sh macos/dist/release/VayuSetu-<version>-<build>-macOS.dmg
```

It needs only full Xcode in `/Applications` and sets its own developer directory, so it works from a default shell (where `xcode-select` points at the
command-line tools, `swift test` cannot find XCTest and `xcodebuild` refuses to run). It runs, and prints one PASS / FAIL / SKIPPED line for each:

- the version configuration checks (below);
- the core package tests, the Go DNS filter tests and formatting, the Swift DNS runtime checks, and the Mac type check (the core module is rebuilt first so it cannot be stale);
- the iPhone compile check (`xcodebuild`, no signing);
- the signed disk image: stapled ticket, Gatekeeper, SHA-256 against the recorded file, app and extension signatures, bundle identifier, build number against the file name,
  extension versions, no diagnostic switches in the binary, and a note on which tunnel extension macOS has activated compared with the one this build carries.

The exit status is 0 only when nothing failed **and nothing was skipped**; skipping a step (`--skip-ios`, `--skip-build`) exits 2 and says so.

## Where the version lives

| Platform | The one file | Read by |
|---|---|---|
| Mac | `macos/scripts/version.json` (`marketing`, `build`, `tunnel`, `filter`) | `vpn-bundle.py`, `bundle.py`, `build-filter.sh`, `verify.py`, the release chain's disk image name |
| iPhone | `ios/Configuration/Version.json` (`marketing`, `build`) | `configure-project.py`, `configure-privacy.py`, `verify.py` |

To bump a version, edit that file and nothing else. `macos/tools/check-versions.py` and `ios/scripts/check-versions.py` fail if a script grows its own copy of a number, or if the
project file or a built app disagrees with the file.

An installed system extension is only replaced when the new one has a **higher** version, so change `tunnel` or `filter` whenever that extension's code changes. A tunnel or filter
with new code and an unchanged version never reaches existing installs.

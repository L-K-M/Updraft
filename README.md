# Updraft

In-app update checks against GitHub Releases, shared by the L-K-M macOS apps.

Updraft replaces the GitHub-Releases update checker that was copied between
the apps. `UpdraftCore` holds the Foundation-only model, client and
downloader and builds and tests on Linux (where the SHA-256 digest check is
skipped for lack of CryptoKit); `UpdraftKit` adds the AppKit
`UpdateChecker` that schedules checks, remembers the user's choices and
presents the alerts.

Released into the public domain; see `LICENSE`.

## Consumers

| App | Adoption | Notes |
|---|---|---|
| Zap | UpdraftKit, downloads | passes its own alert activator and restore hook |
| Jetty | UpdraftKit, downloads | passes `popUpMenu + 1` as the alert window level |
| Invoque | UpdraftKit, downloads | passes `deferWhileInactive: true`, its own activator and restore hook |
| Top Drawer | UpdraftKit, downloads | owner `L-K-M`, repo `MacDring`, app name `Top Drawer` |
| Lucerne | UpdraftKit, downloads | split-arch releases need the architecture-aware selection |
| Gans | UpdraftKit, `autoDownloadAssets: false` | never downloads, stores or launches a binary |
| RepoMen | UpdraftKit, `autoDownloadAssets: false` | never downloads; opens the release page |
| Wrapybara | keeps its copy | its `AGENTS.md` forbids packages |
| Vervellum | keeps its copy | its `AGENTS.md` forbids packages |

## API overview

```swift
import UpdraftKit

// Configure with the repository; the defaults match the keys every app
// already uses.
let checker = UpdateChecker(configuration: .init(
    owner: "L-K-M", repo: "Zap", appName: "Zap"))

// Start the launch check and the daily timer. No-op under XCTest.
checker.start()

// A Settings toggle binds straight to the persisted flag.
Toggle("Check for updates automatically", isOn: $checker.automaticChecksEnabled)

// A menu item or a Check Now button calls:
checker.checkNow()
```

`UpdateChecker` publishes `automaticChecksEnabled`, `lastCheckDate`,
`isChecking`, `isDownloading` and `pendingUpdateTag`, and calls
`onPendingUpdateChanged` when a background-found update is queued or retired.
`presentPendingUpdateNow()` shows a queued update from a status-menu item.

`UpdraftCore` also exposes the pieces for tests and previews:
`SemanticVersion`, `GitHubRelease`, `AssetSelection`, `ReleaseFetching`,
`GitHubReleaseClient`, `UpdateVersionComparison`, `UpdateDownloadSession` and
`UpdateDownloader`.

## Persisted keys

`UpdateChecker` stores its state in `UserDefaults` under a configurable prefix.
The default prefix is `UpdateChecker.<owner>.<repo>`, which is exactly what
every app uses today, so the defaults line up without any extra configuration.
Three keys exist per prefix:

| Key | Type | Meaning |
|---|---|---|
| `<prefix>.enabled` | Bool | automatic checks toggle; absent means on |
| `<prefix>.lastCheck` | Date | when the last successful fetch completed |
| `<prefix>.skippedVersion` | String | raw release tag the user skipped |

The exact keys today:

| App | Prefix |
|---|---|
| Zap | `UpdateChecker.L-K-M.Zap` |
| Jetty | `UpdateChecker.L-K-M.Jetty` |
| Invoque | `UpdateChecker.L-K-M.Invoque` |
| Top Drawer | `UpdateChecker.L-K-M.MacDring` |
| Gans | `UpdateChecker.L-K-M.Gans` |
| RepoMen | `UpdateChecker.L-K-M.RepoMen` |
| Lucerne | `UpdateChecker.L-K-M.Lucerne` |
| Vervellum | `UpdateChecker.L-K-M.Vervellum` |
| Wrapybara | `UpdateChecker.L-K-M.Wrapybara` |

Each app must keep its prefix. Existing users have their enabled flag, last
check date and skipped version stored under those strings; a new prefix would
orphan them, so every user would be re-prompted and lose the version they
skipped. An app whose repository name differs from its product name (Top
Drawer uses `MacDring`) passes the repository name in `owner`/`repo` and the
product name in `appName`.

## Behaviour changes when an app adopts Updraft

These are the user-visible differences from the copy each app carries today.
Every claim is checked against the updater research ledger (section 6.5) and
the source copies it cites.

### Zap

- Version parsing is strict: tags and installed versions such as `01.2.3` or
  `1.0.0-alpha_1` that Zap accepted are now reported as unparseable.
- Pre-release ordering follows SemVer section 11; the old lexical comparison
  ordered `beta.10` below `beta.9`.
- Skip-this-version compares parsed versions, so a retag (`v1.3.0` to `1.3.0`)
  no longer re-prompts a skipped version.
- Downloads are verified: HTTPS on a GitHub host for the initial URL, every
  redirect hop and the final response, an exact size check, a SHA-256 check
  when the release provides a digest, and the `com.apple.quarantine` attribute
  so Gatekeeper evaluates the file on first open.
- Assets with an unknown extension, or a name that names another OS, are never
  offered; Zap previously fell back to the first uploaded asset of any type.
- A click on Check for Updates during a background check is now queued and
  reported instead of being dropped.
- The background throttle compares against 90% of the interval, so a punctual
  daily timer no longer skips a day.

### Jetty

- Jetty was already strict and SemVer-ordered; the shared type keeps that.
- Asset selection now also refuses unknown extensions and other-OS assets and
  ranks the host architecture, which matters for the universal assets Jetty
  ships (no change for its current releases).
- Downloads gain the redirect host allowlist, SHA-256 verification, the
  always-on size check and quarantine stamping.
- Skip-this-version compares parsed versions and survives a retag.
- The alert window level stays configurable; Jetty passes
  `NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)` so the
  alert still clears the Jetty Menu.

### Invoque

- The architecture-aware matcher is kept and extended: OS filtering is added
  and the matcher now matches architecture hints on whole tokens.
- Downloads gain the HTTPS host allowlist (including redirect hops), an
  always-on size check and SHA-256 verification when a digest is present.
  Quarantine stamping was already there and stays.
- Strict version parsing may reject tags Invoque accepted.
- Skip-this-version compares parsed versions and survives a retag.
- The background throttle moves from the full interval to 90%, fixing the
  skipped day.
- The unparseable-version alert now distinguishes the installed version from
  the release tag.
- Invoque passes `deferWhileInactive: true`, its own activator and its
  restore hook, preserving the queued status-menu update and handing focus
  back to the previous app after an alert.

### Top Drawer

- Strict version parsing and SemVer pre-release ordering.
- Skip-this-version compares parsed versions and survives a retag.
- Asset selection is no longer "first asset per extension": it ranks the host
  architecture and still never offers a `.deb` or unknown asset on macOS.
- Downloads gain the redirect host allowlist, SHA-256 verification, the
  always-on size check, quarantine stamping and the move-retry race fix.
- A click on Check for Updates during a background check is now queued and
  reported.
- The throttle was already 90% and stays the default.

### Gans

- Gans keeps `autoDownloadAssets: false`, so it never downloads, stores or
  launches a binary; the Download button still opens the release page.
- The model decodes `assets` (harmless; Gans never offers them).
- Strict version parsing; unparseable versions are no longer reported as
  "you're up to date".
- Skip-this-version compares parsed versions and survives a retag.
- A click on Check for Updates during a background check is now queued and
  reported.
- The background throttle moves from the full interval to 90%.

### RepoMen

- RepoMen keeps downloads disabled and opens the release page.
- Strict version parsing and SemVer pre-release ordering.
- Skip-this-version compares parsed versions and survives a retag.
- A click on Check for Updates during a background check is now queued and
  reported.
- The throttle defaults to 90%; RepoMen passes `throttleFraction: 0.85` to
  keep its current behaviour.
- The unparseable-version alert uses the shared wording, which distinguishes
  the installed version from the release tag.

### Lucerne

- Split-arch release assets are now matched to the host architecture, so an
  arm64 Mac no longer risks being offered the x86_64 disk image.
- Downloads keep the SHA-256 and host allowlist verification and gain
  quarantine stamping, the always-on size check and the move-retry race fix.
- Strict version parsing and SemVer pre-release ordering.
- Skip-this-version compares parsed versions and survives a retag.
- The queued checkNow behaviour and the download-failure alert were already in
  Lucerne and stay.
- The background throttle moves from the full interval to 90%.
- Lucerne passes `currentVersion:` itself, with its
  `AboutWindowController.fallbackVersion` fallback. The package's default reads
  `CFBundleShortVersionString` and falls back to `"0"`, which would offer every
  release as an update to a build without that key.

### Wrapybara and Vervellum

Their `AGENTS.md` files forbid packages, so they keep their current copies and
see no change.

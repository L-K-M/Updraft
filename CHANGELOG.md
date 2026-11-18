# Changelog

## Unreleased

- Add UpdraftCore with `SemanticVersion`, ported from Jetty (strict SemVer
  identifiers, overflow-safe section 11 pre-release ordering) and behaviourally
  checked against Invoque, Lucerne, Top Drawer, Gans and RepoMen.
- Add `UpdateVersionComparison`, ported unchanged from Jetty, so unparseable
  installed and release versions are reported distinctly instead of as
  "up to date".
- Add `GitHubRelease` and `AssetSelection`: the model comes from Invoque
  (self-contained date decoding, bounded release notes) plus Lucerne's asset
  `digest`; asset selection combines Top Drawer's never-offer-unknown rule,
  Invoque's architecture tiers and Vervellum's other-OS filtering.
- Add `GitHubReleaseClient`, ported from Invoque (percent-encoded owner/repo,
  404 split between the latest and list endpoints, newest-parseable selection)
  with Jetty's invalid-URL guard and RepoMen's `noReleases` wording.
- Add `UpdateDownloader` and `UpdateDownloadSession`: the session seam is from
  Top Drawer; the transport checks are Lucerne's (HTTPS host allowlist on the
  initial, redirect and final URLs, streamed SHA-256, custom timeouts); the
  file handling is Jetty's (bounded unique names, symlink-safe existence,
  filename sanitization, always-on size check) plus Invoque's move retry and
  quarantine stamping.
- Add UpdraftKit's `UpdateChecker`, based on Invoque with Lucerne's
  queued-checkNow and download-failure alert, Jetty's distinct invalid-version
  alerts and Top Drawer's throttle fraction, RepoMen's main-actor flag flip and
  Zap's format-string-safe background logging.
- Add `Bundle` display-name and short-version helpers from the shared copies.
- `Configuration.activateForAlert` and `restoreAfterAlert` run around every
  alert, so Zap and Invoque keep handing focus back to the app the user was in
  once an update alert closes.
- Treat the release data as untrusted beyond what any copy did: Download and
  Open Release Page only open this repository's github.com release pages (any
  other `html_url` falls back to the repository's releases page), asset URLs
  must use the default HTTPS port, saved file names lose leading dots and are
  capped at 200 bytes, the file is quarantined before it reaches Downloads,
  and version strings are shortened in alerts.
- `Configuration.offersReleasePageForInvalidVersions` makes the "Couldn't
  compare versions" alert offer Open Release Page and Cancel instead of OK.
  Top Drawer turns it on to keep the button its own checker had.

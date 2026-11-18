# Changelog

## 0.2.0

- `GitHubReleaseClient.ClientError` gains `rateLimited(resetsAt:)`. GitHub's
  rate-limit answers (403 or 429 with no requests left, `retry-after`, or a
  bare 429) used to surface as "GitHub returned HTTP 403." A user-initiated
  check now says "GitHub is limiting requests from this network. Try again
  after 15:45." (or "later" when GitHub gives no time). A 403 with requests
  left is still reported as an HTTP error. Adding the case is
  source-breaking for code that switches over `ClientError` exhaustively,
  hence the minor version.
- The prerelease scan (`latestRelease(includePrereleases: true)`) reads every
  page of releases, 100 at a time and at most 10 pages, instead of only the
  30 most recently created. GitHub lists releases by creation date, so a
  higher-versioned release created earlier was missed and an older
  prerelease could be offered as the newest. From Top Drawer's open PR #208.

## 0.1.0

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

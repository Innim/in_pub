
## Unreleased

### Fixed
- Markdown tables (and other GitHub-flavored elements like fenced code and strikethrough) now render correctly on package pages; table column alignment is preserved.
- Dependency links on a package page now point to where each dependency is actually hosted: packages on this server link internally, pub.dev packages link to pub.dev, packages on another hosted server link to that server, and Flutter SDK dependencies link to the Flutter API docs. Previously every dependency was linked to this server, so pub.dev dependencies led to a "package not exists" page.

## 3.2.2

### Fixed
- Version links on a package's Versions tab now open the selected version instead of doing nothing.
- The default displayed version is now the highest stable version instead of the last uploaded one. A fix published for an older release no longer becomes the default, and prerelease versions (dev/alpha/beta) are only shown by default when there is no stable version.

## 3.2.1

### Fixed
- Auth failures now return `401 Unauthorized` (with `WWW-Authenticate: Bearer`) instead of `400 Bad Request`.

## 3.2.0

- Server version is now displayed in the web UI footer.
- Bundled logo is served at `/logo`; no external image dependency.

## 3.1.0 

- Add endpoint to remove a package version.
- Fix: invalid name for dart file in bin/.

## 3.0.0

Released as `in_pub`.

## 2.0.1-dev.0 (not released)

- Fix archive download links on detail pages 
- Add json api end-point with versions list
- Add reverse proxy deploy support, fixed issue #59
- Implementing null safety in app.serve

## 2.0.0

- Supports NNBD
- Fixes Web styles

## 1.2.1

## 1.2.0

- Supports mongodb pool connection
- Update web page styles

## 1.1.0

- Add badges for version and downloads
- Fix web page styles

## 1.0.0

## 0.4.0

## 0.3.0

## 0.2.2

## 0.2.1

## 0.2.0

- Refactor
- Semver whitelist

## 0.1.1

- Get email via Google APIs
- Upload validator

## 0.1.0

- `pub get`
- `pub publish` with permission check

## 0.0.1

- Initial version, created by Stagehand

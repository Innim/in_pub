
## Unreleased

### Added
- Optional sign-in for the web UI through any OpenID Connect provider. Enabled with `--auth`; off by default, so existing deployments are unaffected. `dart pub get` and `dart pub publish` are deliberately untouched for now — only the web UI, its data endpoints and the generated API documentation require a session.
  - Sessions are stored server side and can be ended: your own at `/auth/sessions`, anyone else's at `/auth/admin` for members of `--auth-admin-groups`. Blocking a user there is independent of the identity provider and survives them signing in again.
  - A copied session cookie is detected. The session secret is re-issued on an interval, and once the browser has used the new one, a request still carrying the previous one means two clients hold the session; it is ended for both (or for all of that user's sessions with `--auth-reuse-kills-all`). A client that merely missed a cookie update is re-issued a working secret rather than locked out.
  - Access follows the identity provider without a second manual step. Signed-in users are re-checked on `--auth-revalidate-interval` by refreshing their grant and reading their profile, so disabling or deleting an account there, or removing it from `--auth-allowed-groups`, ends every session here within that interval. An unreachable provider is not treated as a revocation, but users who stay unverified past `--auth-revalidate-hard` stop being served.
  - Access can be limited to provider groups with `--auth-allowed-groups`. Behind a reverse proxy, set `--auth-trusted-proxies` so `X-Forwarded-For` is honoured; without it the header is ignored and sessions record the proxy's address.

- `--verbose` (`-v`), which logs the whole exchange with the identity provider — discovery, endpoints, token requests and the provider's own error responses — so a sign-in that fails can be diagnosed. Secrets, tokens and authorization codes are never printed.

### Changed
- `401` responses now carry a `message` parameter in the `WWW-Authenticate` header, which `dart pub` prints back to the user.
- The web UI header shows the signed-in user, with links to their sessions, to the administration page (for administrators) and to sign out. Nothing is shown when the server runs without `--auth`.

### Fixed
- The page now references the web UI bundle by content hash (`main.dart.js?v=...`), and both it and `/` are served with `Cache-Control: no-cache` and an entity tag. Previously the bundle was served from a fixed url with no cache headers at all, so a browser — or worse, a CDN or tunnel in front of the server, which may cache a plain `.js` url on its own terms — kept serving the build from before an upgrade, for hours and for everyone. That looked exactly like the new build not working. Unchanged assets still answer `304`, so nothing is re-downloaded needlessly.

## 3.3.0

### Added
- The "API reference" link on a package page now works. The server generates dartdoc API documentation on demand at `/documentation/<name>/<version>/` (running `dart pub get` + `dart doc`), caches the result under `unpub-docs/`, and serves it; the first view shows a progress screen that opens the docs automatically once they are ready. Generation requires a Dart SDK on the server host and can be disabled with `--no-docs` (with the SDK executable configurable via `--dart-executable`); when disabled, the "API reference" link is hidden. Docs for a version are removed when that version is deleted, and requests for packages not hosted here are redirected to the upstream server's documentation.

### Fixed
- Search/list pagination controls are now hidden only when there are no results. Previously, an empty search result still showed the pagination bar with an active "»" button that navigated to further empty pages; a single page of results still shows the pagination bar (with all buttons disabled) as before.
- Search/list pagination no longer shows an extra empty page: the page count now matches the actual number of results (e.g. a single result shows one page, not two).
- Markdown tables (and other GitHub-flavored elements like fenced code and strikethrough) now render correctly on package pages; table column alignment is preserved.
- Dependency links on a package page now point to where each dependency is actually hosted: packages on this server link internally, pub.dev packages link to pub.dev, packages on another hosted server link to that server, and Flutter SDK dependencies link to the Flutter API docs. Previously every dependency was linked to this server, so pub.dev dependencies led to a "package not exists" page.
- "Packages that depend on X" now actually filters the results instead of listing every package: the `dependency:` search filter was silently dropped by the Mongo query builder. The listing also now includes packages that use the target as a `dev_dependencies` entry, not only as a regular dependency.
- The search box now reflects the active query when arriving via a link (e.g. "packages that depend on X" or any URL with a `?q=` filter); previously the results were filtered but the search field stayed empty. The field is also cleared again when leaving the results for a package page or the home page.

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

## Unreleased

### Added
- Access tokens for the pub client, and `--auth-protect-pub-api` to require one. It also closes `/badge` unless `--auth-public-badges` is passed; both flags need `--auth`, and the server refuses to start rather than run open while the operator believes otherwise, since a badge answers differently for a package that exists and so hands out the private names and their latest versions. What this closes is who may *ask*: a badge is still answered with a redirect to `img.shields.io` carrying the package name and its latest version in the url, so an authorized viewer's browser hands both to that third party. Closing badges stops anonymous enumeration; it does not keep the versions off the public internet. Rendering the image here instead is not done yet. `/logo` stays public either way, being the same image whatever is hosted here. With it on, package metadata and tarballs need a token, so `dart pub get` becomes private too. Off by default: turning it on stops every consumer that has not yet run `dart pub token add`, so it has to be a deliberate step taken after the tokens are handed out.
  - Sessions and tokens now live on one **Account** screen in the web UI, reached from the header, with a tab each — tokens first. `/auth/sessions` and `/auth/tokens` redirect there. Administration is a separate section at `/admin`, since that one is about everybody else; `/auth/admin` redirects to it. A new token, and the `dart pub token add` command that consumes it, can each be copied in one click. A token's value is shown once — only a hash is stored — alongside the `dart pub token add` command that consumes it.
  - A personal token is only as good as the account behind it: the owner is looked up and revalidated on every use, so blocking someone here, or disabling them on the identity provider, stops their tokens too. They are not revoked outright, so unblocking restores them rather than forcing everyone to reissue.
  - Administrators can issue *service* tokens, which belong to no account and so survive staff changes. The trade is that nothing upstream can revoke one — only this server can.
  - Publishing and deleting accept a bearer token and nothing else: a browser attaches cookies to cross-site requests it was tricked into making, so honouring one there would let another page do those as whoever is signed in. Reads also accept a browser session, because the web UI links straight to a package's archive and refusing there would hand a signed-in person a JSON error where they asked for a file.
  - The original Google credential does not open reads (the publish handshake, including its two GETs, still works). It proves only that somebody holds a Google account — no group, and until they have signed in here it maps to nobody this server knows — so accepting it would mean anyone could mint one and take every private package. It still authorises a publish, which is additionally checked against the package's uploader list, and is now refused when the address it carries belongs to anyone blocked here or outside `--auth-allowed-groups`. Creating a *new* package with one is refused while `--auth` is on, since a name nobody owns yet is not bounded by an uploader list.
  - Refusals carry the `dart pub token add` command in the `WWW-Authenticate` header, which `dart pub` prints back to the user.

### Breaking
- A package whose record has no `uploaders` field is now frozen rather than open: publishing to it, adding an uploader and deleting a version all refuse, where before the missing list read as "no objection" and let any authenticated caller take it over. Repair the record to unfreeze it. `POST /api/packages/<name>/uploaders` also answers 404 for a package that does not exist, instead of reporting success while changing nothing.
- `AuthStore` gains the token and address methods the pub-client work needs (`createToken`, `getToken`, `touchToken`, `revokeToken`, `listTokensOfUser`, `listServiceTokens`, `serviceTokensForEmail`, `purgeDeadTokens`, `findUsersByEmail`), `usersWithLiveSessions` and `liveSessionCounts` now take the idle window so that every caller agrees on what a live session is, and `revokeSession` returns whether the call is the one that ended the session — the write is conditional on the row still being live, and reporting it is the only way the account screen can avoid answering "ended" for a session somebody else had already closed. Anyone with their own `AuthStore` implementation has to add them. `UserStatus` also gains `needsSignIn`, for an account that cannot be checked until its owner signs in again.
- `--auth-public-url` no longer accepts a path prefix: `https://example.org/pub` is now refused at startup instead of half-working. The built page carries `<base href="/">`, so the web UI was never actually reachable under a prefix — the redirect uri was the only part that honoured it. Serve this server at the root of a host or subdomain.
- Cross-origin access to the JSON endpoints is restricted. With `--auth` on, only the origin of `--auth-public-url` may read them, plus anything named by the new `--auth-dev-origins` (comma-separated, e.g. `http://localhost:8080`) — for a tool or a page run from another port against a development server. Each entry is credentialed access to whatever a visitor's cookies open, so it is stated explicitly rather than inferred from `--auth-insecure-cookie`, which is a cookie attribute and says nothing about who may read what. `--auth-dev-origins` needs `--auth` too: without it nothing ever consults the list, so an entry — including a misspelled one — was silently dropped and the flag read as though it had configured something. Listing an origin is still not enough to exercise authentication through `make dev-web`: the browser client sends no cookies cross-origin, so those requests arrive unauthenticated whatever the CORS headers say. With `--auth` off the answer is a plain `Access-Control-Allow-Origin: *` with credentials refused, rather than the caller's origin reflected back with credentials allowed: the latter let any page read package data from a visitor's browser with their cookies attached, which matters where a repository sits behind an SSO proxy. A cross-origin consumer using `withCredentials` has to be given an allowed origin. This needs `shelf_cors_headers` 0.1.5 or newer, which is where a supplied `Access-Control-Allow-Origin` began to be honoured at all.
- With `--auth` on, a Google credential that answers to no account here can no longer create a **new** package. Publishing a new version of a package it already uploads is unaffected, so existing publishers keep working; a private repository just no longer accepts brand-new packages from anyone holding any Google account. Sign in through the web interface once, or publish with a token created there.

### Changed
- The web UI header links to your account rather than to separate session and token pages.
- Only sign-in, sign-out and the "no access" pages are still rendered by the server. They are the ones needed at moments when the application either has not loaded or must not be trusted to say what went wrong; everything else is a route in the web UI.
- Buttons are defined in the shared stylesheet as `.btn`. The `mdc-button` classes it inherited set a background and nothing else, expecting a Material Components stylesheet this application does not load, so using them gave black text on dark blue at no height at all.
- Anything under `/auth/` is now answered by the auth routes alone. Previously a deliberate 404 from one of them — "that token does not exist" — was mistaken for "no such route" and replaced by the application router's own not-found, discarding the explanation.
- Publishing accepts a token from this server as well as the original Google credential. The latter stays on by default so existing publishers are unaffected, and can be switched off with `--no-google-auth` once everyone has migrated. The `unpub_auth` tool is now documented as the legacy path: it obtains a Google credential, which remains the way to upload to a server running without `--auth`.

### Fixed
- With `--auth` on, every answer now carries `Vary: Origin`. Cross-origin access is decided per caller — the header sent back is the caller's own origin — but nothing said so, and the gate only stamped `Vary` on what it authenticated: with `--auth-protect-pub-api` off, `/api/packages/<name>` left with a reflected origin and `Access-Control-Allow-Credentials: true` and no `Vary` at all, while `/` and `/main.dart.js` left `no-cache` with an entity tag. A CDN or reverse proxy keyed on the url alone could store one origin's header and replay it to the next caller.
- Redirects from the auth routes are sent `Cache-Control: no-store`, as their HTML and JSON answers already were. Several of them carry a `Set-Cookie`: the callback hands out the new session cookie, the already-signed-in branch of `/auth/login?return=/` hands out a rotated session secret from a url stable enough to cache, and the bounce to the provider carries the signed login-state cookie.
- `POST /api/packages/<name>/uploaders` refuses a value that is not an email address, using the same rule the token side applies. `email=alice` used to be written to the uploader list, where it could never publish — a token carrying it is refused — and where it then made the server decline to issue a *service* token for `alice` on the grounds that it already publishes packages here. That rule wants a deliverable address and nothing less: an `@` and a domain with a dot in it, so single-label intranet names are refused too — `dart pub uploader add ops@intranet` does not work, and neither does a service token carrying `ci@internal`. Deliberate rather than an oversight, but it has a consequence to check before turning `--auth-protect-pub-api` on: an account whose provider reports a dotless address (some AD and LDAP directories do) cannot create a token at all, and with the pub API closed a token is the only credential there is. The fix is a real address on the directory entry. The refusals now say which part of the rule they mean instead of only "is not an email address".
- An account this server can no longer re-check is no longer served forever. When the stored provider credential will not decrypt — a lost or rotated `INPUB_AUTH_SESSION_SECRET` — a bearer credential is still allowed through, because refusing on the first request puts every account in the deployment out at once and stops all of CI over an operator's mistake. But the attempt is now recorded, where before nothing was written at all: neither the timestamp nor the failure count moved, so that same branch was taken on every later request, the identity provider was never consulted about the account again, and one disabled upstream kept publishing and reading private packages for as long as the server ran. Each unconfirmable check now spends one of `--auth-revalidate-max-failures`, and once they are gone the credential is refused until the account signs in through a browser, which re-encrypts a usable credential and clears the state. The account is still never blocked over it, and a `dart pub publish` from CI still never ends its owner's browser sessions.
- A bearer credential is refused, not served, when the account record has been deleted. The check read "no record, so nothing says this account is blocked" and answered on the stale copy the caller was still holding in memory, so admin cleanup, a half-finished migration or a dropped collection left tokens working against accounts that no longer existed.
- A Google credential is no longer reported as refused when googleapis could not say what happened. An error with no status at all — a truncated or non-JSON body, a captive portal, an intercepting proxy — was read as a considered "no" and told a publisher mid-`dart pub publish` to reissue a credential that was fine; it is now treated as the outage it is, like a 5xx or a rate limit.
- The account screen shows when each session expires, alongside the same column the token tables have. The server had been sending the field since sessions were listed at all and nothing rendered it.

## 3.4.0

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

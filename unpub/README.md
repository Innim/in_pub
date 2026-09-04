# in_pub

Fork of [unpub](https://github.com/pd4d10/unpub) by Innim.

[![pub](https://img.shields.io/pub/v/in_pub.svg)](https://pub.dev/packages/in_pub)

`in_pub` is a self-hosted private Dart Pub server for Enterprise, with a simple web interface to search and view packages information.

## Screenshots

![Screenshot](https://raw.githubusercontent.com/Innim/in_pub/master/assets/screenshot.png)

## Usage

### Command Line

```sh
pub global activate in_pub
in_pub --database mongodb://localhost:27017/dart_pub # Replace this with production database uri
```

in_pub use mongodb as meta information store and file system as package(tarball) store by default.

Dart API is also available for further customization.

### Dart API

```dart
import 'package:mongo_dart/mongo_dart.dart';
import 'package:in_pub/in_pub.dart' as in_pub;

main(List<String> args) async {
  final db = Db('mongodb://localhost:27017/dart_pub');
  await db.open(); // make sure the MongoDB connection opened

  final app = in_pub.App(
    metaStore: in_pub.MongoStore(db),
    packageStore: in_pub.FileStore('./unpub-packages'),
  );

  final server = await app.serve('0.0.0.0', 4000);
  print('Serving at http://${server.address.host}:${server.port}');
}
```

### Options

| Option | Description | Default |
| --- | --- | --- |
| `metaStore` (Required) | Meta information store | - |
| `packageStore` (Required) | Package(tarball) store | - |
| `docStore` | On-demand dartdoc API docs store (see [API documentation](#api-documentation)) | - (disabled) |
| `upstream` | Upstream url | https://pub.dev |
| `googleapisProxy` | Http(s) proxy to call googleapis (to get uploader email) | - |
| `uploadValidator` | See [Package validator](#package-validator) | - |
| `auth` | See [Sign-in required](#sign-in-required) | - (open) |


### Sign-in required

With `--auth`, browsing the repository requires signing in through an OpenID
Connect provider. Any spec-compliant provider works — nothing here is tied to
a particular one; everything except the issuer url is read from the provider's
discovery document.

By default only the web UI is affected: `dart pub get` and `dart pub publish`
keep working exactly as before, so turning this on breaks nothing for existing
consumers. Closing the pub client's side too is a second, separate step —
see [Making the pub client private too](#making-the-pub-client-private-too).

#### 1. Register a client with your provider

Create a **confidential** client (one with a secret — this server keeps it,
never the browser) using the **authorization code** flow, and note down its
**client id** and **client secret**.

| Setting | Value |
| --- | --- |
| Redirect / callback uri | `<public-url>/auth/callback`, e.g. `https://pub.example.org/auth/callback` |
| Client type | Confidential |
| Flow / grant type | Authorization code |
| Scopes the client may request | `openid profile email groups offline_access` |
| Refresh token lifetime | Longer than `--auth-session-ttl`, or unlimited |
| PKCE | Supported (always used; harmless if the provider ignores it) |

Two of these are worth being careful about.

**The redirect uri must match byte for byte.** It is derived from
`--auth-public-url` by appending `/auth/callback`: with `--auth-public-url
https://pub.example.org` the callback is
`https://pub.example.org/auth/callback`. A mismatch in scheme, host, port,
path or trailing slash makes the provider reject the sign-in.

`--auth-public-url` must name the root of a host or subdomain — a path prefix
such as `https://example.org/pub` is refused at startup. The built web UI
carries `<base href="/">`, so it was never actually reachable under a prefix;
only the redirect uri honoured one, which made the setup look half-working
rather than wrong.

**`offline_access` is not optional.** It is what makes the provider issue a
refresh token, and the refresh token is the only way this server can keep
asking whether an account still exists. Without one it refuses to create a
session rather than quietly issuing one that would outlive a revocation. Some
providers only issue refresh tokens when the scope is explicitly permitted for
the client.

If the provider can restrict which claims a client sees, allow at least `sub`,
`email`, `name` and `groups`. Group membership is read from the `userinfo`
endpoint, not the id token, so it is enough for those claims to be available
there.

<details>
<summary>Example: Nextcloud</summary>

Install the **OpenID Connect Identity Provider** app (app id `oidc`) from the
app store. It adds its own section to the admin settings, in the left-hand
menu, where clients are registered and per-client scopes, claims, flows and
token lifetimes are configured. Fill it in as above; the issuer is the
Nextcloud base url, e.g. `https://cloud.example.org`.

Nextcloud's *built-in* OAuth2 app will not work: it is plain OAuth2 with no
`userinfo` endpoint and no group claims, and its tokens grant full read/write
access to the account's files.

</details>

#### 2. Run the server

```sh
export INPUB_AUTH_CLIENT_SECRET=...   # not on the command line: argv is world-readable
export INPUB_AUTH_SESSION_SECRET=...  # a long random string; without it, restarting signs everyone out

in_pub --auth \
  --auth-issuer https://id.example.org \
  --auth-client-id in-pub \
  --auth-public-url https://pub.example.org \
  --auth-allowed-groups developers \
  --auth-admin-groups pubadmins \
  --auth-trusted-proxies 127.0.0.1
```

| Option | Description |
| --- | --- |
| `--auth` | Turns the whole thing on. Off by default. |
| `--auth-issuer` | Provider base url. Discovery runs against `<issuer>/.well-known/openid-configuration`. |
| `--auth-client-id` | Client id from step 1. |
| `--auth-client-secret` | Client secret. Prefer `INPUB_AUTH_CLIENT_SECRET`. |
| `--auth-public-url` | Public base url of *this* server; the callback uri is derived from it. |
| `--auth-session-secret` | Signs cookies and encrypts stored refresh tokens. Prefer `INPUB_AUTH_SESSION_SECRET`. |
| `--auth-allowed-groups` | Comma-separated groups allowed in. Empty means any account on the issuer. |
| `--auth-admin-groups` | Groups whose members may manage other people's sessions at `/auth/admin`. |
| `--auth-trusted-proxies` | Addresses allowed to set `X-Forwarded-For`. Required behind a reverse proxy. |
| `--auth-protect-pub-api` | Require a token for `dart pub get` too. Off by default; see below. Also closes `/badge`, which otherwise reveals which packages exist and their latest versions — pass `--auth-public-badges` to keep it open anyway. What this closes is who may *ask*: a badge is answered with a redirect to `img.shields.io` carrying the package name and its latest version, so an authorized viewer's browser still hands both to that third party. Closing badges stops anonymous enumeration, not disclosure to shields.io. `/logo` stays public either way: it is the same image whatever is hosted here. |
| `--no-google-auth` | Stop accepting the original Google credential for publishing. |
| `--auth-insecure-cookie` | Drops `Secure` from cookies so the flow works over plain http. Local testing only. It is a cookie attribute and nothing more; it does not open cross-origin access. |
| `--auth-dev-origins` | Comma-separated origins allowed to read the JSON endpoints cross-origin, on top of `--auth-public-url` (e.g. `http://localhost:8080`). Each one is credentialed access to whatever a visitor's cookies open, so this is for a development tool on another port and nothing else. Needs `--auth`: without it nothing consults these origins, so passing them stops the server rather than reading as though it configured something. An entry that is not an origin stops the server. |
| `--verbose` / `-v` | Logs the whole exchange with the provider. See [When sign-in does not work](#when-sign-in-does-not-work). |

Two that are easy to miss:

- **`--auth-session-secret`.** Without it a random key is generated at startup,
  so every restart signs everyone out.
- **`--auth-trusted-proxies`.** Behind a reverse proxy, without it
  `X-Forwarded-For` is ignored and every session records the proxy's address.
  It is ignored on purpose when the peer is not listed: otherwise any client
  could dictate its own recorded address, and both the session binding and the
  audit trail would be fiction.

The remaining options are timings — session lifetime, rotation, revalidation
intervals — and all have workable defaults. Run `in_pub --help` for the list.

#### What it does

- **Sessions live on the server**, so they can be ended: from the **Sessions**
  tab of your account for your own, and at `/auth/admin` for anyone else's if
  you are in an admin group. Blocking someone there is independent of the provider — it keeps them
  out of this repository while their account elsewhere is untouched.
- **A stolen cookie is detected.** The session secret is re-issued every few
  minutes; once the browser has used the new one, a request still carrying the
  old one means two clients hold the session, and it is ended for both. A
  client that merely missed a cookie update is handed a working one instead of
  being locked out.
- **Revocation follows the provider.** Every few minutes each signed-in user is
  re-checked by refreshing their grant and reading their profile. A disabled or
  deleted account, or one removed from `--auth-allowed-groups`, loses every
  session within `--auth-revalidate-interval`. A provider *outage* is not
  treated as a revocation — nobody is blocked for it — but after
  `--auth-revalidate-hard` unverified users stop being served, so downtime
  cannot be used to keep a revoked account alive. The same bound applies when
  it is this server that cannot ask — a rotated `INPUB_AUTH_SESSION_SECRET`
  leaves the stored provider credentials unreadable — except that there it is
  counted in attempts rather than elapsed time: tokens keep working for
  `--auth-revalidate-max-failures` checks, and then stop until the account
  signs in through the browser again, which is what restores this server's
  ability to check it.

#### Making the pub client private too

By default only the web UI is gated: `dart pub get` and `dart pub publish`
keep working for anyone who can reach the server. `--auth-protect-pub-api`
closes that as well, so package metadata and the tarballs themselves need a
token.

Turn it on *after* handing out tokens — the moment it is on, every consumer
that has not run `dart pub token add` stops resolving dependencies.

**Getting a token.** Sign in, open your account from the header, and switch to
the **Tokens** tab. The value is shown once and never again; only a hash of it
is kept. Then:

```sh
dart pub token add https://pub.example.org
# paste the token when prompted
```

For CI, keep it out of the process list and the shell history:

```sh
export PUB_TOKEN=...   # from your CI secret store
dart pub token add https://pub.example.org --env-var PUB_TOKEN
```

Two things `pub` is strict about:

- **https is required.** `dart pub token add` refuses a plain-http server
  (localhost aside), so private mode needs TLS in front.
- **The url must match what is in the pubspec.** `pub` sends the token only to
  the exact prefix it was registered under, so the `hosted:` url in every
  consuming `pubspec.yaml`, `--auth-public-url` and the url given to
  `dart pub token add` all have to agree — scheme, host, port and path.

**Tokens for automation.** A personal token belongs to the person who made it
and stops working the moment their account is blocked or disabled upstream —
which is usually what you want, and a nasty surprise for a release pipeline
when they leave. Administrators can issue a *service token* on the same page:
it belongs to no account and survives staff changes, at the cost of being
revocable only here. Give each one a name that says where it runs.

**Publishing.** Uploads have always authenticated; they now accept a token
from this server as well as the original Google credential. The Google one
authorises a publish only — it says nothing about group membership, and until
its owner has signed in here it corresponds to no account on this server, so
it cannot be used to read private packages. Whichever is used,
the address it resolves to is what gets recorded as the package's uploader.

**Every identity here has to be a real email address.** An account's address,
a service token's, and each entry on a package's uploader list are all held to
the same rule: an `@`, and a domain with at least one dot in it. A bare name
is refused, and so is a single-label intranet domain —
`dart pub uploader add ops@intranet` does not work, and neither does a service
token carrying `ci@internal`. That is deliberate: an uploader entry is an
identity matched against publishing credentials, and a value nothing can
deliver to is one no person can hold.

It is worth checking before you turn `--auth-protect-pub-api` on. If your
provider reports dotless addresses — some AD and LDAP directories do — the
people it reports them for cannot create a token at all, because the token
would publish as something that is not an address, and with the pub API closed
a token is the only credential there is. Put a real address on those directory
entries.

One limit applies to a Google credential that corresponds to no account here:
with `--auth` on it cannot create a **new** package. Publishing further
versions of a package it already uploads is unaffected — that is bounded by
the package's uploader list — but a new name is bounded by nothing, and a
repository whose owner asked for authentication should not accept one from
anybody holding any Google account. Sign in through the web interface once,
or publish with a token from it.

The `unpub_auth` tool in this repository is that older path, and is now
legacy: it obtains a Google credential, which still works — including against
a server running without `--auth` at all, which is what it was written for.
Nothing has to be migrated in a hurry, but new setups should use the tokens
above. Once everyone has, turn the old path off with `--no-google-auth`.

#### When sign-in does not work

Start the server with `--verbose`. It then logs the whole exchange with the
provider — the discovery document and the endpoints it named, every request to
the token endpoint with its parameters and chosen client authentication, the
provider's own error responses verbatim, and which claims `userinfo` returned.
Secrets, tokens and authorization codes are never printed; the configured
client secret is only ever described (its length, whether it has stray
whitespace).

The startup summary alone catches most of it: it prints the exact redirect uri
being sent, the scopes being requested, and whether the provider could be
reached at all.

Common answers, and what they mean:

| Symptom | Usually |
| --- | --- |
| `invalid_client` | Wrong client id or secret. The log shows the secret's length and flags stray whitespace — a trailing newline from copy-paste is the classic one. The server also retries the other ways of presenting the credentials before giving up, so this really does mean they are wrong. |
| `redirect_uri` mismatch, or the provider refuses before you see a password prompt | `--auth-public-url` does not match what was registered. The verbose log prints the authorize url in full; compare its `redirect_uri` with the provider's registration character by character. |
| Sign-in works, then "not a member of a group with access" | `groups` is missing from `userinfo`. The log warns about this explicitly. Allow the `groups` scope *and* claim for the client. |
| "The identity provider did not issue a refresh token" | Seen only after the server has already asked the provider to prompt for consent again and still received none. `offline_access` is not permitted for this client, or the provider only issues refresh tokens in a non-default mode. |
| `invalid_grant` right after signing in | The authorization code expired or was replayed — usually a stale browser tab or a reloaded callback url. |

#### Trying it locally

Authentication cannot be exercised through `make dev-web` at all: it serves
the UI from a different origin than the API, and the browser client does not
send cookies cross-origin, so every request arrives unauthenticated. Adding
that origin to `--auth-dev-origins` does not change this — it decides who may
read what needs no session, not whether cookies are sent. Test against a
server built with `make build`, over http, with `--auth-insecure-cookie` and
`--auth-public-url http://localhost:4000`.


### API documentation

in_pub can generate [dartdoc](https://dart.dev/tools/dart-doc) API documentation
for hosted packages on demand and serve it at `/documentation/<name>/<version>/`
(this is the "API reference" link on each package page). The first request for a
version extracts its tarball, runs `dart pub get` + `dart doc`, caches the result
under the store directory, and serves it; later requests come straight from the
cache. While docs are being built for the first time a progress page is shown
that opens the documentation automatically once it is ready.

Enable it by passing a `docStore`:

```dart
final app = in_pub.App(
  metaStore: in_pub.MongoStore(db),
  packageStore: in_pub.FileStore('./unpub-packages'),
  docStore: in_pub.DocStore('./unpub-docs'),
);
```

Notes:

- A Dart SDK must be available on the server host (to run `dart pub get` and
  `dart doc`). The executable defaults to `dart` on `PATH`; override it with
  `in_pub.DocStore('./unpub-docs', dartExecutable: '/path/to/dart')`.
- To document packages that depend on the **Flutter SDK** (`sdk: flutter`), the
  configured Dart must be the one **bundled with Flutter**
  (`<flutter>/bin/cache/dart-sdk/bin/dart`), not a standalone Dart SDK. A
  standalone `dart` cannot locate the Flutter SDK, so `dart pub get` fails with
  *"Flutter users should use `flutter pub` instead of `dart pub`"* and `dart doc`
  cannot resolve `dart:ui`. Flutter's bundled Dart handles both Flutter and plain
  Dart packages, so pointing `dartExecutable` at it (or running the server on a
  host/image that has Flutter on `PATH`) is the simplest setup.
- Generation resolves the package's dependencies, so the host needs network
  access and reachability of any private dependencies hosted on this server.
- If `docStore` is not configured the `/documentation/...` route is disabled and
  the "API reference" link is hidden in the web UI.

From the command line docs are enabled by default; use `--no-docs` to disable
them and `--dart-executable` to point at a specific Dart SDK.


### Usage behind reverse-proxy

Using in_pub behind reverse proxy(nginx or another), ensure you have necessary headers
```sh
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Server $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# Workaround for: 
# Asynchronous error HttpException: 
# Trying to set 'Transfer-Encoding: Chunked' on HTTP 1.0 headers
proxy_http_version 1.1;
```

### Package validator

Naming conflicts is a common issue for private registry. A reasonable solution is to add prefix to reduce conflict probability.

With `uploadValidator` you could check if uploaded package is valid.

```dart
var app = in_pub.App(
  // ...
  uploadValidator: (Map<String, dynamic> pubspec, String uploaderEmail) {
    // Only allow packages with some specified prefixes to be uploaded
    var prefix = 'my_awesome_prefix_';
    var name = pubspec['name'] as String;
    if (!name.startsWith(prefix)) {
      throw 'Package name should starts with $prefix';
    }

    // Also, you can check if uploader email is valid
    if (!uploaderEmail.endsWith('@your-company.com')) {
      throw 'Uploader email invalid';
    }
  }
);
```

### Customize meta and package store

in_pub is designed to be extensible. It is quite easy to customize your own meta store and package store.

```dart
import 'package:in_pub/in_pub.dart' as in_pub;

class MyAwesomeMetaStore extends in_pub.MetaStore {
  // Implement methods of MetaStore abstract class
  // ...
}

class MyAwesomePackageStore extends in_pub.PackageStore {
  // Implement methods of PackageStore abstract class
  // ...
}

// Then use it
var app = in_pub.App(
  metaStore: MyAwesomeMetaStore(),
  packageStore: MyAwesomePackageStore(),
);
```

## Badges

| URL | Badge |
| --- | --- |
| `/badge/v/{package_name}` | ![badge example](https://img.shields.io/static/v1?label=in_pub&message=0.1.0&color=orange) ![badge example](https://img.shields.io/static/v1?label=in_pub&message=1.0.0&color=blue) |
| `/badge/d/{package_name}` | ![badge example](https://img.shields.io/static/v1?label=downloads&message=123&color=blue) |

## Alternatives

- [pub-dev](https://github.com/dart-lang/pub-dev): Source code of [pub.dev](https://pub.dev), which should be deployed at Google Cloud Platform.
- [pub_server](https://github.com/dart-lang/pub_server): An alpha version of pub server provided by Dart team.

## Credits

- [pub-dev](https://github.com/dart-lang/pub-dev): Web page styles are mostly imported from https://pub.dev directly.
- [shields](https://shields.io): Badges generation.

## License

MIT

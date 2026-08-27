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

Only the web UI is affected. `dart pub get` and `dart pub publish` keep working
exactly as before, so turning this on breaks nothing for existing consumers.

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
`--auth-public-url` by appending `/auth/callback`, including any path prefix:
with `--auth-public-url https://example.org/pub` the callback is
`https://example.org/pub/auth/callback`. A mismatch in scheme, host, port,
path or trailing slash makes the provider reject the sign-in.

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
| `--auth-insecure-cookie` | Drops `Secure` from cookies so the flow works over plain http. Local testing only. |
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

- **Sessions live on the server**, so they can be ended: at `/auth/sessions`
  for your own, and at `/auth/admin` for anyone else's if you are in an admin
  group. Blocking someone there is independent of the provider — it keeps them
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
  cannot be used to keep a revoked account alive.

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
| "the provider returned no refresh token" | `offline_access` is not permitted for this client, or the provider only issues refresh tokens in a non-default mode. |
| `invalid_grant` right after signing in | The authorization code expired or was replayed — usually a stale browser tab or a reloaded callback url. |

#### Trying it locally

Sign-in needs cookies that survive a redirect, which the `make dev-web` setup
cannot provide: it serves the UI from a different origin than the API. Test
against a server built with `make build`, over http, with
`--auth-insecure-cookie` and `--auth-public-url http://localhost:4000`.


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

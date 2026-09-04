import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:crypto/crypto.dart' show sha1;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:archive/archive.dart';
import 'package:in_pub/src/models.dart';
import 'package:in_pub/unpub_api/lib/models.dart';
import 'package:in_pub/src/meta_store.dart';
import 'package:in_pub/src/package_store.dart';
import 'package:in_pub/src/doc_store.dart';
import 'package:in_pub/src/doc_progress_page.dart';
import 'package:in_pub/src/auth/auth_middleware.dart';
import 'package:in_pub/src/auth/http_helpers.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:in_pub/src/auth/auth_store.dart';
import 'package:in_pub/src/auth/auth_service.dart';
import 'package:in_pub/src/auth/google_credential.dart';
import 'package:path/path.dart' as p;
import 'utils.dart';
import 'auth_exception.dart';
import 'static/index.html.dart' as index_html;
import 'static/main.dart.js.dart' as main_dart_js;

part 'app.g.dart';

/// Client-side routes that only mean anything once `--auth` is on.
///
/// Named so the test that walks the shell routes reads the same list the
/// server does; the `@Route.get` annotations on [App.indexHtml] still have
/// to be kept in step by hand, because they are compiled into the router.
const authOnlyRoutes = {'/account', '/admin'};

class App {
  static const proxyOriginHeader = "proxy-origin";

  /// meta information store
  final MetaStore metaStore;

  /// package(tarball) store
  final PackageStore packageStore;

  /// generates and caches dartdoc API documentation on demand; when null the
  /// `/documentation/...` route is disabled.
  final DocStore? docStore;

  /// upstream url, default: https://pub.dev
  final String upstream;

  /// when non-null, browsing the repository requires a signed-in user; see
  /// `lib/src/auth/`. Null leaves the server open, as it was before.
  final AuthService? auth;

  /// http(s) proxy to call googleapis (to get uploader email)
  final String? googleapisProxy;

  /// Whether a Google credential is still accepted for publishing.
  ///
  /// On by default, because it is how publishing has always worked here and
  /// switching it off strands every existing publisher until they have a
  /// token from this server.
  final bool googleAuth;
  final String? overrideUploaderEmail;

  /// A forward proxy uri
  final Uri? proxy_origin;

  final String version;

  /// validate if the package can be published
  ///
  /// for more details, see: https://github.com/Innim/in_pub#package-validator
  final Future<void> Function(
      Map<String, dynamic> pubspec, String uploaderEmail)? uploadValidator;

  App({
    required this.metaStore,
    required this.packageStore,
    this.docStore,
    this.auth,
    this.upstream = 'https://pub.dev',
    this.googleapisProxy,
    this.googleAuth = true,
    this.overrideUploaderEmail,
    this.uploadValidator,
    this.proxy_origin,
    this.version = '',
  });

  /// Whether [resolveGoogleBearer] has anything to do.
  ///
  /// Only with authentication off. With it on, every credential goes through
  /// the gate and `AuthService.legacyResolver` is the one that answers —
  /// [googleAuth] here applies to nothing. Asking whether *that* resolver
  /// exists, as this used to, made the condition true precisely when this
  /// path is unreachable, and building [_resolver] under it allocated a
  /// second HTTP client and a second answer cache for a question the auth
  /// layer had already answered.
  bool get _legacyEnabled => auth == null && googleAuth;

  /// A JSON answer.
  ///
  /// Deliberately without an `Access-Control-Allow-Origin` of its own: the
  /// CORS middleware decides that, and a wildcard set here replaces its
  /// answer — `shelf_cors_headers` lets the response's own headers win — so
  /// the origin restriction would never reach the endpoints that carry
  /// package data.
  static shelf.Response _okWithJson(Map<String, dynamic> data) =>
      shelf.Response.ok(
        json.encode(data),
        headers: {HttpHeaders.contentTypeHeader: _jsonContentType},
      );

  /// `application/json` with the encoding spelled out.
  ///
  /// `ContentType.json.mimeType` drops the charset that `ContentType.json`
  /// itself carries. Nothing was broken by that — shelf puts it back when
  /// the body is a string, which every answer here is — but the guarantee
  /// then lives in shelf rather than in this file, and a body handed over as
  /// bytes would silently lose it. What is at stake is not decoration:
  /// `package:http`, which the web UI fetches with, reads a body with no
  /// stated charset as latin1, and every README and description this server
  /// answers with is text somebody wrote.
  static const _jsonContentType = 'application/json; charset=utf-8';

  static shelf.Response _successMessage(String message) => _okWithJson({
        'success': {'message': message}
      });

  static shelf.Response _badRequest(String message,
          {int status = HttpStatus.badRequest}) =>
      shelf.Response(
        status,
        headers: {HttpHeaders.contentTypeHeader: _jsonContentType},
        body: json.encode({
          'error': {'message': message}
        }),
      );

  /// 401 for the pub client. Shared with the gate, so a caller sees the same
  /// shape whichever of the two refused it.
  static shelf.Response _unauthorized(String message) =>
      pubUnauthorized(message);

  String _resolveUrl(shelf.Request req, String reference) {
    if (proxy_origin != null) {
      return proxy_origin!.resolve(reference).toString();
    }
    String? proxyOriginInHeader = req.headers[proxyOriginHeader];
    if (proxyOriginInHeader != null) {
      return Uri.parse(proxyOriginInHeader).resolve(reference).toString();
    }
    return req.requestedUri.resolve(reference).toString();
  }

  /// The identity to record against a publish, and to check against a
  /// package's uploader list.
  ///
  /// Resolution order: whatever the gate already established for this
  /// request, then one of this server's own tokens, then — while
  /// [googleAuth] is on — the original Google credential, so deployments
  /// that publish with `unpub_auth` today keep working until they migrate.
  Future<String> _getUploaderEmail(shelf.Request req) async =>
      (await _resolvePublisher(req)).email;

  /// Whether [email] is on [uploaders], compared the way addresses compare.
  ///
  /// A literal `List.contains` made the answer depend on how somebody typed
  /// their address: an identity provider reporting `Alice@Example.org`
  /// against a list holding `alice@example.org` — the form Google returns,
  /// and so the form every legacy publish recorded — is the same person, and
  /// refusing them said only that they were "not an uploader".
  /// An absent list is not a permission. Nobody is recorded as owning such
  /// a package, and reading that as "no objection" let any caller who could
  /// authenticate at all add themselves as an uploader of it, or delete its
  /// versions. It stays frozen until the record is repaired.
  static bool _isUploader(List<String>? uploaders, String email) =>
      _storedUploader(uploaders, email) != null;

  /// The entry in [uploaders] that stands for [email], as it is actually
  /// stored, or null if there is none.
  ///
  /// The one place address equality is decided, so the guard and the
  /// mutation cannot come to disagree — which is the bug that made a
  /// case-mismatched removal report success and remove nothing.
  static String? _storedUploader(List<String>? uploaders, String email) =>
      _storedUploaders(uploaders, email).firstOrNull;

  /// Every entry in [uploaders] that stands for [email], as they are actually
  /// stored.
  ///
  /// There can be more than one. `addVersion` adds the uploader with
  /// `addToSet`, which compares literally, so before the write path started
  /// recording the spelling already on file a publish as `Alice@Example.org`
  /// to a list holding `alice@example.org` appended a second entry for the
  /// same person. Removal has to take them all: pulling only the first left
  /// Alice publishing while `dart pub uploader remove` printed success.
  static List<String> _storedUploaders(List<String>? uploaders, String email) {
    if (uploaders == null) return const [];
    var wanted = normalizeAddress(email);
    return uploaders.where((u) => normalizeAddress(u) == wanted).toList();
  }

  /// Who is publishing, and whether this server knows them.
  ///
  /// `provisional` means the credential was accepted but answers to no
  /// account here — only the legacy Google credential can be that. It may
  /// still publish to a package whose uploader list already names it; what
  /// it may not do is create a new one. See [upload].
  Future<({String email, bool provisional})> _resolvePublisher(
      shelf.Request req) async {
    if (overrideUploaderEmail != null) {
      return (email: overrideUploaderEmail!, provisional: false);
    }

    // Already resolved by the gate on the way in; no reason to spend a second
    // round trip proving the same credential.
    var alreadyResolved = bearerUserOf(req);
    if (alreadyResolved != null) {
      return (
        email: alreadyResolved.email,
        provisional: bearerIsProvisionalIn(req)
      );
    }

    var authHeader = req.headers[HttpHeaders.authorizationHeader];
    if (authHeader == null) throw AuthException('missing authorization header');

    var token = authHeader.split(' ').last;

    var authService = auth;
    if (authService != null) {
      // Delegated rather than repeated: `resolveBearer` is the one place
      // that sequences our tokens and the legacy credential, and a second
      // copy of that ordering here would drift from it.
      var result = await authService.resolveBearer(token,
          ip: clientIp(req, authService.config.trustedProxies),
          // The same predicate the gate uses, not a second copy of the
          // rule. The gate steps aside entirely when
          // `--auth-protect-pub-api` is off, which is the default, so this
          // path has to carry the rule too — and when the two were written
          // out separately one of them grew a `googleAuth` conjunct the
          // other lacked.
          allowLegacy: authService.legacyAllowedFor(req.requestedUri.path));
      var user = result.user;
      if (user != null) {
        return (email: user.email, provisional: result.provisional);
      }
      throw AuthException(
          result.message ?? 'this credential is not recognised by this server');
    }

    // Authentication is switched off, so the legacy credential is the only
    // scheme there is — and publishing has always worked this way.
    String? email;
    try {
      email = await resolveGoogleBearer(token);
    } on IdentityUnavailableException catch (e) {
      // Not a refusal. Letting this escape turned a Google outage into a
      // malformed-upload error on one route and a 500 on three others.
      throw AuthException(e.message);
    }
    if (email == null) {
      throw AuthException('this credential is not recognised by this server');
    }
    // Nothing to be provisional against: with authentication off there are no
    // accounts, and publishing has always worked exactly this way.
    return (email: email, provisional: false);
  }

  /// Resolves the original Google credential, or null when it is switched
  /// off or the token is not one.
  ///
  /// Only reachable with authentication off: with it on, the gate resolves
  /// every credential, and this server's own tokens have to be tried first.
  /// The work itself lives in [GoogleCredentialResolver], so both paths
  /// share one cache policy and one idea of what a network failure means.
  Future<String?> resolveGoogleBearer(String token) {
    if (!_legacyEnabled) return Future.value(null);
    return _resolver.resolve(token);
  }

  /// This server's own resolver, built on first use.
  ///
  /// Only ever reached with authentication off — with it on the gate
  /// resolves every credential through [AuthService.legacyResolver], and
  /// this is never consulted. An earlier version tried to borrow that one
  /// here, which read as though the two could collide; they cannot.
  GoogleCredentialResolver get _resolver =>
      _ownResolver ??= GoogleCredentialResolver(proxy: googleapisProxy);

  GoogleCredentialResolver? _ownResolver;

  /// Releases what this server owns, for an embedder that builds and discards
  /// [App]s. The auth layer's own resources go with [AuthService.close].
  void close() => _ownResolver?.close();

  /// Adds `Origin` to an answer's `Vary`, leaving one that already says so
  /// alone.
  ///
  /// Merged rather than set: the gate lists `Authorization` and sometimes
  /// `Cookie` as well, and overwriting that would tell a shared cache it may
  /// serve one token holder's private metadata to the next.
  static shelf.Handler _varyOnOrigin(shelf.Handler inner) =>
      (shelf.Request req) async {
        var response = await inner(req);
        var stated = response.headers[HttpHeaders.varyHeader];
        var fields =
            (stated ?? '').split(',').map((f) => f.trim().toLowerCase());
        if (fields.any((f) => f == 'origin' || f == '*')) return response;
        return response.change(headers: {
          HttpHeaders.varyHeader:
              stated == null || stated.isEmpty ? 'Origin' : '$stated, Origin',
        });
      };

  Future<HttpServer> serve([String host = '0.0.0.0', int port = 4000]) async {
    var authService = auth;
    if (authService != null) await authService.start();

    // `shelf_cors_headers` answers with the caller's own origin reflected
    // back and `Access-Control-Allow-Credentials: true`. Left open, that
    // lets any page a browser considers same-site — a sibling subdomain, a
    // stale CNAME — read an authenticated response, including the
    // anti-forgery token the account API hands out. Once there is a public
    // url to compare against, only it is allowed.
    var pipeline = shelf.Pipeline();
    // Outermost, so it sees the finished answer and whatever `Vary` the gate
    // already put on it. With `--auth` on the CORS answer is the caller's
    // own origin reflected back, and `shelf_cors_headers` writes `Vary` only
    // when it is handed a fixed `Access-Control-Allow-Origin` — which this
    // branch is not, it supplies only the allowed request headers. So every
    // answer left carrying an origin-specific `Access-Control-Allow-Origin`
    // and nothing saying the answer depends on the origin. The gate stamps
    // one on what it authenticates, but plenty leaves without passing
    // through that: with `--auth-protect-pub-api` off — the default —
    // `/api/packages/<name>` short-circuits and goes out with a reflected
    // origin and `Allow-Credentials: true`, and `/` and `/main.dart.js` go
    // out `no-cache` with an entity tag, which is an invitation to store
    // them. A CDN or reverse proxy keying on the url alone then holds one
    // origin's header and replays it to the next caller. The wildcard branch
    // below needs none of this: `*` is the same answer for everybody.
    if (authService != null) pipeline = pipeline.addMiddleware(_varyOnOrigin);
    pipeline = pipeline
        .addMiddleware(authService == null
            // A wildcard, not the caller's origin reflected back. The
            // default reflects it *and* sends
            // `Access-Control-Allow-Credentials: true`, which lets any page
            // read these endpoints from a visitor's browser with their
            // cookies attached — a real exposure where a repository is
            // fronted by an SSO proxy and that proxy's cookie is what grants
            // access. `*` is what a browser refuses to combine with
            // credentials, and it used to be set per-response until that was
            // removed as redundant.
            ? corsHeaders(headers: {
                ACCESS_CONTROL_ALLOW_ORIGIN: '*',
                ACCESS_CONTROL_ALLOW_CREDENTIALS: 'false',
              })
            // The public url's own origin, plus whatever
            // `--auth-dev-origins` names. Both spelled out: this used to
            // admit any localhost origin whenever `--auth-insecure-cookie`
            // was set, which reads a CORS policy off a cookie attribute —
            // an operator terminating TLS at a reverse proxy sets that flag
            // for its documented reason and was thereby letting any page on
            // any localhost port read `/auth/api/account` with the
            // visitor's cookies. Listing an origin still does not make
            // `make dev-web` able to exercise authentication: the browser
            // client sends no cookies cross-origin, so those requests
            // arrive unauthenticated whatever these headers say. README's
            // "Trying it locally" is the accurate account.
            : corsHeaders(
                originChecker: authService.config.allowedOrigins.contains,
                // The default list does not mention `x-csrf-token`, which
                // every account and administration change carries, so such a
                // request failed its preflight before leaving the page. A
                // cross-origin caller that does send credentials
                // deliberately needs it allowed.
                headers: {
                    ACCESS_CONTROL_ALLOW_HEADERS: 'accept,accept-encoding,'
                        'authorization,content-type,dnt,origin,user-agent,'
                        'x-csrf-token',
                  }))
        .addMiddleware(shelf.logRequests());
    // The gate sits inside request logging so refusals are logged, and
    // outside the router so a route that does not exist cannot be probed
    // without a session.
    if (authService != null)
      pipeline = pipeline.addMiddleware(authService.gate);

    var handler = pipeline.addHandler((req) async {
      // `/auth/` belongs to the auth router in its entirety, so its answer
      // is final. Falling through on a 404 would discard a deliberate "no
      // such token" — body and all — and replace it with the application
      // router's own not-found.
      if (authService != null && req.requestedUri.path.startsWith('/auth/')) {
        return authService.handler(req);
      }
      // Return 404 by default
      // https://github.com/google/dart-neats/issues/1
      var res = await router.call(req);
      return res;
    });
    var server = await shelf_io.serve(handler, host, port);
    return server;
  }

  Map<String, dynamic> _versionToJson(UnpubVersion item, shelf.Request req) {
    var name = item.pubspec['name'] as String;
    var version = item.version;
    return {
      'archive_url':
          _resolveUrl(req, '/packages/$name/versions/$version.tar.gz'),
      'pubspec': item.pubspec,
      'version': version,
    };
  }

  /// Picks the version to show by default for a package: the highest stable
  /// version, or the highest prerelease (dev/alpha/beta) only when there is no
  /// stable version at all. This is not necessarily the last uploaded version —
  /// a fix published for an older release must not become the default.
  UnpubVersion? _primaryVersion(List<UnpubVersion> versions) {
    if (versions.isEmpty) return null;
    var primary = semver.Version.primary(
        versions.map((v) => semver.Version.parse(v.version)).toList());
    return versions.firstWhere(
        (v) => semver.Version.parse(v.version) == primary,
        orElse: () => versions.last);
  }

  bool isPubClient(shelf.Request req) {
    var ua = req.headers[HttpHeaders.userAgentHeader];
    print(ua);
    return ua != null && ua.toLowerCase().contains('dart pub');
  }

  /// Built once, for the same reason as the auth router: a getter rebuilt
  /// the whole table on every request.
  late final Router router = _$AppRouter(this);

  @Route.get('/api/packages/<name>')
  Future<shelf.Response> getVersions(shelf.Request req, String name) async {
    var package = await metaStore.queryPackage(name);

    if (package == null) {
      return shelf.Response.found(
          Uri.parse(upstream).resolve('/api/packages/$name').toString());
    }

    package.versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(a.version), semver.Version.parse(b.version));
    });

    var versionMaps =
        package.versions.map((item) => _versionToJson(item, req)).toList();

    var primary = _primaryVersion(package.versions);

    return _okWithJson({
      'name': name,
      'latest':
          primary != null ? _versionToJson(primary, req) : versionMaps.last,
      'versions': versionMaps,
    });
  }

  @Route.get('/api/packages/<name>/versions/<version>')
  Future<shelf.Response> getVersion(
      shelf.Request req, String name, String version) async {
    // Important: + -> %2B, should be decoded here
    try {
      version = Uri.decodeComponent(version);
    } catch (err) {
      print(err);
    }

    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/api/packages/$name/versions/$version')
          .toString());
    }

    var packageVersion =
        package.versions.firstWhereOrNull((item) => item.version == version);
    if (packageVersion == null) {
      return shelf.Response.notFound('Not Found');
    }

    return _okWithJson(_versionToJson(packageVersion, req));
  }

  @Route.get('/packages/<name>/versions/<version>.tar.gz')
  Future<shelf.Response> download(
      shelf.Request req, String name, String version) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/packages/$name/versions/$version.tar.gz')
          .toString());
    }

    if (isPubClient(req)) {
      metaStore.increaseDownloads(name, version);
    }

    if (packageStore.supportsDownloadUrl) {
      return shelf.Response.found(
          await packageStore.downloadUrl(name, version));
    } else {
      return shelf.Response.ok(
        packageStore.download(name, version),
        headers: {HttpHeaders.contentTypeHeader: ContentType.binary.mimeType},
      );
    }
  }

  Future<List<int>> _readTarball(String name, String version) async {
    var builder = BytesBuilder();
    await for (var chunk in packageStore.download(name, version)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Requests without a trailing slash are redirected so the generated docs'
  /// relative asset/links resolve against the version directory.
  @Route.get('/documentation/<name>/<version>')
  Future<shelf.Response> documentationRedirect(
      shelf.Request req, String name, String version) async {
    return shelf.Response.movedPermanently(
        req.requestedUri.replace(path: '${req.requestedUri.path}/').toString());
  }

  /// JSON generation status, polled by the "generating…" progress page.
  @Route.get('/documentation/<name>/<version>/__status')
  Future<shelf.Response> documentationStatus(
      shelf.Request req, String name, String version) async {
    if (docStore == null) {
      return _okWithJson({'status': DocStatus.none.name});
    }
    try {
      version = Uri.decodeComponent(version);
    } catch (_) {}

    var status = docStore!.statusOf(name, version);
    return _okWithJson({
      'status': status.name,
      if (status == DocStatus.failed)
        'error': docStore!.errorOf(name, version) ??
            'Documentation generation failed.',
    });
  }

  @Route.get('/documentation/<name>/<version>/<file|[^]*>')
  Future<shelf.Response> documentation(
      shelf.Request req, String name, String version, String file) async {
    if (docStore == null) {
      return shelf.Response.notFound(
          'API documentation is not available on this server.');
    }

    try {
      version = Uri.decodeComponent(version);
    } catch (_) {}

    // Already generated: serve the requested file straight from the cache,
    // without a metadata lookup.
    var docDir = docStore!.cachedDir(name, version);
    if (docDir != null) {
      return _serveDocFile(req, docDir, file.isEmpty ? 'index.html' : file);
    }

    // A sub-resource requested before docs exist: nothing to serve yet.
    if (file.isNotEmpty && file != 'index.html') {
      return shelf.Response.notFound('Not Found');
    }

    var package = await metaStore.queryPackage(name);
    // Not hosted here — defer to the upstream server's documentation.
    if (package == null) {
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/documentation/$name/$version/')
          .toString());
    }
    if (package.versions.every((v) => v.version != version)) {
      return shelf.Response.notFound('Not Found');
    }

    // Kick off generation (idempotent) and show the progress page, which
    // polls `__status` and reloads into the docs when they are ready.
    docStore!.startGeneration(name, version, () => _readTarball(name, version));
    return shelf.Response.ok(
      docProgressPage(name, version),
      headers: {
        HttpHeaders.contentTypeHeader: ContentType.html.mimeType,
        // Stated here rather than left to whatever sits in front. This page
        // stops being true the moment `dart doc` finishes — seconds — and it
        // is served from the same url the finished documentation will be, so
        // anything that keeps a copy shows a generated doc set as still
        // generating. With `--auth` on the gate would mark it private and
        // unstorable anyway; with `--auth` off nothing does, and a CDN in
        // front is free to hold a plain 200 on its own terms.
        HttpHeaders.cacheControlHeader: 'no-store',
      },
    );
  }

  /// Serves one file out of a generated documentation set, with the
  /// validator that makes the gate's `private, no-cache` mean something.
  ///
  /// `no-cache` is a promise to revalidate, not a refusal to store — but a
  /// revalidation the server cannot answer with "unchanged" can only be
  /// answered with the whole file again, which left the marking identical to
  /// `no-store`: every stylesheet, script and search index in the set
  /// re-downloaded on every click through the docs. A generated set is
  /// written once and replaced wholesale rather than edited in place, so its
  /// size and modification time identify a file as well as hashing the bytes
  /// would, at the cost of the `stat` this needs anyway.
  Future<shelf.Response> _serveDocFile(
      shelf.Request req, Directory docDir, String file) async {
    // Resolve the requested file within the doc dir, guarding against
    // path traversal (`..`) escaping the cache.
    var target = p.normalize(p.join(docDir.path, file));
    if (!p.equals(target, docDir.path) && !p.isWithin(docDir.path, target)) {
      return shelf.Response.notFound('Not Found');
    }

    // dartdoc links to libraries as directories (e.g. `foo/`); serve the
    // directory's index.html so those links resolve.
    if (await Directory(target).exists()) {
      target = p.join(target, 'index.html');
    }

    var f = File(target);
    if (!await f.exists()) {
      return shelf.Response.notFound('Not Found');
    }

    var stat = await f.stat();
    // Truncated to the second: `Last-Modified` carries nothing finer, and
    // comparing an untruncated time against the one we ourselves handed out
    // makes the file look newer on every conditional request. `FileStat`
    // reports whole seconds anyway on the platforms this runs on.
    var modified = DateTime.fromMillisecondsSinceEpoch(
        stat.modified.millisecondsSinceEpoch ~/ 1000 * 1000,
        isUtc: true);
    // Size and time, which is what nginx derives a tag from as well, rather
    // than a hash of the bytes: hashing would mean reading every file on
    // every conditional request, which is the download this exists to
    // avoid. What it cannot tell apart is a doc set regenerated within the
    // same second as the one before it, whose files come out at exactly the
    // same length — a narrower window than the seconds `dart doc` spends
    // producing them.
    var etag = '"${stat.size.toRadixString(16)}-'
        '${modified.millisecondsSinceEpoch.toRadixString(16)}"';
    var validators = {
      HttpHeaders.etagHeader: etag,
      HttpHeaders.lastModifiedHeader: HttpDate.format(modified),
    };

    if (_docFileIsUnchanged(req, etag, modified)) {
      return shelf.Response.notModified(headers: validators);
    }

    return shelf.Response.ok(
      f.openRead(),
      headers: {
        HttpHeaders.contentTypeHeader:
            lookupMimeType(target) ?? 'application/octet-stream',
        ...validators,
      },
    );
  }

  /// Whether the caller already holds this exact file.
  static bool _docFileIsUnchanged(
      shelf.Request req, String etag, DateTime modified) {
    var tags = req.headers[HttpHeaders.ifNoneMatchHeader];
    if (tags != null) {
      // The tag decides on its own when it is there: a browser that has the
      // file sends both headers, and reading the date instead would answer
      // with the whole body whenever a redeployment rewrote the set with the
      // same contents.
      return _ifNoneMatchHolds(tags, etag);
    }
    var since = req.headers[HttpHeaders.ifModifiedSinceHeader];
    if (since == null) return false;
    try {
      return !modified.isAfter(HttpDate.parse(since));
    } catch (_) {
      // A date we cannot read says nothing about the file.
      return false;
    }
  }

  /// Whether an `If-None-Match` header claims [etag].
  ///
  /// RFC 9110 lets the header carry `*`, a comma-separated list, and weak
  /// tags — and clients use all three: a caching proxy in front of this
  /// server may weaken a tag on the way through, and a browser holding an
  /// earlier and a current copy sends both. Compared as one opaque string,
  /// none of those ever matched, so the answer to a revalidation was the
  /// whole body again. Shared by the generated documentation and the
  /// embedded assets, because a rule written out twice is one the two will
  /// eventually disagree about.
  static bool _ifNoneMatchHolds(String header, String etag) => header
      .split(',')
      .map((t) => t.trim())
      .any((t) => t == '*' || t == etag || t == 'W/$etag');

  @Route.get('/api/packages/versions/new')
  Future<shelf.Response> getUploadUrl(shelf.Request req) async {
    return _okWithJson({
      'url': _resolveUrl(req, '/api/packages/versions/newUpload').toString(),
      'fields': {},
    });
  }

  @Route.post('/api/packages/versions/newUpload')
  Future<shelf.Response> upload(shelf.Request req) async {
    try {
      var publisher = await _resolvePublisher(req);
      var uploader = publisher.email;

      var contentType = req.headers['content-type'];
      if (contentType == null) throw 'invalid content type';

      var mediaType = MediaType.parse(contentType);
      var boundary = mediaType.parameters['boundary'];
      if (boundary == null) throw 'invalid boundary';

      var transformer = MimeMultipartTransformer(boundary);
      MimeMultipart? fileData;

      // The map below makes the runtime type checker happy.
      // https://github.com/dart-lang/pub-dev/blob/19033f8154ca1f597ef5495acbc84a2bb368f16d/app/lib/fake/server/fake_storage_server.dart#L74
      final stream = req.read().map((a) => a).transform(transformer);
      await for (var part in stream) {
        if (fileData != null) continue;
        fileData = part;
      }

      var bb = await fileData!.fold(
          BytesBuilder(), (BytesBuilder byteBuilder, d) => byteBuilder..add(d));
      var tarballBytes = bb.takeBytes();
      var tarBytes = GZipDecoder().decodeBytes(tarballBytes);
      var archive = TarDecoder().decodeBytes(tarBytes);
      ArchiveFile? pubspecArchiveFile;
      ArchiveFile? readmeFile;
      ArchiveFile? changelogFile;

      for (var file in archive.files) {
        if (file.name == 'pubspec.yaml') {
          pubspecArchiveFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'readme.md') {
          readmeFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'changelog.md') {
          changelogFile = file;
          continue;
        }
      }

      if (pubspecArchiveFile == null) {
        throw 'Did not find any pubspec.yaml file in upload. Aborting.';
      }

      var pubspecYaml = utf8.decode(pubspecArchiveFile.content);
      var pubspec = loadYamlAsMap(pubspecYaml)!;

      // TODO: null
      var name = pubspec['name'] as String;
      var version = pubspec['version'] as String;

      var package = await metaStore.queryPackage(name);

      // Before the embedder's hook, not after. A new package has no uploader
      // list, so nothing else in this method bounds who may create one. That
      // is fine when the credential answers to an account here, and not fine
      // when it only proves the holder has a Google account: on a server
      // whose owner has asked for authentication, anyone at all could
      // otherwise fill the repository with packages. Publishing to a package
      // that already exists is unaffected, which is what keeps publishers
      // from before authentication existed working.
      //
      // The decision needs nothing the validator produces, and running the
      // hook first meant a publish about to be refused still triggered
      // whatever the host does there — audit rows, a policy call, a name
      // reservation.
      if (package == null && publisher.provisional) {
        throw '$uploader has no account on this server, so it cannot create '
            'the new package $name. Sign in through the web interface once, '
            'or publish it with a token created there.';
      }

      if (uploadValidator != null) {
        await uploadValidator!(pubspec, uploader);
      }

      // Package already exists
      if (package != null) {
        if (package.private == false) {
          throw '$name is not a private package. Please upload it to https://pub.dev';
        }

        // Check uploaders
        if (!_isUploader(package.uploaders, uploader)) {
          throw '$uploader is not an uploader of $name';
        }

        // Check duplicated version
        var duplicated = package.versions
            .firstWhereOrNull((item) => version == item.version);
        if (duplicated != null) {
          throw 'version invalid: $name@$version already exists.';
        }
      }

      // Upload package tarball to storage
      await packageStore.upload(name, version, tarballBytes);

      String? readme;
      String? changelog;
      if (readmeFile != null) {
        readme = utf8.decode(readmeFile.content);
      }
      if (changelogFile != null) {
        changelog = utf8.decode(changelogFile.content);
      }

      // Recorded under the spelling the package already holds, where it has
      // one. `addVersion` adds the uploader with `addToSet`, which compares
      // literally — so publishing as `Alice@Example.org` to a list holding
      // `alice@example.org` appended a second entry for the same person, and
      // removing one of them afterwards left the other publishing. The
      // permission check above already treats the two as equal; the write
      // has to agree with it.
      uploader = _storedUploader(package?.uploaders, uploader) ?? uploader;

      // Write package meta to database
      var unpubVersion = UnpubVersion(
        version,
        pubspec,
        pubspecYaml,
        uploader,
        readme,
        changelog,
        DateTime.now(),
      );
      await metaStore.addVersion(name, unpubVersion);

      // TODO: Upload docs
      return shelf.Response.found(
          _resolveUrl(req, '/api/packages/versions/newUploadFinish'));
    } on AuthException catch (e) {
      return _unauthorized(e.message);
    } catch (err) {
      // Built as a query parameter rather than interpolated. The message
      // carries the package name, which comes verbatim from the uploaded
      // pubspec: `name: foo#x` made everything after the `#` a fragment, so
      // the finish route saw no error at all and reported a refused publish
      // as a success, and `name: foo&error=ok` rewrote the parameter.
      return shelf.Response.found(_resolveUrl(
          req,
          Uri(
              path: '/api/packages/versions/newUploadFinish',
              queryParameters: {'error': '$err'}).toString()));
    }
  }

  @Route.get('/api/packages/versions/newUploadFinish')
  Future<shelf.Response> uploadFinish(shelf.Request req) async {
    var error = req.requestedUri.queryParameters['error'];
    if (error != null) {
      return _badRequest(error);
    }
    return _successMessage('Successfully uploaded package.');
  }

  @Route.post('/api/packages/<name>/uploaders')
  Future<shelf.Response> addUploader(shelf.Request req, String name) async {
    var body = await req.readAsString();
    // Not `!`: a request without the field is a bad request, not a crash.
    var email = Uri.splitQueryString(body)['email']?.trim() ?? '';
    if (email.isEmpty) {
      return _badRequest('email is required');
    }
    // The same rule the token side applies, from the same place. An uploader
    // entry is an identity: `TokenService` refuses to issue a credential
    // carrying anything that is not an address, so `alice` written here can
    // never publish — and worse, `_checkServiceAddress` then reads it as a
    // name that "already publishes packages here" and refuses to give a
    // service token that address either. One typed word on this route locks
    // a name out on both.
    if (!looksLikeEmailAddress(email)) {
      return _badRequest('"$email" is not an email address: an uploader is '
          'recorded as the address it publishes under, so it has to be a '
          'full one — an @ and a domain with a dot in it. A single-label '
          'name like "ops@intranet" is refused for that reason');
    }
    final String operatorEmail;
    try {
      operatorEmail = await _getUploaderEmail(req);
    } on AuthException catch (e) {
      return _unauthorized(e.message);
    }
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      // Said plainly. The store's update matches no document, so answering
      // "uploader added" reported a publish permission that was never
      // granted — and `dart pub uploader add` printed success.
      return _badRequest('package not found', status: HttpStatus.notFound);
    }

    if (!_isUploader(package.uploaders, operatorEmail)) {
      return _badRequest('no permission', status: HttpStatus.forbidden);
    }
    if (_isUploader(package.uploaders, email)) {
      return _badRequest('email already exists');
    }

    await metaStore.addUploader(name, email);
    return _successMessage('uploader added');
  }

  @Route.delete('/api/packages/<name>/uploaders/<email>')
  Future<shelf.Response> removeUploader(
      shelf.Request req, String name, String email) async {
    try {
      email = Uri.decodeComponent(email);
    } on FormatException {
      // Defensive rather than a fix for anything reachable today: every
      // malformed escape tried here is rejected by `Uri.parse` inside
      // shelf's own `Request`, so nothing gets this far. Kept because the
      // decode happens before any credential is checked, `removeVersion`
      // has always guarded its identical one, and a lenient parser in some
      // later shelf would make this an unauthenticated 500.
      return _badRequest('malformed uploader address');
    }
    final String operatorEmail;
    try {
      operatorEmail = await _getUploaderEmail(req);
    } on AuthException catch (e) {
      return _unauthorized(e.message);
    }
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _badRequest('package not found', status: HttpStatus.notFound);
    }

    if (!_isUploader(package.uploaders, operatorEmail)) {
      return _badRequest('no permission', status: HttpStatus.forbidden);
    }
    // The stored spellings, not the one in the url, and all of them. The
    // check above folds case while the store removes by exact match: a
    // request naming `Alice@Example.org` for a list holding
    // `alice@example.org` would otherwise pass the guard, remove nothing, and
    // answer "uploader removed" while Alice kept publishing. Taking only the
    // first is the same failure one step along — a package carrying both
    // spellings, which the old literal-compare write path produced, keeps the
    // other entry and with it the permission this call was asked to withdraw.
    var stored = _storedUploaders(package.uploaders, email);
    if (stored.isEmpty) {
      return _badRequest('email not uploader');
    }

    for (var entry in stored) {
      await metaStore.removeUploader(name, entry);
    }
    return _successMessage('uploader removed');
  }

  @Route.delete('/api/packages/<name>/versions/<version>')
  Future<shelf.Response> removeVersion(
      shelf.Request req, String name, String version) async {
    try {
      version = Uri.decodeComponent(version);
    } catch (err) {
      print(err);
    }

    final String operatorEmail;
    try {
      operatorEmail = await _getUploaderEmail(req);
    } on AuthException catch (e) {
      return _unauthorized(e.message);
    }
    var package = await metaStore.queryPackage(name);

    if (package == null) {
      return _badRequest('package not found', status: HttpStatus.notFound);
    }
    if (!_isUploader(package.uploaders, operatorEmail)) {
      return _badRequest('no permission', status: HttpStatus.forbidden);
    }

    var packageVersion =
        package.versions.firstWhereOrNull((item) => item.version == version);
    if (packageVersion == null) {
      return _badRequest('version not found', status: HttpStatus.notFound);
    }
    if (package.versions.length == 1) {
      return _badRequest('cannot remove the last version of a package');
    }

    await metaStore.removeVersion(name, version);
    await packageStore.delete(name, version);
    await docStore?.delete(name, version);
    return _successMessage('version removed');
  }

  @Route.get('/webapi/packages')
  Future<shelf.Response> getPackages(shelf.Request req) async {
    var params = req.requestedUri.queryParameters;
    var size = int.tryParse(params['size'] ?? '') ?? 10;
    var page = int.tryParse(params['page'] ?? '') ?? 0;
    var sort = params['sort'] ?? 'download';
    var q = params['q'];

    String? keyword;
    String? uploader;
    String? dependency;

    if (q == null) {
    } else if (q.startsWith('email:')) {
      uploader = q.substring(6).trim();
    } else if (q.startsWith('dependency:')) {
      dependency = q.substring(11).trim();
    } else {
      keyword = q;
    }

    final result = await metaStore.queryPackages(
      size: size,
      page: page,
      sort: sort,
      keyword: keyword,
      uploader: uploader,
      dependency: dependency,
    );

    var data = ListApi(result.count, [
      for (var package in result.packages)
        if (_primaryVersion(package.versions) case var primary?)
          ListApiPackage(
            package.name,
            primary.pubspec['description'] as String?,
            getPackageTags(primary.pubspec),
            primary.version,
            package.updatedAt,
          )
    ]);

    return _okWithJson({'data': data.toJson()});
  }

  @Route.get('/packages/<name>.json')
  Future<shelf.Response> getPackageVersions(
      shelf.Request req, String name) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _badRequest('package not exists', status: HttpStatus.notFound);
    }

    var versions = package.versions.map((v) => v.version).toList();
    versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(b), semver.Version.parse(a));
    });

    return _okWithJson({
      'name': name,
      'versions': versions,
    });
  }

  @Route.get('/webapi/package/<name>/<version>')
  Future<shelf.Response> getPackageDetail(
      shelf.Request req, String name, String version) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _okWithJson({'error': 'package not exists'});
    }

    UnpubVersion? packageVersion;
    if (version == 'latest') {
      packageVersion = _primaryVersion(package.versions);
    } else {
      packageVersion =
          package.versions.firstWhereOrNull((item) => item.version == version);
    }
    if (packageVersion == null) {
      return _okWithJson({'error': 'version not exists'});
    }

    var versions = package.versions
        .map((v) => DetailViewVersion(v.version, v.createdAt))
        .toList();
    versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(b.version), semver.Version.parse(a.version));
    });

    var pubspec = packageVersion.pubspec;
    List<String> authors;
    if (pubspec['author'] != null) {
      authors = RegExp(r'<(.*?)>')
          .allMatches(pubspec['author'])
          .map((match) => match.group(1))
          .nonNulls
          .toList();
    } else if (pubspec['authors'] != null) {
      authors = (pubspec['authors'] as List)
          .map((author) => RegExp(r'<(.*?)>').firstMatch(author)!.group(1))
          .nonNulls
          .toList();
    } else {
      authors = [];
    }

    var depMap =
        (pubspec['dependencies'] as Map? ?? {}).cast<String, dynamic>();
    var selfUri = Uri.parse(_resolveUrl(req, '/'));
    var dependencies = <DependencyView>[];
    for (var entry in depMap.entries) {
      dependencies.add(await resolveDependencyView(
        entry.key,
        entry.value,
        selfUri,
        (name) async => (await metaStore.queryPackage(name)) != null,
      ));
    }

    var data = WebapiDetailView(
      package.name,
      packageVersion.version,
      packageVersion.pubspec['description'] ?? '',
      packageVersion.pubspec['homepage'] ?? '',
      package.uploaders ?? [],
      packageVersion.createdAt,
      packageVersion.readme,
      packageVersion.changelog,
      versions,
      authors,
      dependencies,
      getPackageTags(packageVersion.pubspec),
      hasDocs: docStore != null,
    );

    return _okWithJson({'data': data.toJson()});
  }

  static bool _isPubDevHost(String host) =>
      host == 'pub.dev' || host == 'pub.dartlang.org';

  /// A normalized origin+path key used to decide whether a hosted dependency
  /// points at *this* server. Comparing only the host is not enough: the same
  /// hostname can serve different pub repositories on different ports or path
  /// prefixes (e.g. `http://localhost:8080` vs `http://localhost:4000`).
  static String _baseKey(Uri uri) {
    var path = uri.path;
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    return '${uri.scheme}://${uri.host}:${uri.port}$path';
  }

  /// Builds a [DependencyView] for a single pubspec dependency entry,
  /// resolving where the package is actually hosted so the web UI can link
  /// to the right place (this server, pub.dev, or another hosted server).
  ///
  /// [spec] is the raw pubspec dependency value: a version string, or a map
  /// describing a `hosted`/`sdk`/`git`/`path` source.
  static Future<DependencyView> resolveDependencyView(
    String name,
    dynamic spec,
    Uri selfUri,
    Future<bool> Function(String name) isPublishedLocally,
  ) async {
    if (spec is Map) {
      // sdk dependencies: Flutter SDK packages link to the Flutter API docs
      // (matching pub.dev); other sdk sources have no pub page to link to.
      var sdk = spec['sdk'];
      if (sdk != null) {
        if (sdk == 'flutter') {
          return DependencyView(name, url: 'https://api.flutter.dev/');
        }
        return DependencyView(name);
      }

      // git/path dependencies have no pub page to link to.
      if (spec.containsKey('git') || spec.containsKey('path')) {
        return DependencyView(name);
      }

      var hosted = spec['hosted'];
      if (hosted != null) {
        // `hosted` may be a plain url string or a {name, url} map.
        String? url;
        var hostedName = name;
        if (hosted is String) {
          url = hosted;
        } else if (hosted is Map) {
          url = hosted['url'] as String?;
          hostedName = (hosted['name'] as String?) ?? name;
        }

        if (url != null) {
          var depUri = Uri.tryParse(url);
          var host = depUri?.host;
          if (depUri == null ||
              host == null ||
              host.isEmpty ||
              _baseKey(depUri) == _baseKey(selfUri)) {
            return DependencyView(name, internal: true);
          }
          if (_isPubDevHost(host)) {
            return DependencyView(name,
                url: 'https://pub.dev/packages/$hostedName');
          }
          var base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
          return DependencyView(name, url: '$base/packages/$hostedName');
        }
      }
    }

    // Plain version string (default pub server). If this server hosts the
    // package, link internally; otherwise it comes from pub.dev.
    if (await isPublishedLocally(name)) {
      return DependencyView(name, internal: true);
    }
    return DependencyView(name, url: 'https://pub.dev/packages/$name');
  }

  /// The embedded web assets and their entity tags, computed on first use.
  /// Both are fixed for the life of the process, and the bundle is large
  /// enough that neither rendering nor hashing it belongs on a request path.
  String? _indexHtmlBody, _indexHtmlEtag;
  String? _mainDartJsBody, _mainDartJsEtag;

  static String _etagOf(String body) =>
      '"${sha1.convert(utf8.encode(body)).toString().substring(0, 16)}"';

  String get _mainDartJs => _mainDartJsBody ??= main_dart_js.content({});
  String get _mainDartJsTag => _mainDartJsEtag ??= _etagOf(_mainDartJs);

  /// The page, with the script reference stamped with the bundle's content
  /// hash.
  ///
  /// `no-cache` on `/main.dart.js` asks a browser to revalidate, but it is
  /// only a request, and anything sitting in front of this server — a CDN, a
  /// tunnel, a corporate proxy — may cache a plain `.js` url on its own
  /// terms and keep serving the previous release for hours. A url that
  /// changes with the content cannot be stale: the page itself is never
  /// cached, so it always points at the build that is actually running.
  /// Filled through the project's build-time template mechanism rather than
  /// by rewriting the emitted markup: `{{$BUNDLE_VERSION}}` in
  /// `unpub_web/web/index.html` becomes an interpolation in the generated
  /// source. A `replaceFirst` on a bare `src="main.dart.js"` literal matched
  /// one line of a generated file and would have silently done nothing —
  /// reverting to the unversioned url this exists to avoid — the moment
  /// webdev changed a quote or reordered an attribute.
  String get _indexHtml => _indexHtmlBody ??= index_html.content({
        'APP_VERSION': version,
        'BUNDLE_VERSION': _mainDartJsTag.replaceAll('"', ''),
      });

  String get _indexHtmlTag => _indexHtmlEtag ??= _etagOf(_indexHtml);

  /// Serves one of the embedded assets with revalidation.
  ///
  /// Their urls carry no version, so a browser left to its own devices will
  /// happily keep serving the bundle it downloaded before an upgrade — which
  /// looks exactly like the new build not working. `no-cache` makes it ask
  /// every time; the entity tag keeps that question cheap by answering 304
  /// when nothing changed.
  shelf.Response _staticAsset(
      shelf.Request req, String body, String etag, String contentType) {
    var tags = req.headers[HttpHeaders.ifNoneMatchHeader];
    if (tags != null && _ifNoneMatchHolds(tags, etag)) {
      return shelf.Response.notModified(headers: {
        HttpHeaders.cacheControlHeader: 'no-cache',
        HttpHeaders.etagHeader: etag,
      });
    }
    return shelf.Response.ok(body, headers: {
      HttpHeaders.contentTypeHeader: contentType,
      HttpHeaders.cacheControlHeader: 'no-cache',
      HttpHeaders.etagHeader: etag,
    });
  }

  /// Serves the web UI shell.
  ///
  /// Every client-side route needs an entry here, or opening one directly —
  /// a pasted link, a reload, a redirect from elsewhere on the server — hits
  /// the router instead of the application and comes back "not found". The
  /// list is deliberately explicit rather than a catch-all, so a genuinely
  /// wrong url still says so; the price is that it has to be kept in step
  /// with `unpub_web/lib/src/routes.dart`.
  @Route.get('/')
  @Route.get('/packages')
  @Route.get('/packages/<name>')
  @Route.get('/packages/<name>/versions/<version>')
  @Route.get('/account')
  @Route.get('/admin')
  Future<shelf.Response> indexHtml(shelf.Request req) async {
    // The account and administration screens exist only when there is
    // something to account for. Serving them otherwise gives a page whose
    // very first request goes to an endpoint that is not routed.
    if (auth == null && authOnlyRoutes.contains(req.requestedUri.path)) {
      return shelf.Response.notFound('Not Found');
    }
    return _staticAsset(
        req, _indexHtml, _indexHtmlTag, ContentType.html.mimeType);
  }

  @Route.get('/main.dart.js')
  Future<shelf.Response> mainDartJs(shelf.Request req) async {
    return _staticAsset(req, _mainDartJs, _mainDartJsTag, 'text/javascript');
  }

  @Route.get('/logo')
  Future<shelf.Response> logo(shelf.Request req) async {
    final uri = await resolveInPubPackageUri('src/static/logo.png');
    if (uri == null) return shelf.Response.notFound('Not found');
    final file = File(uri.toFilePath());
    if (!await file.exists()) return shelf.Response.notFound('Not found');
    return shelf.Response.ok(
      file.openRead(),
      headers: {HttpHeaders.contentTypeHeader: 'image/png'},
    );
  }

  String _getBadgeUrl(String label, String message, String color,
      Map<String, String> queryParameters) {
    var badgeUri = Uri.parse('https://img.shields.io/static/v1');
    return Uri(
        scheme: badgeUri.scheme,
        host: badgeUri.host,
        path: badgeUri.path,
        queryParameters: {
          'label': label,
          'message': message,
          'color': color,
          ...queryParameters,
        }).toString();
  }

  @Route.get('/badge/<type>/<name>')
  Future<shelf.Response> badge(
      shelf.Request req, String type, String name) async {
    var queryParameters = req.requestedUri.queryParameters;
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.notFound('Not found');
    }

    switch (type) {
      case 'v':
        var latest = semver.Version.primary(package.versions
            .map((pv) => semver.Version.parse(pv.version))
            .toList());

        var color = latest.major == 0 ? 'orange' : 'blue';

        return shelf.Response.found(
            _getBadgeUrl('in_pub', latest.toString(), color, queryParameters));
      case 'd':
        return shelf.Response.found(_getBadgeUrl(
            'downloads', package.download.toString(), 'blue', queryParameters));
      default:
        return shelf.Response.notFound('Not found');
    }
  }
}

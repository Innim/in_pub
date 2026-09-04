import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;

import 'auth_config.dart';
import 'auth_pages.dart';
import 'http_helpers.dart';
import 'identity.dart';
import 'session.dart';
import 'token_service.dart';

/// Key under which a caller authenticated by bearer token is placed, so a
/// handler further down does not have to resolve the credential a second
/// time.
const bearerPrincipalContextKey = 'in_pub.auth.bearer';

/// Key under which a bearer caller that answers to no account here is
/// flagged. See [TokenResolution.provisional].
const bearerProvisionalContextKey = 'in_pub.auth.bearer.provisional';

/// What kind of client a route serves, which decides how a missing session is
/// answered.
enum RouteKind {
  /// Reachable without signing in.
  public,

  /// A page in a browser. Answered with a redirect into the sign-in flow.
  web,

  /// Data fetched by the web UI. Answered with a 401 the front end turns into
  /// a redirect, because redirecting an XHR would return the login page as
  /// JSON.
  webApi,

  /// The `dart pub` client. It speaks bearer tokens, never cookies.
  pubApi,
}

/// The three routes `dart pub publish` walks through, in order: ask for an
/// upload url, POST the archive, finish.
///
/// Named here because the gate has to tell them from a metadata read, and
/// exported so that a test can hold them against the router's own
/// annotations — nothing else ties the two together, and a rename that
/// missed this set would silently reclassify a publish step as a read.
const publishHandshakePaths = {
  '/api/packages/versions/new',
  '/api/packages/versions/newUpload',
  '/api/packages/versions/newUploadFinish',
};

/// Decides which contract a request path falls under.
///
/// Deliberately driven by the path rather than by the `User-Agent`: the
/// existing `isPubClient` check is fine for download counting but trivially
/// spoofed, which makes it unusable for an access decision.
RouteKind classifyRoute(String path, {bool publicBadges = true}) {
  if (path == '/auth' || path.startsWith('/auth/')) return RouteKind.public;
  if (path == '/health') return RouteKind.public;

  // The site's own logo: the same bytes whatever is hosted here.
  if (path == '/logo') return RouteKind.public;

  if (_isBadge(path)) {
    // Closed badges are still badges: a README renderer or a CI job that has
    // run `dart pub token add` has to be able to fetch one. `pubApi` is the
    // kind that accepts a bearer token, and it accepts a session cookie for
    // reads besides, so a signed-in browser keeps working too. Classifying
    // them as `web` left a token holder with no way to authenticate at all.
    return isClosedBadge(path, publicBadges: publicBadges)
        ? RouteKind.pubApi
        : RouteKind.public;
  }

  if (path.startsWith('/webapi/')) return RouteKind.webApi;

  // The pub client's own surface: metadata, uploads, and the tarballs
  // themselves.
  if (path.startsWith('/api/')) return RouteKind.pubApi;
  if (path.startsWith('/packages/')) {
    if (path.endsWith('.tar.gz')) return RouteKind.pubApi;
    // `/packages/<name>.json` is a listing endpoint, not the SPA's package
    // page, which has no extension.
    if (path.endsWith('.json')) return RouteKind.pubApi;
  }

  return RouteKind.web;
}

bool _isBadge(String path) => path.startsWith('/badge/');

/// Whether [path] is a badge this deployment does not serve anonymously.
///
/// The one place the rule lives, because two things need the same answer:
/// [classifyRoute] has to send such a request to the contract that speaks
/// bearer tokens, and the gate has to demand a credential for it even where
/// `--auth-protect-pub-api` leaves the rest of the pub surface open. Written
/// out separately, nothing tied the two together — and a change to the
/// prefix in one of them would have gone on serving closed badges to anyone.
bool isClosedBadge(String path, {required bool publicBadges}) =>
    !publicBadges && _isBadge(path);

/// Gates every request on a valid session once `--auth` is on.
class AuthMiddleware {
  final AuthConfig config;
  final SessionManager sessions;

  /// Resolves the `Authorization: Bearer` credential the pub client sends.
  /// [allowLegacy] admits the original Google credential, which proves only
  /// that somebody holds a Google account.
  final Future<TokenResolution> Function(String value,
      {String? ip, bool allowLegacy}) resolveBearer;

  /// Whether the legacy credential may authorise a request for this path.
  /// Owned by [AuthService] so that this and `App` cannot disagree.
  final bool Function(String path) legacyAllowedFor;

  AuthMiddleware({
    required this.config,
    required this.sessions,
    required this.resolveBearer,
    required this.legacyAllowedFor,
  });

  shelf.Middleware get middleware => (shelf.Handler inner) {
        return (shelf.Request req) async {
          var path = req.requestedUri.path;
          var kind = classifyRoute(path, publicBadges: config.publicBadges);

          if (kind == RouteKind.public) return inner(req);

          if (kind == RouteKind.pubApi) {
            // A closed badge is closed by its own flag, and `_pubApi` opens
            // the whole pub surface when `--auth-protect-pub-api` is off.
            // Without this, `--no-auth-public-badges` on its own was a
            // silent no-op serving badges to anyone — the opposite of what
            // the operator asked for.
            return _pubApi(req, inner,
                alwaysGate:
                    isClosedBadge(path, publicBadges: config.publicBadges));
          }

          var result = await sessions.resolve(req);
          if (result.isAuthenticated) {
            // Passed through unchanged. The session-authenticated user was
            // put on the request context for a while; nothing downstream ever
            // read it, and `req.change` allocates a fresh request for every
            // page a signed-in person opens. Publishing goes through the
            // bearer principal below, which `App` does read.
            var response = await inner(req);
            return withCookies(
                _carriesPackageData(path)
                    ? _private(response, storable: _mayBeHeldByTheBrowser(path))
                    : response,
                result.cookies);
          }

          return _refuse(req, kind, result);
        };
      };

  /// The pub client's own surface.
  ///
  /// A bearer token is the way in. A session cookie is accepted for reads
  /// only, and only because the web UI links straight to a package's
  /// archive: refusing it there would hand a signed-in person a JSON error
  /// where they asked for a file, with no way to authenticate from a
  /// browser. Anything that changes state stays bearer-only — a browser
  /// attaches cookies to cross-site requests it was tricked into making, so
  /// honouring one on a publish or a delete would let another page do those
  /// on behalf of whoever is signed in.
  /// [alwaysGate] demands a credential even where the pub surface as a whole
  /// is open, for a route closed by a flag of its own.
  Future<shelf.Response> _pubApi(shelf.Request req, shelf.Handler inner,
      {bool alwaysGate = false}) async {
    if (!config.protectPubApi && !alwaysGate) return inner(req);

    var header = req.headers[HttpHeaders.authorizationHeader];
    if (header == null || !header.toLowerCase().startsWith('bearer ')) {
      if (!_isPublishFlow(req)) {
        var session = await sessions.resolve(req);
        if (session.isAuthenticated) {
          var response = await inner(req);
          return withCookies(_private(response), session.cookies);
        }
        // A person clicking the archive link on a package page is owed the
        // sign-in flow, not the pub client's JSON. Whatever the session
        // check decided — a clone, an expiry — its instruction to drop the
        // cookie has to travel with the answer either way, or the browser
        // keeps presenting a dead one.
        // A browser is owed the same answer it would get anywhere else,
        // including the reason its session was ended — bouncing a blocked
        // person through the provider, or swallowing "used from two
        // clients", is what `_refuse` exists to avoid.
        if (prefersHtml(req)) return _refuse(req, RouteKind.web, session);
        return withCookies(_pubUnauthorized(_needsCredential), session.cookies);
      }
      return _pubUnauthorized(_needsCredential);
    }

    var result = await resolveBearer(
      header.substring('bearer '.length).trim(),
      ip: clientIp(req, config.trustedProxies),
      // The original Google credential proves only that somebody holds a
      // Google account: it carries no group, and until they have signed in
      // here it maps to nobody this server knows. That was tolerable while
      // it only ever authorised a publish, which is additionally checked
      // against the package's uploader list. Letting it open reads would
      // mean anyone on the internet could mint one and take every private
      // package, which is precisely what this mode exists to prevent.
      //
      // The publish handshake exactly, not `_isPublishFlow`: that counts
      // every state-changing method, which handed the legacy credential
      // `DELETE /api/packages/<name>/versions/<version>` and
      // `POST /api/packages/<name>/uploaders` as well. Destroying a
      // published version is worse than the read this mode is careful to
      // refuse, and those routes have this server's own tokens to use.
      allowLegacy: legacyAllowedFor(req.requestedUri.path),
    );
    var user = result.user;
    if (user == null) {
      return _pubUnauthorized(result.message ?? 'This credential was refused.');
    }

    return _private(await inner(req.change(context: {
      bearerPrincipalContextKey: user,
      bearerProvisionalContextKey: result.provisional,
    })));
  }

  /// Whether a path answers with something particular to this repository's
  /// contents, as opposed to the application shell, which is the same for
  /// everyone and wants to be cached.
  /// Badges are deliberately absent: `classifyRoute` sends them to `public`
  /// or, once closed, to `pubApi`, and this is only consulted on the
  /// session-authenticated branch — which serves neither. A closed badge is
  /// marked private by `_pubApi` instead.
  static bool _carriesPackageData(String path) =>
      path.startsWith('/webapi/') || path.startsWith('/documentation/');

  /// Whether a path's answer may sit in the caller's own browser cache.
  ///
  /// Generated documentation is hundreds of static files per package —
  /// stylesheets, scripts, the search index, every page. `no-store` there
  /// makes the browser re-fetch all of it on every click, and buys nothing:
  /// what the marking is for is keeping a *shared* cache from serving one
  /// caller's answer to another, which `private` already does.
  static bool _mayBeHeldByTheBrowser(String path) =>
      path.startsWith('/documentation/');

  /// Marks an answer as belonging to one caller.
  ///
  /// This mode requires TLS in front — `dart pub token add` refuses a plain
  /// http server — so a reverse proxy or CDN is on the path by
  /// construction. Without these an intermediary is free to key a private
  /// package's metadata, or its archive, on the url alone and hand it to the
  /// next anonymous caller.
  static shelf.Response _private(shelf.Response response,
      {bool storable = false}) {
    // Only an answer the browser can revalidate may be held, which is what
    // carrying a validator means. `no-cache` is a promise to ask before
    // reusing, and a stored copy the server cannot answer "unchanged" about
    // buys nothing over `no-store` — while everything under
    // `/documentation/` that is *not* a generated file stops being true
    // within seconds: the "generating…" progress page, the redirect upstream
    // for a package hosted elsewhere, the 404 for an asset that does not
    // exist yet. Keeping one showed a finished doc set as still generating,
    // or kept sending a browser to pub.dev for a package that had just been
    // published here.
    //
    // Keyed on the validator rather than on the status code, which is what
    // this used to read. A 200 is not the question — the progress page is
    // one, and was being stamped storable in flat contradiction of the
    // paragraph above; it was harmless only because it carries nothing to
    // revalidate against. `_serveDocFile` is the one thing here that emits
    // an entity tag, on the full answer and on the 304 alike, and the 304 is
    // the answer to the very revalidation this marking asks for.
    var mayHold = storable &&
        response.headers[HttpHeaders.etagHeader] != null &&
        response.headers[HttpHeaders.cacheControlHeader] == null;

    return _stamp(response, storable: mayHold);
  }

  static shelf.Response _stamp(shelf.Response response,
          {bool storable = false}) =>
      response.change(headers: {
        HttpHeaders.cacheControlHeader:
            // `no-cache` rather than a lifetime: the browser may keep the
            // bytes and skip re-downloading them, but has to ask first, and
            // that question comes back through this gate. A `max-age` meant
            // a private package's documentation stayed readable from the
            // browser's own cache for five minutes after signing out, being
            // blocked, or handing the machine to somebody else — `private`
            // only excludes caches this server does not control.
            storable ? 'private, no-cache' : 'private, no-store',
        // No `Cookie` on the storable branch. The session cookie rotates on
        // the same five-minute cadence as that lifetime, so keying the
        // browser's cache on it turned every rotation into a full miss —
        // the whole documentation bundle re-fetched, plus a duplicate set
        // kept per cookie value. `private` is already what stops a shared
        // cache from mixing callers up; `Vary: Cookie` bought nothing and
        // cost the caching this branch exists for.
        // `Origin` is listed here rather than left to the CORS middleware.
        // That middleware is outermost, so on the way out it runs last and
        // lets the response's own headers win — anything it set is replaced
        // by this. An earlier attempt merged instead, which could not work:
        // at this point the CORS header does not exist yet.
        'vary': storable
            ? 'Origin, Authorization'
            : 'Origin, Authorization, Cookie',
      });

  static const _needsCredential =
      'Authentication is required for this package repository.';

  /// Whether this request is part of publishing rather than reading.
  ///
  /// The method alone will not say. Publishing is a handshake: `dart pub
  /// publish` asks for an upload url with a GET, POSTs the archive, then
  /// finishes with another GET — so treating every GET as a read refuses the
  /// flow at its first step. Those two GETs live under a path of their own,
  /// which is what separates them from a metadata read.
  static bool _isPublishFlow(shelf.Request req) {
    // Everything that changes state is publishing, which already covers the
    // POST in the middle of the handshake; the set below is consulted for
    // the two GETs on either side of it.
    if (req.method != 'GET' && req.method != 'HEAD') return true;
    // The exact three, not the prefix they share: `versions` is a legal
    // package name, so `/api/packages/versions/1.0.0` is somebody's metadata
    // and must not be mistaken for a step of publishing.
    return publishHandshakePaths.contains(req.requestedUri.path);
  }

  /// The pub client's 401, with the instructions that get somebody unstuck.
  shelf.Response _pubUnauthorized(String message) =>
      pubUnauthorized('$message Create a token at '
          '${config.resolvePath('auth/tokens')} and run: '
          'dart pub token add ${config.publicUrl}');

  shelf.Response _refuse(
      shelf.Request req, RouteKind kind, SessionResult result) {
    // Something happened worth telling the person about: their session was
    // ended under them, or they are no longer allowed in. Bouncing them
    // straight back through the provider would either hide the event or, for
    // a blocked account, loop.
    var explain = result.outcome == SessionOutcome.cloned ||
        result.outcome == SessionOutcome.denied ||
        (result.outcome == SessionOutcome.revoked && result.message != null);

    if (kind == RouteKind.web && prefersHtml(req)) {
      if (explain) {
        return withCookies(
            shelf.Response(
                result.outcome == SessionOutcome.denied
                    ? HttpStatus.forbidden
                    : HttpStatus.unauthorized,
                body: accessDeniedPage(
                    result.outcome == SessionOutcome.denied
                        ? 'Access denied'
                        : 'Your session was ended',
                    result.message ?? 'Please sign in again.',
                    offerRetry: result.outcome != SessionOutcome.denied),
                headers: {
                  HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8',
                  HttpHeaders.cacheControlHeader: 'no-store',
                }),
            result.cookies);
      }
      // `no-store` because this diff makes the redirect reachable for
      // `/packages/**.tar.gz` and `/api/**` urls through `_pubApi`'s browser
      // branch. An intermediary keying on the url alone would otherwise be
      // free to store a redirect-to-login against a tarball address and hand
      // it to the next pub client, token and all.
      return withCookies(
          shelf.Response.found('/auth/login?return=${returnTargetFor(req)}',
              headers: {HttpHeaders.cacheControlHeader: 'no-store'}),
          result.cookies);
    }

    return webRefusal(result.message ?? 'authentication required',
        denied: result.outcome == SessionOutcome.denied,
        // The application navigates to the denied page itself, so the
        // reason has to survive a trip through the browser to get there.
        crypto: sessions.crypto,
        cookies: result.cookies);
  }
}

/// The bearer-authenticated caller attached by [AuthMiddleware], if any.
AuthenticatedUser? bearerUserOf(shelf.Request req) =>
    req.context[bearerPrincipalContextKey] as AuthenticatedUser?;

/// Whether that caller answers to no account on this server.
bool bearerIsProvisionalIn(shelf.Request req) =>
    req.context[bearerProvisionalContextKey] == true;

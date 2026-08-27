import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;

import 'auth_config.dart';
import 'auth_pages.dart';
import 'auth_store.dart';
import 'http_helpers.dart';
import 'session.dart';

/// Key under which the signed-in user is placed on the request context, for
/// handlers that need to know who is asking.
const authenticatedUserContextKey = 'in_pub.auth.user';

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

/// Decides which contract a request path falls under.
///
/// Deliberately driven by the path rather than by the `User-Agent`: the
/// existing `isPubClient` check is fine for download counting but trivially
/// spoofed, which makes it unusable for an access decision.
RouteKind classifyRoute(String path, {bool publicBadges = true}) {
  if (path == '/auth' || path.startsWith('/auth/')) return RouteKind.public;
  if (path == '/health') return RouteKind.public;

  if (publicBadges && (path == '/logo' || path.startsWith('/badge/'))) {
    return RouteKind.public;
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

/// Gates every request on a valid session once `--auth` is on.
class AuthMiddleware {
  final AuthConfig config;
  final SessionManager sessions;

  AuthMiddleware({required this.config, required this.sessions});

  shelf.Middleware get middleware => (shelf.Handler inner) {
        return (shelf.Request req) async {
          var path = req.requestedUri.path;
          var kind = classifyRoute(path, publicBadges: config.publicBadges);

          if (kind == RouteKind.public) return inner(req);

          // Phase one leaves the pub client exactly as it was: publishing
          // still authenticates the way it always did, and dependency
          // resolution stays open. Closing this is a separate, deliberate
          // step, because it breaks every consumer that has not yet run
          // `dart pub token add`.
          if (kind == RouteKind.pubApi) return inner(req);

          var result = await sessions.resolve(req);
          if (result.isAuthenticated) {
            var response = await inner(req.change(context: {
              authenticatedUserContextKey: result.user,
            }));
            return withCookies(response, result.cookies);
          }

          return _refuse(req, kind, result);
        };
      };

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
      var target = Uri.encodeComponent(req.requestedUri.path +
          (req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : ''));
      return withCookies(
          shelf.Response.found('/auth/login?return=$target'), result.cookies);
    }

    return withCookies(
        shelf.Response(
            result.outcome == SessionOutcome.denied
                ? HttpStatus.forbidden
                : HttpStatus.unauthorized,
            body: json.encode({
              'error': result.message ?? 'authentication required',
              // Lets the web UI send the browser somewhere useful instead of
              // guessing the sign-in path.
              'login': '/auth/login',
            }),
            headers: {
              HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
              HttpHeaders.cacheControlHeader: 'no-store',
            }),
        result.cookies);
  }
}

/// The signed-in user attached by [AuthMiddleware], if any.
StoredUser? userOf(shelf.Request req) =>
    req.context[authenticatedUserContextKey] as StoredUser?;

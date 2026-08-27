import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import 'auth_config.dart';
import 'auth_pages.dart';
import 'auth_store.dart';
import 'crypto_box.dart';
import 'http_helpers.dart';
import 'identity.dart';
import 'session.dart';

final _log = Logger('in_pub.auth');

const _loginCookieName = 'inpub_login';

/// Everything served under `/auth/`.
class AuthRoutes {
  final AuthConfig config;
  final AuthStore store;
  final IdentityProvider provider;
  final SessionManager sessions;
  final CryptoBox crypto;

  AuthRoutes({
    required this.config,
    required this.store,
    required this.provider,
    required this.sessions,
    required this.crypto,
  });

  Router get router => Router()
    ..get('/auth/login', _login)
    ..get('/auth/callback', _callback)
    ..get('/auth/logout', _logout)
    ..post('/auth/logout', _logout)
    ..get('/auth/signed-out', (shelf.Request _) => _html(signedOutPage()))
    ..get('/auth/me', _me)
    ..get('/auth/sessions', _sessionsPage)
    ..post('/auth/sessions/revoke', _revokeSession)
    ..get('/auth/admin', _adminPage)
    ..post('/auth/admin/action', _adminAction);

  // ---------------------------------------------------------------- sign in

  Future<shelf.Response> _login(shelf.Request req) async {
    var target = safeReturnPath(req.requestedUri.queryParameters['return']);

    // Already signed in: nothing to do but go where they were headed.
    var existing = await sessions.resolve(req);
    if (existing.isAuthenticated) {
      return _redirect(target, cookies: existing.cookies);
    }

    var state = CryptoBox.randomToken();
    var nonce = CryptoBox.randomToken();
    var verifier = CryptoBox.randomToken(64);

    Uri authorizationUrl;
    try {
      authorizationUrl = await provider.authorizationUrl(
        state: state,
        nonce: nonce,
        codeChallenge: CryptoBox.codeChallenge(verifier),
      );
    } on IdentityUnavailableException catch (e) {
      _log.severe('cannot start sign-in: ${e.message}');
      return _html(
          authErrorPage('The identity provider could not be reached. '
              'Please try again in a moment.'),
          status: HttpStatus.serviceUnavailable);
    }

    // The login state rides along in a signed cookie rather than a server-side
    // table: it is single-use, short-lived, and needs no coordination.
    var payload = crypto.sign(base64Url.encode(utf8.encode(json.encode({
      's': state,
      'n': nonce,
      'v': verifier,
      'r': target,
    }))));

    return _redirect(authorizationUrl.toString(), cookies: [
      buildCookie(_loginCookieName, payload,
          secure: !config.insecureCookie, maxAge: const Duration(minutes: 10)),
      // Any half-finished session is in the way now.
      sessions.deleteCookie(),
    ]);
  }

  Future<shelf.Response> _callback(shelf.Request req) async {
    var params = req.requestedUri.queryParameters;
    var clearLoginCookie = buildCookie(_loginCookieName, '',
        secure: !config.insecureCookie, maxAge: Duration.zero);

    // Which parameters and cookies arrived, without their values: the code
    // and state are single-use secrets, but knowing whether they turned up at
    // all is most of the diagnosis.
    _log.fine('callback: parameters ${params.keys.join(', ')}; '
        'login cookie ${parseCookies(req).containsKey(_loginCookieName) ? 'present' : 'MISSING'}');

    var providerError = params['error'];
    if (providerError != null) {
      var description = params['error_description'] ?? providerError;
      _log.info('provider refused the sign-in: $description');
      return _html(
          authErrorPage('The identity provider refused the sign-in: '
              '$description'),
          status: HttpStatus.forbidden,
          cookies: [clearLoginCookie]);
    }

    var raw = parseCookies(req)[_loginCookieName];
    var payload = raw == null ? null : crypto.verify(raw);
    if (payload == null) {
      return _html(
          authErrorPage('This sign-in link is no longer valid. It may have '
              'expired, or cookies may be blocked for this site.'),
          status: HttpStatus.badRequest,
          cookies: [clearLoginCookie]);
    }

    Map<String, dynamic> stateData;
    try {
      stateData = json.decode(utf8.decode(base64Url.decode(payload)))
          as Map<String, dynamic>;
    } catch (_) {
      return _html(authErrorPage('This sign-in link could not be read.'),
          status: HttpStatus.badRequest, cookies: [clearLoginCookie]);
    }

    var expectedState = stateData['s'] as String? ?? '';
    var returnedState = params['state'] ?? '';
    if (expectedState.isEmpty ||
        !CryptoBox.constantTimeEquals(expectedState, returnedState)) {
      // Either a stale tab or a forged callback; both end here.
      _log.warning('rejected a callback whose state did not match');
      return _html(
          authErrorPage('This sign-in could not be verified. Please start '
              'again from the beginning.'),
          status: HttpStatus.badRequest,
          cookies: [clearLoginCookie]);
    }

    var code = params['code'];
    if (code == null || code.isEmpty) {
      return _html(
          authErrorPage('The identity provider returned no '
              'authorization code.'),
          status: HttpStatus.badRequest,
          cookies: [clearLoginCookie]);
    }

    OidcTokens tokens;
    AuthenticatedUser identity;
    try {
      tokens = await provider.exchangeCode(
        code: code,
        codeVerifier: stateData['v'] as String? ?? '',
        nonce: stateData['n'] as String? ?? '',
      );
      identity = await provider.userInfo(tokens.accessToken);
    } on IdentityRevokedException catch (e) {
      _log.info('sign-in rejected by the provider: ${e.message}');
      return _html(
          accessDeniedPage('Access denied',
              'The identity provider did not authorise this account.'),
          status: HttpStatus.forbidden,
          cookies: [clearLoginCookie]);
    } on IdentityUnavailableException catch (e) {
      _log.severe('sign-in failed: ${e.message}');
      return _html(authErrorPage(e.message),
          status: HttpStatus.serviceUnavailable, cookies: [clearLoginCookie]);
    }

    if (!config.isAllowedGroup(identity.groups)) {
      _log.info('denied ${identity.id}: not in ${config.allowedGroups}');
      return _html(
          accessDeniedPage(
              'Access denied',
              'Your account is not a member of a group with access to this '
                  'package repository. Ask an administrator to add you to one '
                  'of: ${config.allowedGroups.join(', ')}.',
              offerRetry: false),
          status: HttpStatus.forbidden,
          cookies: [clearLoginCookie]);
    }

    // A local block is an administrator's decision here and must survive a
    // successful sign-in on the provider — otherwise blocking someone would
    // last only until they clicked "sign in" again.
    var known = await store.getUser(identity.id);
    if (known != null && known.status == UserStatus.blockedLocal) {
      _log.info('denied ${identity.id}: blocked on this server');
      return _html(
          accessDeniedPage(
              'Access denied',
              known.blockedReason ??
                  'Your access to this package repository has been withdrawn.',
              offerRetry: false),
          status: HttpStatus.forbidden,
          cookies: [clearLoginCookie]);
    }

    var refreshToken = tokens.refreshToken;
    await store.upsertUser(
      identity,
      refreshTokenEnc:
          refreshToken == null ? null : crypto.encrypt(refreshToken),
      validatedAt: DateTime.now(),
    );
    // A provider-side revocation that has since been undone: the provider is
    // vouching for them again, so let them back in.
    if (known != null && known.status == UserStatus.blockedUpstream) {
      await store.setUserStatus(identity.id, UserStatus.active);
    }

    var cookie = await sessions.create(req, identity, idToken: tokens.idToken);
    _log.info('signed in ${identity.id} (${identity.email})');

    return _redirect(safeReturnPath(stateData['r'] as String?),
        cookies: [cookie, clearLoginCookie]);
  }

  // --------------------------------------------------------------- sign out

  /// Ends the session.
  ///
  /// Reachable by GET as well as POST. A forged cross-site request can
  /// therefore sign someone out, which is an annoyance rather than a breach —
  /// and worth the plain link it buys.
  Future<shelf.Response> _logout(shelf.Request req) async {
    var result = await sessions.resolve(req);
    var session = result.session;
    String? idToken;
    if (session != null) {
      idToken = session.idToken;
      await sessions.destroy(session);
      _log.info('signed out ${session.userId}');
    }

    var cookies = [sessions.deleteCookie()];

    if (config.rpInitiatedLogout) {
      var endSession = await provider.endSessionUrl(
        idToken: idToken,
        postLogoutRedirect: config.resolvePath('auth/signed-out'),
      );
      if (endSession != null) {
        return _redirect(endSession.toString(), cookies: cookies);
      }
    }
    return _html(signedOutPage(), cookies: cookies);
  }

  // ------------------------------------------------------------------- data

  Future<shelf.Response> _me(shelf.Request req) async {
    var result = await sessions.resolve(req);
    var user = result.user;
    if (user == null) {
      return _json({'authenticated': false}, cookies: result.cookies);
    }
    return _json({
      'authenticated': true,
      'id': user.id,
      'email': user.email,
      'name': user.displayName,
      'groups': user.groups,
      'admin': config.isAdmin(user.groups),
    }, cookies: result.cookies);
  }

  // --------------------------------------------------------------- sessions

  Future<shelf.Response> _sessionsPage(shelf.Request req) async {
    var result = await sessions.resolve(req);
    if (!result.isAuthenticated) return _requireSignIn(req, result);

    var user = result.user!;
    var list = await store.listUserSessions(user.id);
    return _html(
        sessionsPage(
          user: user,
          sessions: list,
          currentSessionId: result.session!.id,
          csrfToken: _csrfToken(result.session!.id),
          isAdmin: config.isAdmin(user.groups),
        ),
        cookies: result.cookies);
  }

  Future<shelf.Response> _revokeSession(shelf.Request req) async {
    var result = await sessions.resolve(req);
    if (!result.isAuthenticated) return _requireSignIn(req, result);

    var form = Uri.splitQueryString(await req.readAsString());
    if (!_checkCsrf(form, result.session!.id)) {
      return _html(authErrorPage('This request could not be verified.'),
          status: HttpStatus.forbidden);
    }

    var targetId = form['session'];
    if (targetId == null || targetId.isEmpty) {
      return _redirect('/auth/sessions', cookies: result.cookies);
    }

    var target = await store.getSession(targetId);
    // Only a person's own sessions, and only via a lookup by id — otherwise
    // anyone could end anyone else's by guessing.
    if (target == null || target.userId != result.user!.id) {
      return _html(authErrorPage('That session does not exist.'),
          status: HttpStatus.notFound);
    }

    await store.revokeSession(target.id, 'ended by the account owner');
    _log.info('${result.user!.id} ended session ${target.id}');

    if (target.id == result.session!.id) {
      return _html(signedOutPage(), cookies: [sessions.deleteCookie()]);
    }
    return _redirect('/auth/sessions', cookies: result.cookies);
  }

  // ------------------------------------------------------------------ admin

  Future<shelf.Response> _adminPage(shelf.Request req) async {
    var result = await sessions.resolve(req);
    if (!result.isAuthenticated) return _requireSignIn(req, result);
    if (!config.isAdmin(result.user!.groups)) return _notAdmin();

    var users = await store.listUsers();
    var counts = await store.liveSessionCounts();
    return _html(
        adminPage(
          users: users,
          sessionCounts: counts,
          csrfToken: _csrfToken(result.session!.id),
        ),
        cookies: result.cookies);
  }

  Future<shelf.Response> _adminAction(shelf.Request req) async {
    var result = await sessions.resolve(req);
    if (!result.isAuthenticated) return _requireSignIn(req, result);
    if (!config.isAdmin(result.user!.groups)) return _notAdmin();

    var form = Uri.splitQueryString(await req.readAsString());
    if (!_checkCsrf(form, result.session!.id)) {
      return _html(authErrorPage('This request could not be verified.'),
          status: HttpStatus.forbidden);
    }

    var targetId = form['user'] ?? '';
    var action = form['do'] ?? '';
    var actor = result.user!.id;
    if (targetId.isEmpty) {
      return _redirect('/auth/admin', cookies: result.cookies);
    }

    switch (action) {
      case 'end-sessions':
        var ended = await store.revokeUserSessions(
            targetId, 'ended by an administrator');
        _log.info('$actor ended $ended session(s) for $targetId');
      case 'block':
        await store.setUserStatus(targetId, UserStatus.blockedLocal,
            reason: 'Access to this package repository has been withdrawn by '
                'an administrator.');
        var ended = await store.revokeUserSessions(
            targetId, 'blocked by an administrator');
        _log.info('$actor blocked $targetId and ended $ended session(s)');
      case 'unblock':
        // Back to active, but with no confirmation on record — the next
        // request will make them prove themselves against the provider
        // before anything is served.
        await store.setUserStatus(targetId, UserStatus.active);
        await store.recordValidation(targetId,
            validatedAt: DateTime.fromMillisecondsSinceEpoch(0), failures: 0);
        _log.info('$actor unblocked $targetId');
      default:
        _log.warning('$actor requested unknown admin action "$action"');
    }

    return _redirect('/auth/admin', cookies: result.cookies);
  }

  shelf.Response _notAdmin() => _html(
      accessDeniedPage('Not allowed', 'This page is limited to administrators.',
          offerRetry: false),
      status: HttpStatus.forbidden);

  shelf.Response _requireSignIn(shelf.Request req, SessionResult result) {
    var target = Uri.encodeComponent(
        '${req.requestedUri.path}${req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : ''}');
    return _redirect('/auth/login?return=$target', cookies: result.cookies);
  }

  // ------------------------------------------------------------------ CSRF

  /// A token bound to the session, so a form posted from another site cannot
  /// be replayed even if the cookie were somehow attached.
  String _csrfToken(String sessionId) => crypto.sign('csrf:$sessionId');

  bool _checkCsrf(Map<String, String> form, String sessionId) {
    var supplied = form['csrf'];
    if (supplied == null) return false;
    return CryptoBox.constantTimeEquals(supplied, _csrfToken(sessionId));
  }
}

/// Restricts a post-login redirect to somewhere on this server.
///
/// Anything absolute, protocol-relative or backslash-prefixed would let a
/// crafted link bounce a freshly authenticated person to another site.
String safeReturnPath(String? value) {
  if (value == null || value.isEmpty) return '/';
  var decoded = value;
  try {
    decoded = Uri.decodeComponent(value);
  } catch (_) {}
  if (!decoded.startsWith('/')) return '/';
  if (decoded.startsWith('//') || decoded.startsWith(r'/\')) return '/';
  // Sending someone back into the sign-in flow would loop.
  if (decoded.startsWith('/auth/login') ||
      decoded.startsWith('/auth/callback')) {
    return '/';
  }
  return decoded;
}

shelf.Response _redirect(String location, {List<String> cookies = const []}) =>
    withCookies(shelf.Response.found(location), cookies);

shelf.Response _html(String body,
        {int status = HttpStatus.ok, List<String> cookies = const []}) =>
    withCookies(
        shelf.Response(status, body: body, headers: {
          HttpHeaders.contentTypeHeader: 'text/html; charset=utf-8',
          HttpHeaders.cacheControlHeader: 'no-store',
        }),
        cookies);

shelf.Response _json(Map<String, dynamic> body,
        {int status = HttpStatus.ok, List<String> cookies = const []}) =>
    withCookies(
        shelf.Response(status, body: json.encode(body), headers: {
          HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
          HttpHeaders.cacheControlHeader: 'no-store',
        }),
        cookies);

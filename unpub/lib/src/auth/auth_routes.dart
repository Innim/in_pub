import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';

import 'package:in_pub/unpub_api/lib/models.dart';

import 'auth_config.dart';
import 'auth_pages.dart';
import 'auth_store.dart';
import 'crypto_box.dart';
import 'http_helpers.dart';
import 'identity.dart';
import 'session.dart';
import 'token_service.dart';
import 'user_validator.dart';

final _log = Logger('in_pub.auth');

const _loginCookieName = 'inpub_login';

/// Carries "the callback asked for a fresh consent" from that callback to
/// the sign-in route.
///
/// A cookie rather than a query parameter because acting on it ends the
/// caller's session, and `/auth/login` is a public unauthenticated GET that
/// anything may link to. Read off the query string, `consent=1` let any page
/// sign a visitor out — `SameSite=Lax` sends the session cookie on a
/// top-level navigation — and put the sign-out in the browser's history, so
/// pressing Back after signing in silently did it again and burned another
/// provider consent prompt. Signed, so only a request this server answered
/// counts; single use, because [_login] clears it as it reads it.
const _consentCookieName = 'inpub_consent';

/// Everything served under `/auth/`.
class AuthRoutes {
  final AuthConfig config;
  final AuthStore store;
  final IdentityProvider provider;
  final SessionManager sessions;
  final TokenService tokens;
  final CryptoBox crypto;

  /// Whether [email] is on any package's uploader list.
  ///
  /// The package metadata lives outside this layer, and this is the only
  /// thing here that has to consult it: a service token's address is checked
  /// against uploader lists when it publishes, so it must not be handed an
  /// address that already appears on one. Null means the question cannot be
  /// asked, and no service token can be issued at all — guessing would hand
  /// out exactly the escalation the check exists to stop.
  final Future<bool> Function(String email)? isPackageUploader;

  AuthRoutes({
    required this.config,
    required this.store,
    required this.provider,
    required this.sessions,
    required this.tokens,
    required this.crypto,
    this.isPackageUploader,
  });

  /// Built once. A getter here compiled fourteen route patterns afresh on
  /// every request that reached `/auth/`.
  late final Router router = Router()
    ..get('/auth/login', _login)
    ..get('/auth/callback', _callback)
    ..get('/auth/logout', _logout)
    ..post('/auth/logout', _logout)
    ..get('/auth/signed-out', (shelf.Request _) => _html(signedOutPage()))
    ..get('/auth/denied', _denied)
    ..get('/auth/me', _me)
    // Kept as redirects: these were the pages before the account screen
    // moved into the application, and links to them are already out there.
    ..get('/auth/sessions', _toAccount)
    ..get('/auth/tokens', _toAccountTokens)
    ..get('/auth/api/account', _accountView)
    ..post('/auth/api/account/sessions/revoke', _apiRevokeSession)
    ..post('/auth/api/account/tokens/create', _apiCreateToken)
    ..post('/auth/api/account/tokens/revoke', _apiRevokeToken)
    // Kept as a redirect: this was the page before administration moved
    // into the application.
    ..get('/auth/admin', _toAdmin)
    ..get('/auth/api/admin', _adminView)
    ..post('/auth/api/admin/action', _adminAct);

  // ---------------------------------------------------------------- sign in

  Future<shelf.Response> _login(shelf.Request req) async {
    var target = safeReturnPath(req.requestedUri.queryParameters['return']);
    // Set by the callback when the sign-in produced no refresh token and
    // this server has none stored that still opens. Also copied into the
    // login state below, so the callback can tell "we already asked" from
    // "first try" and refuse rather than bounce forever.
    var forceConsent = _consentRequested(req);
    // Cleared whatever this request does with it: one callback asking for a
    // consent buys exactly one forced prompt, and leaving it set would make
    // every later visit to this url end a session again.
    var clearConsentCookie = buildCookie(_consentCookieName, '',
        secure: !config.insecureCookie, maxAge: Duration.zero);

    // Already signed in: nothing to do but go where they were headed. Not
    // when we are here to collect a consent — that is the one case where an
    // existing session is exactly what we are trying to make revalidatable,
    // and it is ended further down instead.
    var existing = await sessions.resolve(req);
    if (existing.isAuthenticated && !forceConsent) {
      return _redirect(target,
          cookies: [...existing.cookies, clearConsentCookie]);
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
        forceConsent: forceConsent,
      );
    } on IdentityUnavailableException catch (e) {
      _log.severe('cannot start sign-in: ${e.message}');
      return _html(
          authErrorPage('The identity provider could not be reached. '
              'Please try again in a moment.'),
          // The consent cookie is deliberately left alone: this answer
          // leaves the person exactly as they were and invites them to
          // retry, and the retry still needs the consent the callback asked
          // for.
          status: HttpStatus.serviceUnavailable);
    }

    // The login state rides along in a signed cookie rather than a server-side
    // table: it is single-use, short-lived, and needs no coordination.
    var payload = crypto.sign(base64Url.encode(utf8.encode(json.encode({
      's': state,
      'n': nonce,
      'v': verifier,
      'r': target,
      'c': forceConsent,
    }))));

    // Ending the session the browser arrived with, but only now that there
    // is somewhere to send it. Deleting the cookie below stops this browser
    // presenting the session; it does not end it, so the row would stay live
    // for the whole idle window — counted on the administration screen,
    // listed with a working End button, and re-checked by every sweep — for
    // a browser that can no longer make a single request with it. The same
    // reason the group check in `session.dart` ends the one it refuses.
    //
    // After the authorization url, not before: the failure above answers
    // with an error page and leaves the person exactly as they were, and a
    // provider that is momentarily unreachable is no reason to sign anybody
    // out.
    var superseded = forceConsent ? existing.session : null;
    if (superseded != null) {
      await sessions.destroy(superseded,
          reason: 'signing in again to renew the provider consent');
    }

    return _redirect(authorizationUrl.toString(), cookies: [
      buildCookie(_loginCookieName, payload,
          secure: !config.insecureCookie, maxAge: const Duration(minutes: 10)),
      // Any half-finished session is in the way now.
      sessions.deleteCookie(),
      clearConsentCookie,
    ]);
  }

  /// Whether the callback asked this sign-in to force a fresh consent.
  ///
  /// The deadline is checked here rather than left to the cookie's
  /// `Max-Age`. A signature over a fixed word would be one value, good
  /// forever and the same for everybody: anyone able to write a cookie for
  /// this domain — a sibling subdomain, a stale CNAME, the same neighbours
  /// the CORS policy is drawn against — could replay it indefinitely to sign
  /// a visitor out and force a consent prompt on every visit. `Max-Age` does
  /// not help, being the client's to honour. Carrying the deadline inside
  /// what is signed puts it on this side.
  bool _consentRequested(shelf.Request req) {
    var raw = parseCookies(req)[_consentCookieName];
    if (raw == null) return false;
    var payload = crypto.verify(raw);
    if (payload == null || !payload.startsWith(_consentPrefix)) return false;
    var until = int.tryParse(payload.substring(_consentPrefix.length));
    return until != null && DateTime.now().millisecondsSinceEpoch < until;
  }

  /// What the consent cookie says once unwrapped: the word, then the instant
  /// it stops counting.
  static String _consentPayload(DateTime until) =>
      '$_consentPrefix${until.millisecondsSinceEpoch}';

  static const _consentPrefix = 'consent:';

  /// How long a consent request stays good for. One hop through the
  /// provider, so minutes rather than hours.
  static const _consentWindow = Duration(minutes: 10);

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

    OidcTokens oidcTokens;
    AuthenticatedUser identity;
    try {
      oidcTokens = await provider.exchangeCode(
        code: code,
        codeVerifier: stateData['v'] as String? ?? '',
        nonce: stateData['n'] as String? ?? '',
      );
      identity = await provider.userInfo(oidcTokens.accessToken);
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

    var refreshToken = oidcTokens.refreshToken;
    // `upsertUser` leaves the stored token alone when handed null, so a
    // sign-in that returned none is not necessarily a sign-in with none: an
    // earlier one may have left a usable token behind.
    // Decrypts, not merely present. `setUserStatus` deliberately keeps the
    // ciphertext when marking an account `needsSignIn`, so after the signing
    // secret is rotated every record still *has* one — it just no longer
    // opens. Treating that as "can revalidate" produced the exact
    // sign-in-then-kicked-out loop this check exists to prevent.
    var storedIsUsable = known?.refreshTokenEnc != null &&
        crypto.decrypt(known!.refreshTokenEnc!) != null;
    var canRevalidate = refreshToken != null || storedIsUsable;
    if (!canRevalidate) {
      // Signing them in here would work for one revalidation interval and
      // then throw them out, over and over, because the background check has
      // nothing to ask the provider with.
      var alreadyAsked = stateData['c'] == true;
      if (!alreadyAsked) {
        // Most providers issue a refresh token only on the *first* consent,
        // so a second sign-in after the signing secret was rotated returns
        // none — and every stored one is now undecipherable. Asking the
        // provider to prompt again is what produces a fresh one. Refusing
        // outright here, as an earlier revision did, locked every account on
        // such a provider out of the server permanently, with the startup
        // warning still telling the operator that signing in was the fix.
        _log.info('no usable refresh token for ${identity.id}; asking the '
            'provider to prompt for consent again');
        return _redirect(
            '/auth/login?return='
            '${Uri.encodeComponent(safeReturnPath(stateData['r'] as String?))}',
            cookies: [
              clearLoginCookie,
              // Short-lived at both ends: this is one hop, and a request
              // that never arrives must not leave the next visit to
              // `/auth/login` ending a session. The deadline is signed into
              // the value as well as set as `Max-Age`, because only the
              // former is ours to enforce.
              buildCookie(
                  _consentCookieName,
                  crypto.sign(
                      _consentPayload(DateTime.now().add(_consentWindow))),
                  secure: !config.insecureCookie,
                  maxAge: _consentWindow),
            ]);
      }
      _log.severe(
          'the identity provider returned no refresh token for ${identity.id} '
          'even after being asked to prompt for consent, so this server '
          'cannot re-check the account and will not sign them in. Add '
          '"offline_access" to --auth-scopes, or configure the provider to '
          'issue refresh tokens for this client.');
      return _html(
          accessDeniedPage(
              'Cannot complete sign-in',
              'The identity provider did not issue a refresh token, which '
                  'this server needs to keep checking that your account is '
                  'still active. Please ask an administrator to enable the '
                  '"offline_access" scope for this application.',
              offerRetry: false),
          status: HttpStatus.forbidden,
          cookies: [clearLoginCookie]);
    }

    await store.upsertUser(
      identity,
      refreshTokenEnc:
          refreshToken == null ? null : crypto.encrypt(refreshToken),
      validatedAt: DateTime.now(),
    );
    // The address check that guards service tokens only runs one way round:
    // it refuses a token that would take an address an account already
    // holds. An account arriving second at an address a live service token
    // already publishes as is the same collision, and nothing was looking
    // for it — `UserValidator` sees an existing account *change* address,
    // which a first sign-in is not.
    if (known == null ||
        normalizeAddress(known.email) != normalizeAddress(identity.email)) {
      await warnOnServiceTokenClash(store, identity.email, identity.id);
    }

    // Either the provider is vouching for them again after a revocation, or
    // this is the sign-in that `needsSignIn` was waiting for. Safe to clear
    // either way: the check above established there is something to
    // revalidate with, which is the one thing `needsSignIn` means is missing.
    if (known != null &&
        (known.status == UserStatus.blockedUpstream ||
            known.status == UserStatus.needsSignIn)) {
      await store.setUserStatus(identity.id, UserStatus.active);
    }

    var cookie =
        await sessions.create(req, identity, idToken: oidcTokens.idToken);
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
      idToken = sessions.idTokenOf(session);
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

  /// The page the application sends somebody to when its own request was
  /// refused outright.
  ///
  /// The refusal's wording travels in the query string, signed, because that
  /// navigation is all the browser has left of the answer it was given —
  /// and "your access has been withdrawn, an administrator can restore it"
  /// is the wrong thing to tell somebody whose session ended because the
  /// allowed groups changed. An unsigned or missing value falls back to the
  /// general wording rather than to whatever the link happened to say.
  shelf.Response _denied(shelf.Request req) => _html(accessDeniedPage(
      'Access denied',
      readRefusalDetail(crypto, req.requestedUri.queryParameters['d']) ??
          'Your access to this package repository has been withdrawn. An '
              'administrator can restore it.',
      offerRetry: false));

  shelf.Response _toAccount(shelf.Request req) =>
      _redirect('/account?tab=sessions');

  shelf.Response _toAccountTokens(shelf.Request req) => _redirect('/account');

  // ----------------------------------------------------------- account API

  /// Everything the account screen shows, in one response.
  Future<shelf.Response> _accountView(shelf.Request req) async {
    var result = await sessions.resolve(req);
    if (!result.isAuthenticated) return _apiUnauthorized(result);
    return _accountViewOf(result);
  }

  Future<shelf.Response> _accountViewOf(SessionResult result) async {
    var user = result.user!;
    var isAdmin = config.isAdmin(user.groups);
    var now = DateTime.now();

    // Overlapped through a record's `wait`, which keeps the element types
    // and, unlike awaiting them one at a time, has a listener on each from
    // the start — otherwise a failure on the second while the first is still
    // running escapes the request as an uncaught async error.
    List<StoredSession> sessionRows;
    List<StoredToken> tokenRows;
    List<StoredToken> serviceRows;
    try {
      (sessionRows, tokenRows, serviceRows) = await (
        store.listUserSessions(user.id),
        store.listTokensOfUser(user.id),
        isAdmin ? _serviceTokensOrNone() : Future.value(const <StoredToken>[]),
      ).wait;
    } on ParallelWaitError catch (e) {
      // `wait` reports the whole record, so what actually failed is inside
      // the error rather than on it. Letting that escape made a fault in any
      // one of three queries an opaque 500 on the screen a person opens to
      // find out what their account is doing.
      _log.severe('could not read the account view for ${user.id}: '
          '${e.errors}');
      return _apiError(
          'Your account details could not be read just now. Please try again.',
          status: HttpStatus.serviceUnavailable,
          cookies: result.cookies);
    }

    // Only the sessions are filtered here, and only for the idle window: the
    // store's query drops revoked and expired rows itself, but it cannot
    // express "unused for longer than `--auth-session-idle`", which is
    // configuration this layer holds. Showing one of those as live would put
    // an "End" button on a session that is already gone.
    //
    // The token listings get nothing. Both stores enforce liveness in the
    // query and both say so in a comment warning that a caller filtering
    // afterwards would pass in test and read history in production — so
    // re-applying it here put the rule in a third place, where it can only
    // ever drift from the two that decide it.
    var sessions_ = sessionRows
        .where((s) => !s.isRevoked && !s.isExpired(now, config.sessionIdle))
        .map(_sessionView)
        .toList();
    var tokens_ = tokenRows.map(_tokenView).toList();
    var serviceTokens_ = serviceRows.map(_tokenView).toList();
    var view = AccountView(
      user.id,
      user.email,
      user.displayName,
      user.groups,
      isAdmin,
      _csrfToken(result.session!.id),
      result.session!.id,
      sessions_,
      tokens_,
      serviceTokens_,
      config.protectPubApi,
      config.publicUrl.toString(),
    );
    return _apiOk(view.toJson(), cookies: result.cookies);
  }

  /// The service tokens, or none of them.
  ///
  /// Administrators only, and purely informational: they belong to no
  /// account and nothing on this screen acts on them. A transient fault
  /// reading them must not join the record's failure and take the sessions
  /// and personal tokens — the two things the screen exists for — down with
  /// it.
  Future<List<StoredToken>> _serviceTokensOrNone() =>
      store.listServiceTokens().catchError((Object e) {
        _log.warning('could not list the service tokens for the account '
            'screen: $e');
        return const <StoredToken>[];
      });

  static AccountSession _sessionView(StoredSession session) => AccountSession(
        session.id,
        session.ip,
        // The current address is shown on its own, so only the earlier ones
        // are interesting here.
        session.ipHistory.length > 1
            ? session.ipHistory.sublist(0, session.ipHistory.length - 1)
            : const [],
        session.createdAt,
        session.lastSeenAt,
        session.expiresAt,
      );

  static AccountToken _tokenView(StoredToken token) => AccountToken(
        token.id,
        token.name,
        token.kind.name,
        token.email,
        token.createdBy,
        token.createdAt,
        token.expiresAt,
        token.lastUsedAt,
        token.lastUsedIp,
      );

  Future<shelf.Response> _apiRevokeSession(shelf.Request req) async {
    var guard = await _apiGuard(req);
    if (guard.response != null) return guard.response!;
    var user = guard.result!.user!;

    var body = await _apiBody(req);
    if (body == null) return _apiUnreadableBody(guard.result!);
    var target = await store.getSession(_stringField(body, 'session'));
    // Looked up rather than trusted: without the ownership check anyone could
    // end anyone else's session by guessing an id.
    if (target == null || target.userId != user.id) {
      return _apiError('That session does not exist.',
          status: HttpStatus.notFound, cookies: guard.result!.cookies);
    }

    // The store's write is conditional on the row still being live, exactly
    // as the token one is, so a second click changes nothing. Answering
    // "ended" regardless reported a success that had not happened and wrote
    // an end into the log that nobody performed — a session an administrator
    // had just closed, or the same button pressed twice.
    if (!await store.revokeSession(target.id, 'ended by the account owner')) {
      return _apiError('That session has already ended.',
          status: HttpStatus.conflict, cookies: guard.result!.cookies);
    }
    _log.info('${user.id} ended session ${target.id}');

    // Ending the session you are looking at signs you out, so the cookie has
    // to go with it.
    if (target.id == guard.result!.session!.id) {
      return _apiOk({'signedOut': true}, cookies: [sessions.deleteCookie()]);
    }
    return _apiOk({'signedOut': false}, cookies: guard.result!.cookies);
  }

  Future<shelf.Response> _apiCreateToken(shelf.Request req) async {
    var guard = await _apiGuard(req);
    if (guard.response != null) return guard.response!;
    var user = guard.result!.user!;

    var body = await _apiBody(req);
    if (body == null) return _apiUnreadableBody(guard.result!);
    var name = _stringField(body, 'name');
    if (name.isEmpty) name = 'unnamed';
    // By rune, not by code unit: cutting at 60 units can split a surrogate
    // pair and leave half a character behind.
    if (name.runes.length > 60) {
      name = String.fromCharCodes(name.runes.take(60));
    }

    // Zero means no expiry, which automation needs: a pipeline that stops on
    // a date nobody wrote down is its own kind of outage.
    var days = _daysField(body, 'lifetimeDays', 90);
    var lifetime = days == 0 ? null : Duration(days: days);

    late IssuedToken issued;
    try {
      if (_stringField(body, 'kind') == 'service') {
        if (!config.isAdmin(user.groups)) {
          return _apiError('Only an administrator can create a service token.',
              status: HttpStatus.forbidden,
              reason: 'notAdmin',
              cookies: guard.result!.cookies);
        }
        var email = _stringField(body, 'email');
        if (email.isEmpty) {
          return _apiError(
              'A service token needs an address to record publishes against.',
              cookies: guard.result!.cookies);
        }
        // That address is what a publish is recorded as and what the package's
        // uploader list is checked against, so handing out somebody else's
        // would turn "may manage sessions" into "may publish as anyone".
        var refusal = await _whileClaiming(email, () async {
          var refusal = await _checkServiceAddress(email);
          if (refusal != null) return refusal;
          issued = await tokens.issueService(
            createdBy: user.id,
            name: name,
            email: email,
            displayName: name,
            lifetime: lifetime,
          );
          return null;
        });
        if (refusal != null) {
          return _apiError(refusal,
              status: HttpStatus.forbidden, cookies: guard.result!.cookies);
        }
      } else {
        issued = await tokens.issuePersonal(
            owner: user, name: name, lifetime: lifetime);
      }
    } on TokenIssueRefused catch (e) {
      // The identity a token would carry is refused by the thing that writes
      // it, not only by the screen in front: a personal token copies its
      // address off the account, and nothing on this path had ever looked at
      // it.
      _log.warning('refused a token for ${user.id}: ${e.message}');
      return _apiError(e.message,
          status: HttpStatus.forbidden, cookies: guard.result!.cookies);
    }

    _log.info('${user.id} created token "$name" (${issued.record.id})');
    return _apiOk(
        CreatedToken(_tokenView(issued.record), issued.value).toJson(),
        cookies: guard.result!.cookies);
  }

  /// Service-token creations in progress, keyed by the address they claim.
  ///
  /// [_checkServiceAddress] reads and `issueService` writes, and nothing in
  /// between stops a second request passing the same check: two
  /// administrators acting at once each get a token for one identity, and
  /// revoking either leaves the other publishing as that person. A unique
  /// index would be the airtight answer, but it cannot be built on a
  /// deployment that already holds duplicates — and the token's address is
  /// not stored folded, so the index would not even enforce the rule this
  /// check applies. One process owns this collection, so serialising the
  /// pair here closes the window that actually exists; two servers sharing a
  /// database still race, and that is written down as the residual risk.
  final _addressClaims = <String, Future<void>>{};

  /// Runs [work] with nobody else claiming [email].
  Future<T> _whileClaiming<T>(String email, Future<T> Function() work) async {
    var key = normalizeAddress(email);
    var ahead = _addressClaims[key];
    var mine = Completer<void>();
    _addressClaims[key] = mine.future;
    try {
      if (ahead != null) await ahead;
      return await work();
    } finally {
      mine.complete();
      // By identity: a request queued behind this one already holds the
      // slot, and clearing it would let a third run alongside it.
      if (identical(_addressClaims[key], mine.future)) {
        _addressClaims.remove(key);
      }
    }
  }

  /// Why [email] may not be given to a service token, or null if it may.
  ///
  /// Two ways an address can already belong to somebody, and both have to be
  /// checked: it may be an account that has signed in here, and it may be on
  /// a package's uploader list without ever having signed in — which is every
  /// publisher from before authentication existed. Missing the second let an
  /// administrator mint a token carrying a legacy publisher's address and
  /// then publish to, or delete versions from, their packages.
  Future<String?> _checkServiceAddress(String email) async {
    if (!looksLikeEmailAddress(email)) {
      return 'That does not look like an email address. A service token '
          'publishes as the address it carries, and that address is matched '
          'against package uploader lists, so it has to be a full one — an @ '
          'and a domain with a dot in it. A single-label intranet name like '
          '"ci@internal" is refused for that reason.';
    }
    // No exception for the creator's own address. A service token answers to
    // no account — `TokenService.resolve` never consults one — so blocking
    // the administrator who made it, or disabling them upstream, does not
    // stop it. One carrying their own address is a credential that outlives
    // their access to the server, under their own name.
    var claimed = await store.findUsersByEmail(email);
    if (claimed.isNotEmpty) {
      return 'That address belongs to an account on this server. A service '
          'token answers to no account, so blocking that person would not '
          'stop it — give the token an address of its own and add that to '
          'the packages it should reach.';
    }

    // Another service token may already carry it. Neither check above finds
    // that: a service address is in no account and on no uploader list until
    // its token has actually published. Two credentials publishing as one
    // identity is exactly what "give the token an address of its own" is
    // meant to prevent, and revoking one would leave the other working.
    if ((await store.serviceTokensForEmail(email)).isNotEmpty) {
      return 'Another service token already publishes as that address. '
          'Revoke it first, or give this one an address of its own.';
    }

    var owns = isPackageUploader;
    if (owns == null) {
      // Without a way to ask, the honest answer is no. Anything other than
      // the creator's own address might already publish packages here, and
      // guessing wrong hands out exactly the escalation this check exists to
      // stop. Servers started from `bin/in_pub.dart` always supply this.
      return 'This server cannot check whether that address already '
          'publishes packages, so it will not issue a service token. Wire '
          'the package metadata into the auth layer to enable this.';
    }
    bool alreadyPublishes;
    try {
      alreadyPublishes = await owns(email);
    } catch (e) {
      // The closure counts documents in Mongo, so a momentary database fault
      // lands here. Left to escape it became an unhandled 500 and an opaque
      // error page, which is exactly the outcome the paragraph above rules
      // out: when the question cannot be asked, the honest answer is a
      // refusal somebody can read and retry.
      _log.warning('could not check whether $email already publishes '
          'packages: $e');
      return 'This server could not check whether that address already '
          'publishes packages, so it will not issue a service token. Try '
          'again in a moment.';
    }
    if (alreadyPublishes) {
      return 'That address already publishes packages here. A service token '
          'publishes as the address it carries, so give it one of its own '
          'and add that to the packages it should reach.';
    }
    return null;
  }

  Future<shelf.Response> _apiRevokeToken(shelf.Request req) async {
    var guard = await _apiGuard(req);
    if (guard.response != null) return guard.response!;
    var user = guard.result!.user!;

    var body = await _apiBody(req);
    if (body == null) return _apiUnreadableBody(guard.result!);
    var target = await store.getToken(_stringField(body, 'token'));
    // Your own, or any service token if you administer the server. Anything
    // else is somebody else's business.
    var mayRevoke = target != null &&
        (target.userId == user.id ||
            (target.kind == TokenKind.service && config.isAdmin(user.groups)));
    if (!mayRevoke) {
      return _apiError('That token does not exist.',
          status: HttpStatus.notFound, cookies: guard.result!.cookies);
    }

    // Echoed back to whoever presents the token afterwards, so it says what
    // happened and nothing about who did it — an owner revoking their own
    // token should not be told an administrator did. The actor goes to the
    // log.
    // The store's write is conditional on the token still being live, so a
    // second revocation of the same one changes nothing. Answering "revoked"
    // regardless reported a success that had not happened and wrote a
    // revocation into the log that nobody performed — the same shape as the
    // uploader routes that used to say "uploader added" over an update
    // matching no document.
    if (!await store.revokeToken(target.id, 'revoked from the account page')) {
      return _apiError('That token has already been revoked.',
          status: HttpStatus.conflict, cookies: guard.result!.cookies);
    }
    _log.info('${user.id} (${user.email}) revoked token ${target.id}');
    return _apiOk({'revoked': target.id}, cookies: guard.result!.cookies);
  }

  /// Signed in, and the request proves it came from our own page.
  Future<_ApiGuard> _apiGuard(shelf.Request req) async {
    var result = await sessions.resolve(req);
    if (!result.isAuthenticated) {
      return _ApiGuard(response: _apiUnauthorized(result));
    }
    // `SameSite=Lax` already keeps the cookie off cross-site POSTs; this is
    // the second lock, and the reason the token is handed out with the view
    // rather than embedded in a page.
    var supplied = req.headers['x-csrf-token'];
    if (supplied == null ||
        !CryptoBox.constantTimeEquals(
            supplied, _csrfToken(result.session!.id))) {
      return _ApiGuard(
          response: _apiError(
              'This request could not be verified. Reload the page and try '
              'again.',
              status: HttpStatus.forbidden,
              reason: 'staleRequest',
              cookies: result.cookies));
    }
    return _ApiGuard(result: result);
  }

  /// Reads a string field, whatever the client actually sent. An unchecked
  /// cast here turns a mistyped field into a 500 with no explanation.
  static String _stringField(Map<String, dynamic> body, String key) {
    var value = body[key];
    return value is String ? value.trim() : '';
  }

  /// Reads a whole-number field.
  ///
  /// Clamped at both ends. A huge value overflows [Duration] and comes back
  /// as a token that is already expired; JSON also admits infinity, on which
  /// `toInt` throws outright. A negative one falls back to the default
  /// rather than to zero, since zero here means "never expires" and reading
  /// "expire immediately" as that would be the worst of the answers.
  static int _daysField(Map<String, dynamic> body, String key, int fallback) {
    var value = body[key];
    int? days;
    if (value is int) {
      days = value;
    } else if (value is num && value.isFinite) {
      days = value.toInt();
    } else if (value is String) {
      days = int.tryParse(value);
    }
    if (days == null || days < 0) return fallback;
    if (days == 0) return 0;
    return days > 3650 ? 3650 : days;
  }

  /// The posted JSON object, or null when there was one and it could not be
  /// read.
  ///
  /// Null rather than an empty map, because the two mean opposite things to
  /// the caller. Reading a truncated body, or a JSON value that is not an
  /// object, as "no fields given" meant every field fell back to its default
  /// — and on the token route those defaults are a real credential, named
  /// `unnamed` and good for ninety days, issued and returned against a
  /// request the server could not read. The client sees a failure, never
  /// records the one-time value, and the account is left holding a live
  /// credential nobody knows about. Every other malformed input on these
  /// routes answers 400; an unreadable body is not a lesser case.
  ///
  /// An absent body is still an empty map: sending nothing is a request with
  /// no fields, which is readable and which the defaults are for.
  Future<Map<String, dynamic>?> _apiBody(shelf.Request req) async {
    try {
      var text = await req.readAsString();
      if (text.isEmpty) return const {};
      var decoded = json.decode(text);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  shelf.Response _apiUnreadableBody(SessionResult result) => _apiError(
      'This request could not be read. Reload the page and try again.',
      cookies: result.cookies);

  /// A refusal the running web app can act on.
  ///
  /// Never a redirect: an XHR follows one silently and hands the caller the
  /// sign-in page parsed as JSON.
  shelf.Response _apiUnauthorized(SessionResult result) =>
      webRefusal(result.message ?? 'authentication required',
          denied: result.outcome == SessionOutcome.denied,
          crypto: crypto,
          cookies: result.cookies);

  shelf.Response _apiOk(Map<String, dynamic> data,
          {List<String> cookies = const []}) =>
      _json({'data': data}, cookies: cookies);

  shelf.Response _apiError(String message,
          {int status = HttpStatus.badRequest,
          String? reason,
          List<String> cookies = const []}) =>
      _json({
        'error': message,
        // A machine-readable tag where the status alone is ambiguous. 403
        // means both "you are not an administrator" and "this request could
        // not be verified", and a screen that guesses between them tells an
        // administrator they are not one.
        if (reason != null) 'reason': reason,
      }, status: status, cookies: cookies);

  // ------------------------------------------------------------- admin API

  Future<shelf.Response> _adminView(shelf.Request req) async {
    var result = await sessions.resolve(req);
    if (!result.isAuthenticated) return _apiUnauthorized(result);
    if (!config.isAdmin(result.user!.groups)) {
      return _apiNotAdmin(cookies: result.cookies);
    }
    return _adminViewOf(result);
  }

  /// Builds the view from a session that has already been resolved.
  ///
  /// Resolving it again for the same request would rotate the secret a
  /// second time and, worse, throw away the `Set-Cookie` the first rotation
  /// produced — leaving the browser holding a secret that only survives the
  /// rotation grace period.
  Future<shelf.Response> _adminViewOf(SessionResult result) async {
    // Independent, so they overlap — and through `wait`, so a failure on
    // one is not left without a listener while the other runs.
    // One more than shown, so a full page can be told from a page that
    // happens to end exactly at the limit.
    const shown = 200;
    var (counts, userRows) = await (
      store.liveSessionCounts(config.sessionIdle),
      store.listUsers(limit: shown + 1)
    ).wait;
    var truncated = userRows.length > shown;
    if (truncated) userRows = userRows.sublist(0, shown);
    var users = userRows
        .map((user) => AdminUser(
              user.id,
              user.email,
              user.displayName,
              user.groups,
              user.status.name,
              user.blockedReason,
              counts[user.id] ?? 0,
              user.lastValidatedAt,
            ))
        .toList();

    return _apiOk(
        AdminView(_csrfToken(result.session!.id), result.user!.id, users,
                truncated: truncated)
            .toJson(),
        cookies: result.cookies);
  }

  Future<shelf.Response> _adminAct(shelf.Request req) async {
    var guard = await _apiGuard(req);
    if (guard.response != null) return guard.response!;
    var actor = guard.result!.user!;
    if (!config.isAdmin(actor.groups)) {
      return _apiNotAdmin(cookies: guard.result!.cookies);
    }

    var body = await _apiBody(req);
    if (body == null) return _apiUnreadableBody(guard.result!);
    var targetId = _stringField(body, 'user');
    var action = _stringField(body, 'do');
    if (targetId.isEmpty) {
      return _apiError('No user was named.', cookies: guard.result!.cookies);
    }
    if (await store.getUser(targetId) == null) {
      return _apiError('That user does not exist.',
          status: HttpStatus.notFound, cookies: guard.result!.cookies);
    }

    if (action == 'block' && targetId == actor.id) {
      return _apiError(
          'You cannot block yourself: signing in again would be refused, and '
          'nothing short of editing the database would undo it.',
          cookies: guard.result!.cookies);
    }

    switch (action) {
      case 'end-sessions':
        var ended = await store.revokeUserSessions(
            targetId, 'ended by an administrator');
        _log.info('${actor.id} ended $ended session(s) for $targetId');
      case 'block':
        await store.setUserStatus(targetId, UserStatus.blockedLocal,
            reason: 'Access to this package repository has been withdrawn by '
                'an administrator.');
        var ended = await store.revokeUserSessions(
            targetId, 'blocked by an administrator');
        _log.info('${actor.id} blocked $targetId and ended $ended session(s)');
      case 'unblock':
        // Back to active, but with no confirmation on record: the next
        // request makes them prove themselves against the provider before
        // anything is served.
        await store.setUserStatus(targetId, UserStatus.active);
        await store.recordValidation(targetId,
            validatedAt: DateTime.fromMillisecondsSinceEpoch(0), failures: 0);
        _log.info('${actor.id} unblocked $targetId');
      default:
        _log.warning('${actor.id} requested unknown admin action "$action"');
        return _apiError('Unknown action.', cookies: guard.result!.cookies);
    }

    // An administrator who ended their own sessions has just signed out;
    // there is no view left to build, and saying so is more honest than
    // pretending otherwise.
    var own = await store.getSession(guard.result!.session!.id);
    if (own == null || own.isRevoked) {
      return _apiUnauthorized(SessionResult(SessionOutcome.revoked,
          message: 'you ended your own session',
          cookies: [sessions.deleteCookie()]));
    }
    return _adminViewOf(guard.result!);
  }

  shelf.Response _apiNotAdmin({List<String> cookies = const []}) =>
      _apiError('This is limited to administrators.',
          status: HttpStatus.forbidden, reason: 'notAdmin', cookies: cookies);

  shelf.Response _toAdmin(shelf.Request req) => _redirect('/admin');

  // ------------------------------------------------------------------ CSRF

  /// A token bound to the session, so a form posted from another site cannot
  /// be replayed even if the cookie were somehow attached.
  String _csrfToken(String sessionId) => crypto.sign('csrf:$sessionId');
}

/// Restricts a post-login redirect to somewhere on this server.
///
/// Anything absolute, protocol-relative or backslash-prefixed would let a
/// crafted link bounce a freshly authenticated person to another site.
String safeReturnPath(String? value) {
  if (value == null || value.isEmpty) return '/';
  // Already decoded: this arrives from `Uri.queryParameters`, and decoding a
  // second time turns a literal percent in the query into a dangling one.
  var decoded = value;
  // A control character here reaches the `Location` header, where dart:io
  // refuses to write it — inside shelf_io, past the try that would have made
  // that a 500 — so the caller gets a dropped connection and no answer at
  // all, from a url anyone can hand out without signing in. Refused rather
  // than encoded: nothing on this server produces a path with a newline or a
  // NUL in it, so a value carrying one was crafted.
  if (decoded.codeUnits.any((c) => c < 0x20 || c == 0x7f)) return '/';
  if (!decoded.startsWith('/')) return '/';
  if (decoded.startsWith('//') || decoded.startsWith(r'/\')) return '/';
  // Sending someone back into the sign-in flow would loop.
  if (decoded.startsWith('/auth/login') ||
      decoded.startsWith('/auth/callback')) {
    return '/';
  }
  // Everything above this line is a refusal; this is not. The value arrives
  // already percent-decoded, so a search for a word with an accent or in
  // Cyrillic — `/packages?q=привет`, which the application's own search box
  // produces — comes back as bytes dart:io will not write, and sending that
  // person to `/` after signing in would be a strange way to answer. Encoded
  // back into the form a url carries it in, which the browser resolves to
  // exactly where they were.
  return percentEncodeUnwritable(decoded);
}

/// A 302 from the auth routes, never stored.
///
/// `no-store` for the same reason [_html] and [_json] carry it, and for one
/// more that only redirects have: several of these hand out a `Set-Cookie`.
/// The callback answers with the freshly minted session cookie, the
/// already-signed-in branch of `/auth/login?return=/` — a url stable enough
/// for a proxy to key on — answers with a rotated session secret, and the
/// bounce to the provider carries the signed login-state cookie. A cache
/// configured to hold redirects would replay one of those to whoever asks
/// for the same url next, handing them somebody else's session.
shelf.Response _redirect(String location, {List<String> cookies = const []}) =>
    withCookies(
        shelf.Response.found(location, headers: {
          HttpHeaders.cacheControlHeader: 'no-store',
        }),
        cookies);

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

/// Either a verified request or the refusal to send instead.
class _ApiGuard {
  final SessionResult? result;
  final shelf.Response? response;
  const _ApiGuard({this.result, this.response});
}

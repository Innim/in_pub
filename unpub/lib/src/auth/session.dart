import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'auth_config.dart';
import 'auth_store.dart';
import 'crypto_box.dart';
import 'http_helpers.dart';
import 'identity.dart';
import 'user_validator.dart';

final _log = Logger('in_pub.auth');

const sessionCookieName = 'inpub_session';

/// Why a request is or is not carrying a usable session.
enum SessionOutcome {
  ok,

  /// No session cookie at all — an anonymous visitor.
  absent,

  /// A cookie that does not correspond to a usable session. Treated exactly
  /// like [absent] by callers; kept apart for the log.
  invalid,

  expired,

  /// Ended deliberately: logged out, or terminated by an administrator.
  revoked,

  /// Two different clients were seen using this session. See
  /// [SessionManager.resolve].
  cloned,

  /// The person is known but no longer allowed in.
  denied,
}

/// The result of examining a request's session cookie.
class SessionResult {
  final SessionOutcome outcome;
  final StoredUser? user;
  final StoredSession? session;

  /// Cookies the response must carry — a rotated secret, or a deletion.
  final List<String> cookies;

  /// Human-readable explanation, shown on the "no access" page.
  final String? message;

  const SessionResult(
    this.outcome, {
    this.user,
    this.session,
    this.cookies = const [],
    this.message,
  });

  bool get isAuthenticated => outcome == SessionOutcome.ok && user != null;
}

/// Issues, validates and retires browser sessions.
class SessionManager {
  final AuthConfig config;
  final AuthStore store;
  final CryptoBox crypto;
  final UserValidator validator;

  /// How often `lastSeenAt` is written back. Every request would mean a write
  /// per request for a field only the idle timeout and the session list read.
  static const _touchInterval = Duration(minutes: 1);

  /// Cap on the recorded address history, so a session document cannot grow
  /// without bound on a mobile connection.
  static const _maxIpHistory = 10;

  SessionManager({
    required this.config,
    required this.store,
    required this.crypto,
    required this.validator,
  });

  bool get _secureCookies => !config.insecureCookie;

  /// Starts a session for [user] and returns the cookie to set.
  Future<String> create(
    shelf.Request req,
    AuthenticatedUser user, {
    String? idToken,
  }) async {
    var now = DateTime.now();
    var id = CryptoBox.randomToken();
    var secret = CryptoBox.randomToken();
    var ip = clientIp(req, config.trustedProxies);

    await store.createSession(StoredSession(
      id: id,
      userId: user.id,
      secretHash: CryptoBox.hash(secret),
      rotatedAt: now,
      uaHash: CryptoBox.hash(req.headers['user-agent'] ?? ''),
      ip: ip,
      ipHistory: [if (ip.isNotEmpty) ip],
      createdAt: now,
      lastSeenAt: now,
      expiresAt: now.add(config.sessionTtl),
      idToken: idToken,
    ));

    return _cookie('$id.$secret', maxAge: config.sessionTtl);
  }

  /// Examines the session cookie on [req].
  ///
  /// Besides the obvious checks this is where a stolen cookie is caught. The
  /// session secret is re-issued periodically; the previous one keeps working
  /// only until somebody presents the new one. After that, a request still
  /// carrying the old secret can only come from a second holder of the
  /// cookie, and the session is ended.
  Future<SessionResult> resolve(shelf.Request req) async {
    var raw = parseCookies(req)[sessionCookieName];
    if (raw == null || raw.isEmpty) {
      return const SessionResult(SessionOutcome.absent);
    }

    var cut = raw.indexOf('.');
    if (cut <= 0 || cut == raw.length - 1) {
      return SessionResult(SessionOutcome.invalid, cookies: [_deleteCookie()]);
    }
    var id = raw.substring(0, cut);
    var secret = raw.substring(cut + 1);

    var session = await store.getSession(id);
    if (session == null) {
      return SessionResult(SessionOutcome.invalid, cookies: [_deleteCookie()]);
    }
    if (session.isRevoked) {
      // Blocking someone also ends their sessions, so the revocation is what
      // is seen first. Report the underlying reason instead: telling a
      // blocked person to sign in again only sends them round the provider
      // to be refused at the far end.
      var owner = await store.getUser(session.userId);
      if (owner != null && !owner.isActive) {
        return SessionResult(SessionOutcome.denied,
            cookies: [_deleteCookie()],
            message: owner.blockedReason ?? session.revokedReason);
      }
      return SessionResult(SessionOutcome.revoked,
          cookies: [_deleteCookie()], message: session.revokedReason);
    }

    var now = DateTime.now();
    if (session.isExpired(now, config.sessionIdle)) {
      return SessionResult(SessionOutcome.expired, cookies: [_deleteCookie()]);
    }

    var presented = CryptoBox.hash(secret);
    var matchesCurrent = session.secretHash.isNotEmpty &&
        CryptoBox.constantTimeEquals(presented, session.secretHash);
    var previous = session.prevSecretHash;
    var matchesPrevious = !matchesCurrent &&
        previous != null &&
        previous.isNotEmpty &&
        CryptoBox.constantTimeEquals(presented, previous);

    if (!matchesCurrent && !matchesPrevious) {
      // A legitimate client always holds either the current secret or, if it
      // missed the last update, the previous one. Anything else means the
      // cookie was copied and the copy has fallen behind.
      return _handleClone(session, req, 'session secret is not recognised');
    }

    if (matchesPrevious) {
      if (session.currentSecretSeen) {
        // Somebody already used the new secret, so this request is a second
        // client working from a stale copy of the cookie.
        return _handleClone(
            session, req, 'session was used from two different clients');
      }
      var until = session.prevValidUntil;
      if (until != null && now.isAfter(until)) {
        return SessionResult(SessionOutcome.expired,
            cookies: [_deleteCookie()]);
      }
    }

    // A cookie that travelled to another browser is not this session.
    var uaHash = CryptoBox.hash(req.headers['user-agent'] ?? '');
    if (session.uaHash.isNotEmpty &&
        !CryptoBox.constantTimeEquals(uaHash, session.uaHash)) {
      return _handleClone(
          session,
          req,
          'session was used from a different '
          'client application');
    }

    var ip = clientIp(req, config.trustedProxies);
    if (config.bindIp &&
        session.ip.isNotEmpty &&
        ip.isNotEmpty &&
        ip != session.ip) {
      return _handleClone(
          session, req, 'session was used from a different address');
    }

    var user = await store.getUser(session.userId);
    if (user == null) {
      await store.revokeSession(session.id, 'user record is gone');
      return SessionResult(SessionOutcome.invalid, cookies: [_deleteCookie()]);
    }

    var validation = await validator.ensureValid(user);
    if (!validation.isAllowed) {
      return SessionResult(SessionOutcome.denied,
          cookies: [_deleteCookie()], message: validation.reason);
    }

    var cookies = <String>[];
    if (matchesCurrent) {
      if (!session.currentSecretSeen) {
        // First sighting of the freshly issued secret: the client is caught
        // up, so the old one is retired and any later use of it is a clone.
        await store.confirmSecretSeen(session.id, session.secretHash);
      } else if (now.difference(session.rotatedAt) >= config.sessionRotate) {
        var rotated =
            await _rotate(session, now, keepValid: session.secretHash);
        if (rotated != null) cookies.add(rotated);
      }
    } else {
      // The client is still on the previous secret, so it never received the
      // current one and we cannot resend it — only its hash is stored. Issue
      // a fresh secret instead, keeping the one the client actually holds
      // valid so the rest of an in-flight burst is not mistaken for a clone.
      _log.fine('session ${session.id} missed a cookie update; re-issuing');
      var rotated = await _rotate(session, now, keepValid: presented);
      if (rotated != null) cookies.add(rotated);
    }

    await _touch(session, now, ip);

    return SessionResult(SessionOutcome.ok,
        user: validation.user, session: session, cookies: cookies);
  }

  /// Rotates the session secret, returning the cookie to set, or null if
  /// another concurrent request rotated first.
  ///
  /// [keepValid] is the secret hash that remains acceptable afterwards — the
  /// one the client is known to hold.
  Future<String?> _rotate(StoredSession session, DateTime now,
      {required String keepValid}) async {
    var secret = CryptoBox.randomToken();
    var ok = await store.rotateSession(
      session.id,
      expectedSecretHash: session.secretHash,
      newSecretHash: CryptoBox.hash(secret),
      prevSecretHash: keepValid,
      prevValidUntil: now.add(config.rotationGrace),
      rotatedAt: now,
    );
    // Losing the race is normal and is why the compare-and-set exists: a
    // burst of parallel requests must produce one new secret between them,
    // not a chain where each invalidates the last. The winner's response
    // carries the cookie; the others leave it alone.
    if (!ok) return null;
    return _cookie('${session.id}.$secret', maxAge: config.sessionTtl);
  }

  Future<void> _touch(StoredSession session, DateTime now, String ip) async {
    var movedAddress = ip.isNotEmpty && ip != session.ip;
    if (!movedAddress && now.difference(session.lastSeenAt) < _touchInterval) {
      return;
    }
    List<String>? history;
    if (movedAddress) {
      _log.info('session ${session.id} for ${session.userId} moved from '
          '${session.ip} to $ip');
      history = [...session.ipHistory, ip];
      if (history.length > _maxIpHistory) {
        history = history.sublist(history.length - _maxIpHistory);
      }
    }
    await store.touchSession(session.id, now,
        ip: movedAddress ? ip : null, ipHistory: history);
  }

  Future<SessionResult> _handleClone(
      StoredSession session, shelf.Request req, String reason) async {
    _log.warning('ending session ${session.id} for ${session.userId}: $reason '
        '(from ${clientIp(req, config.trustedProxies)}, '
        'originally ${session.ip})');
    await store.revokeSession(session.id, reason);
    if (config.reuseKillsAllSessions) {
      var ended = await store.revokeUserSessions(session.userId, reason);
      _log.warning('also ended $ended other session(s) for '
          '${session.userId}');
    }
    return SessionResult(SessionOutcome.cloned,
        cookies: [_deleteCookie()],
        message: 'This session was ended because it was used from more than '
            'one place. Please sign in again.');
  }

  /// Ends [session] at the user's request.
  Future<void> destroy(StoredSession session, {String reason = 'signed out'}) =>
      store.revokeSession(session.id, reason);

  String deleteCookie() => _deleteCookie();

  String _deleteCookie() => _cookie('', maxAge: Duration.zero);

  String _cookie(String value, {required Duration maxAge}) =>
      buildCookie(sessionCookieName, value,
          secure: _secureCookies, maxAge: maxAge);
}

import 'dart:convert';

import 'package:in_pub/src/auth/auth_config.dart';
import 'package:in_pub/src/auth/auth_store.dart';
import 'package:in_pub/src/auth/crypto_box.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:in_pub/src/auth/session.dart';
import 'package:in_pub/src/auth/user_validator.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'fake_provider.dart';
import 'memory_auth_store.dart';

/// These exercise the part of the session layer that decides whether a cookie
/// is being used by one client or two. The distinction is not obvious: a
/// perfectly honest browser can miss a `Set-Cookie` and come back on the old
/// secret, and calling that a theft would lock people out at random.
void main() {
  const userAgent = 'Mozilla/5.0 (test)';

  late MemoryAuthStore store;
  late FakeIdentityProvider provider;
  late SessionManager sessions;
  late AuthConfig config;

  AuthConfig makeConfig({
    Duration rotate = Duration.zero,
    Duration idle = const Duration(hours: 8),
    Duration ttl = const Duration(hours: 24),
    bool reuseKillsAll = false,
    List<String> allowedGroups = const [],
  }) =>
      AuthConfig(
        enabled: true,
        issuer: 'https://idp.example.org',
        clientId: 'in-pub',
        clientSecret: 'secret',
        publicUrl: Uri.parse('https://pub.example.org'),
        secret: utf8.encode('a-test-signing-secret-of-sufficient-length!!'),
        sessionRotate: rotate,
        sessionIdle: idle,
        sessionTtl: ttl,
        reuseKillsAllSessions: reuseKillsAll,
        allowedGroups: allowedGroups,
        // Keep revalidation out of the way; it has its own tests.
        revalidateInterval: const Duration(days: 365),
        revalidateHard: const Duration(days: 365),
      );

  void build(AuthConfig cfg) {
    config = cfg;
    store = MemoryAuthStore();
    provider = FakeIdentityProvider();
    var crypto = CryptoBox(config.secret);
    sessions = SessionManager(
      config: config,
      store: store,
      crypto: crypto,
      validator: UserValidator(
        config: config,
        store: store,
        provider: provider,
        crypto: crypto,
      ),
    );
  }

  setUp(() => build(makeConfig()));

  /// Pulls the cookie value out of a `Set-Cookie` header.
  String cookieValue(String setCookie) =>
      setCookie.split(';').first.split('=').sublist(1).join('=');

  shelf.Request request(String cookie, {String ua = userAgent}) =>
      shelf.Request('GET', Uri.parse('https://pub.example.org/packages'),
          headers: {
            'cookie': '$sessionCookieName=$cookie',
            'user-agent': ua,
          });

  Future<String> signIn() async {
    var user = const AuthenticatedUser(
        id: 'user-1',
        email: 'someone@example.org',
        displayName: 'Someone',
        groups: ['developers']);
    await store.upsertUser(user, validatedAt: DateTime.now());
    var setCookie = await sessions.create(
        shelf.Request('GET', Uri.parse('https://pub.example.org/'),
            headers: {'user-agent': userAgent}),
        user);
    return cookieValue(setCookie);
  }

  String sessionIdOf(String cookie) => cookie.split('.').first;

  group('a single well-behaved client', () {
    test('is accepted and gets a rotated secret', () async {
      var cookie = await signIn();

      var first = await sessions.resolve(request(cookie));
      expect(first.outcome, SessionOutcome.ok);
      expect(first.cookies, isNotEmpty, reason: 'the secret should rotate');

      var rotated = cookieValue(first.cookies.single);
      expect(rotated, isNot(cookie));

      var second = await sessions.resolve(request(rotated));
      expect(second.outcome, SessionOutcome.ok);
    });

    test('survives many requests in a row', () async {
      var cookie = await signIn();
      for (var i = 0; i < 20; i++) {
        var result = await sessions.resolve(request(cookie));
        expect(result.outcome, SessionOutcome.ok, reason: 'request $i');
        if (result.cookies.isNotEmpty) {
          cookie = cookieValue(result.cookies.single);
        }
      }
      var session = await store.getSession(sessionIdOf(cookie));
      expect(session!.isRevoked, isFalse);
    });
  });

  group('a session document that cannot be matched', () {
    /// Empties [id]'s stored secret, as a write that failed half way or a
    /// field lost in a migration leaves it — `StoredSession.fromJson`
    /// defaults a missing `secretHash` to the empty string.
    void corrupt(String id) {
      var stored = store.sessions[id]!;
      store.sessions[id] = StoredSession(
        id: stored.id,
        userId: stored.userId,
        secretHash: '',
        rotatedAt: stored.rotatedAt,
        uaHash: stored.uaHash,
        ip: stored.ip,
        createdAt: stored.createdAt,
        lastSeenAt: stored.lastSeenAt,
        expiresAt: stored.expiresAt,
      );
    }

    test('is not reported as a cloned cookie', () async {
      var cookie = await signIn();
      corrupt(sessionIdOf(cookie));

      var result = await sessions.resolve(request(cookie));

      expect(result.outcome, SessionOutcome.invalid,
          reason: 'nothing can match a row with no secret on it, so this is '
              'a broken document rather than a second holder of the cookie');
      expect(result.message, isNull,
          reason: 'telling the owner their session was used from more than '
              'one place would be an accusation over a database fault');
    });

    test('does not sign the owner out everywhere', () async {
      build(makeConfig(reuseKillsAll: true));
      var broken = await signIn();
      var other = await signIn();
      corrupt(sessionIdOf(broken));

      await sessions.resolve(request(broken));

      expect(store.sessions[sessionIdOf(broken)]!.isRevoked, isTrue,
          reason: 'the unusable row is ended rather than left to be counted '
              'on the administration screen and swept forever');
      expect(
          (await sessions.resolve(request(other))).outcome, SessionOutcome.ok,
          reason: 'one broken document must not end every session this '
              'person has open');
    });
  });

  group('a cloned cookie', () {
    test('is detected once the real client has moved on', () async {
      var stolen = await signIn();

      // The legitimate client makes a request and picks up a new secret.
      var legit = await sessions.resolve(request(stolen));
      var fresh = cookieValue(legit.cookies.single);

      // It uses the new secret, which retires the old one for good.
      var confirm = await sessions.resolve(request(fresh));
      expect(confirm.outcome, SessionOutcome.ok);
      if (confirm.cookies.isNotEmpty) {
        fresh = cookieValue(confirm.cookies.single);
        await sessions.resolve(request(fresh));
      }

      // Now the copy shows up on the secret nobody should still be holding.
      var thief = await sessions.resolve(request(stolen));
      expect(thief.outcome, SessionOutcome.cloned);

      var session = await store.getSession(sessionIdOf(stolen));
      expect(session!.isRevoked, isTrue);
      expect(session.revokedReason, isNotNull);
    });

    test('ends the session for the real client too', () async {
      var stolen = await signIn();
      var legit = await sessions.resolve(request(stolen));
      var fresh = cookieValue(legit.cookies.single);
      await sessions.resolve(request(fresh));

      await sessions.resolve(request(stolen));

      var afterwards = await sessions.resolve(request(fresh));
      expect(afterwards.outcome, SessionOutcome.revoked,
          reason: 'the session is gone for everyone, which is what makes the '
              'theft visible to its owner');
    });

    test('optionally takes every other session of that user with it', () async {
      build(makeConfig(reuseKillsAll: true));
      var stolen = await signIn();
      var other = await signIn();

      var legit = await sessions.resolve(request(stolen));
      var fresh = cookieValue(legit.cookies.single);
      await sessions.resolve(request(fresh));
      await sessions.resolve(request(stolen));

      var otherSession = await store.getSession(sessionIdOf(other));
      expect(otherSession!.isRevoked, isTrue);
    });

    test(
        'presented by another client application, the session ends — but '
        'not as a theft', () async {
      // The cookie is refused and the session revoked either way, so a
      // thief is stopped. What changed is the framing: a browser that
      // updates itself overnight changes its `User-Agent`, and reporting
      // that as a stolen cookie showed its owner an alarming message and,
      // with `--auth-reuse-kills-all`, killed their sessions everywhere.
      var cookie = await signIn();
      var result = await sessions
          .resolve(request(cookie, ua: 'curl/8.0 (not a browser)'));

      expect(result.isAuthenticated, isFalse);
      expect(result.outcome, SessionOutcome.invalid);
      expect(store.sessions.values.single.isRevoked, isTrue,
          reason: 'the cookie must stop working for whoever presented it');
    });
  });

  group('a client that missed a cookie update', () {
    test('is not mistaken for a clone', () async {
      var cookie = await signIn();

      // The response carrying the new secret never reaches the client, so it
      // keeps using the old one.
      await sessions.resolve(request(cookie));

      var retry = await sessions.resolve(request(cookie));
      expect(retry.outcome, SessionOutcome.ok);
      expect(retry.cookies, isNotEmpty,
          reason: 'the client must be handed a secret it can actually use');

      var session = await store.getSession(sessionIdOf(cookie));
      expect(session!.isRevoked, isFalse);
    });

    test('recovers: the re-issued secret works', () async {
      var cookie = await signIn();
      await sessions.resolve(request(cookie));
      var retry = await sessions.resolve(request(cookie));
      var recovered = cookieValue(retry.cookies.single);

      var result = await sessions.resolve(request(recovered));
      expect(result.outcome, SessionOutcome.ok);
    });

    test('a burst of parallel requests on one secret is not a clone', () async {
      var cookie = await signIn();

      // What the web UI actually does: several requests leave together, all
      // carrying the same cookie, and only one of them can win the rotation.
      var results = await Future.wait([
        for (var i = 0; i < 6; i++) sessions.resolve(request(cookie)),
      ]);

      expect(results.map((r) => r.outcome), everyElement(SessionOutcome.ok));
      var session = await store.getSession(sessionIdOf(cookie));
      expect(session!.isRevoked, isFalse);
    });
  });

  group('rejecting cookies', () {
    test('an unknown session id is simply not signed in', () async {
      var result = await sessions.resolve(request('nosuch.secret'));
      expect(result.outcome, SessionOutcome.invalid);
      expect(result.cookies.single, contains('Max-Age=0'));
    });

    test('a malformed cookie is not signed in', () async {
      var result = await sessions.resolve(request('garbage'));
      expect(result.outcome, SessionOutcome.invalid);
    });

    test('a revoked session reports why', () async {
      var cookie = await signIn();
      await store.revokeSession(
          sessionIdOf(cookie), 'ended by an administrator');

      var result = await sessions.resolve(request(cookie));
      expect(result.outcome, SessionOutcome.revoked);
      expect(result.message, 'ended by an administrator');
    });

    test('an idle session expires', () async {
      build(makeConfig(idle: const Duration(seconds: 1)));
      var cookie = await signIn();
      var id = sessionIdOf(cookie);
      var session = store.sessions[id]!;
      // Rewind the clock on the record rather than waiting for it.
      store.sessions[id] = StoredSession(
        id: session.id,
        userId: session.userId,
        secretHash: session.secretHash,
        rotatedAt: session.rotatedAt,
        uaHash: session.uaHash,
        ip: session.ip,
        createdAt: session.createdAt,
        lastSeenAt: DateTime.now().subtract(const Duration(minutes: 5)),
        expiresAt: session.expiresAt,
      );

      var result = await sessions.resolve(request(cookie));
      expect(result.outcome, SessionOutcome.expired);
    });

    test('a blocked user is denied, with the reason', () async {
      var cookie = await signIn();
      await store.setUserStatus('user-1', UserStatus.blockedLocal,
          reason: 'blocked by an administrator');

      var result = await sessions.resolve(request(cookie));
      expect(result.outcome, SessionOutcome.denied);
      expect(result.message, 'blocked by an administrator');
    });

    test('no cookie at all is just an anonymous visitor', () async {
      var result = await sessions.resolve(
          shelf.Request('GET', Uri.parse('https://pub.example.org/packages')));
      expect(result.outcome, SessionOutcome.absent);
      expect(result.cookies, isEmpty);
    });
  });

  group('tightening the allowed groups', () {
    test('ends the session rather than merely refusing it', () async {
      // Only this server's configuration changed, so the account is still
      // active and the provider still vouches for it — nothing else would
      // ever clear the row. Left alone it stays "live" for the whole idle
      // window: counted on the administration screen, offered an End button,
      // and re-checked against the provider every few minutes, all for
      // somebody who cannot make a single request.
      var cookie = await signIn();
      build(makeConfig(allowedGroups: ['pubusers']));

      // Rebuilding wiped the store, so put the same session back.
      var user = const AuthenticatedUser(
          id: 'user-1',
          email: 'someone@example.org',
          displayName: 'Someone',
          groups: ['developers']);
      await store.upsertUser(user, validatedAt: DateTime.now());
      var setCookie = await sessions.create(
          shelf.Request('GET', Uri.parse('https://pub.example.org/'),
              headers: {'user-agent': userAgent}),
          user);
      cookie = cookieValue(setCookie);

      var result = await sessions.resolve(request(cookie));
      expect(result.isAuthenticated, isFalse);
      expect(store.sessions.values.single.isRevoked, isTrue,
          reason: 'the row has to stop counting as live');
    });
  });

  group('a cookie presented by a different client', () {
    test('ends the session without calling it a theft', () async {
      // A browser that updates itself overnight changes its `User-Agent`.
      // Reporting that as a stolen cookie showed the owner an alarming
      // message and, with `--auth-reuse-kills-all`, killed their sessions
      // everywhere else too.
      var cookie = await signIn();

      var result =
          await sessions.resolve(request(cookie, ua: 'Mozilla/5.0 (newer)'));

      expect(result.isAuthenticated, isFalse);
      expect(result.outcome, SessionOutcome.invalid);
      expect(store.sessions.values.single.isRevoked, isTrue);
    });
  });
}

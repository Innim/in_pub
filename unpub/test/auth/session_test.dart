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

    test('is detected when the cookie moves to another client application',
        () async {
      var cookie = await signIn();
      var result = await sessions
          .resolve(request(cookie, ua: 'curl/8.0 (not a browser)'));
      expect(result.outcome, SessionOutcome.cloned);
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
}

import 'dart:convert';

import 'package:in_pub/src/auth/auth_config.dart';
import 'package:in_pub/src/auth/auth_store.dart';
import 'package:in_pub/src/auth/crypto_box.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:in_pub/src/auth/user_validator.dart';
import 'package:test/test.dart';

import 'fake_provider.dart';
import 'memory_auth_store.dart';

/// The revalidator is what makes disabling an account on Nextcloud take
/// effect here without anyone repeating the action. Its two failure modes
/// pull in opposite directions, and both are tested: missing a real
/// revocation leaves a closed repository open, while treating an unreachable
/// provider as a revocation logs out the entire company during an outage.
void main() {
  late MemoryAuthStore store;
  late FakeIdentityProvider provider;
  late CryptoBox crypto;
  late UserValidator validator;
  late AuthConfig config;

  AuthConfig makeConfig({
    List<String> allowedGroups = const [],
    Duration interval = const Duration(minutes: 5),
    Duration hard = const Duration(minutes: 30),
    int maxFailures = 3,
  }) =>
      AuthConfig(
        enabled: true,
        issuer: 'https://idp.example.org',
        clientId: 'in-pub',
        clientSecret: 'secret',
        publicUrl: Uri.parse('https://pub.example.org'),
        secret: utf8.encode('a-test-signing-secret-of-sufficient-length!!'),
        allowedGroups: allowedGroups,
        revalidateInterval: interval,
        revalidateHard: hard,
        revalidateMaxFailures: maxFailures,
      );

  void build(AuthConfig cfg) {
    config = cfg;
    store = MemoryAuthStore();
    provider = FakeIdentityProvider();
    crypto = CryptoBox(config.secret);
    validator = UserValidator(
        config: config, store: store, provider: provider, crypto: crypto);
  }

  setUp(() => build(makeConfig()));

  /// Puts a user in the store whose last confirmation is [age] old, holding a
  /// live session.
  Future<StoredUser> seedUser({
    required Duration age,
    List<String> groups = const ['developers'],
    int failures = 0,
  }) async {
    var now = DateTime.now();
    await store.upsertUser(
      AuthenticatedUser(
          id: 'user-1',
          email: 'someone@example.org',
          displayName: 'Someone',
          groups: groups),
      refreshTokenEnc: crypto.encrypt('refresh-1'),
      validatedAt: now.subtract(age),
    );
    if (failures > 0) {
      await store.recordValidation('user-1', failures: failures);
    }
    await store.createSession(StoredSession(
      id: 'session-1',
      userId: 'user-1',
      secretHash: 'hash',
      rotatedAt: now,
      uaHash: 'ua',
      ip: '10.0.0.1',
      createdAt: now,
      lastSeenAt: now,
      expiresAt: now.add(const Duration(hours: 24)),
    ));
    return (await store.getUser('user-1'))!;
  }

  group('a confirmation that is still fresh', () {
    test('is used as is, without calling the provider', () async {
      var user = await seedUser(age: const Duration(minutes: 1));
      var result = await validator.ensureValid(user);

      expect(result.isAllowed, isTrue);
      expect(provider.refreshCalls, 0);
    });
  });

  group('a stale confirmation', () {
    test('is refreshed in the background without delaying the request',
        () async {
      var user = await seedUser(age: const Duration(minutes: 10));
      var result = await validator.ensureValid(user);

      // Served immediately from what we already knew.
      expect(result.isAllowed, isTrue);

      // ...and brought up to date behind it.
      await Future<void>.delayed(Duration.zero);
      expect(provider.refreshCalls, 1);
      expect(provider.userInfoCalls, 1);
    });

    test('reads the profile as well as refreshing the grant', () async {
      // Refreshing alone proves nothing about the account: whether a
      // disabled user's refresh token still works is up to the provider.
      // Reading the profile is the check that cannot pass for one.
      var user = await seedUser(age: const Duration(hours: 1));
      await validator.ensureValid(user);
      expect(provider.userInfoCalls, 1);
    });

    test('stores the rotated refresh token', () async {
      var user = await seedUser(age: const Duration(hours: 1));
      provider.nextRefreshToken = 'refresh-rotated';
      await validator.ensureValid(user);

      var stored = await store.getUser('user-1');
      expect(crypto.decrypt(stored!.refreshTokenEnc!), 'refresh-rotated');
    });
  });

  group('an account the provider no longer vouches for', () {
    test('is blocked when the grant is rejected', () async {
      var user = await seedUser(age: const Duration(hours: 1));
      provider.refreshError = IdentityRevokedException('invalid_grant');

      var result = await validator.ensureValid(user);
      expect(result.isAllowed, isFalse);

      var stored = await store.getUser('user-1');
      expect(stored!.status, UserStatus.blockedUpstream);
    });

    test('is blocked when the profile can no longer be read', () async {
      // This is the disabled-Nextcloud-account case.
      var user = await seedUser(age: const Duration(hours: 1));
      provider.userInfoError = IdentityRevokedException('HTTP 401');

      var result = await validator.ensureValid(user);
      expect(result.isAllowed, isFalse);
      expect(
          (await store.getUser('user-1'))!.status, UserStatus.blockedUpstream);
    });

    test('loses every session, not just the current one', () async {
      var user = await seedUser(age: const Duration(hours: 1));
      provider.refreshError = IdentityRevokedException('invalid_grant');

      await validator.ensureValid(user);

      var session = await store.getSession('session-1');
      expect(session!.isRevoked, isTrue);
    });

    test('is blocked after being removed from an allowed group', () async {
      build(makeConfig(allowedGroups: ['developers']));
      var user = await seedUser(age: const Duration(hours: 1));
      // Still a valid account, just no longer entitled to this repository.
      provider.profile = const AuthenticatedUser(
          id: 'user-1',
          email: 'someone@example.org',
          displayName: 'Someone',
          groups: ['everyone']);

      var result = await validator.ensureValid(user);
      expect(result.isAllowed, isFalse);
      expect(
          (await store.getUser('user-1'))!.status, UserStatus.blockedUpstream);
    });

    test('cannot be verified at all without a refresh token', () async {
      var now = DateTime.now();
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-2', email: '', displayName: 'No Token'),
          validatedAt: now.subtract(const Duration(hours: 1)));

      var result =
          await validator.ensureValid((await store.getUser('user-2'))!);
      expect(result.isAllowed, isFalse);
    });
  });

  group('a provider that cannot be reached', () {
    test('does not block anyone', () async {
      var user = await seedUser(age: const Duration(minutes: 10));
      provider.refreshError =
          IdentityUnavailableException('connection refused');

      var result = await validator.ensureValid(user);
      expect(result.isAllowed, isTrue);

      await Future<void>.delayed(Duration.zero);
      expect((await store.getUser('user-1'))!.status, UserStatus.active,
          reason: 'an outage is not a revocation');
    });

    test('counts the failure', () async {
      var user = await seedUser(age: const Duration(hours: 1));
      provider.refreshError = IdentityUnavailableException('timeout');

      await validator.ensureValid(user);
      expect((await store.getUser('user-1'))!.validationFailures, 1);
    });

    test('stops serving a user who has been unverifiable for too long',
        () async {
      var user = await seedUser(age: const Duration(hours: 2));
      provider.refreshError = IdentityUnavailableException('timeout');

      var result = await validator.ensureValid(user);
      expect(result.isAllowed, isFalse,
          reason: 'otherwise an outage indefinitely extends access for '
              'accounts that may already have been revoked');
      expect((await store.getUser('user-1'))!.status, UserStatus.active,
          reason: 'refused for now, but not blocked: they come back when the '
              'provider does');
    });

    test('stops serving after too many consecutive failures', () async {
      build(makeConfig(maxFailures: 2));
      var user = await seedUser(age: const Duration(minutes: 10), failures: 2);
      provider.refreshError = IdentityUnavailableException('timeout');

      var result = await validator.ensureValid(user);
      expect(result.isAllowed, isFalse);
    });

    test('lets a recovered user straight back in', () async {
      var user = await seedUser(age: const Duration(hours: 2), failures: 5);

      var result = await validator.ensureValid(user);
      expect(result.isAllowed, isTrue);
      expect((await store.getUser('user-1'))!.validationFailures, 0);
    });
  });

  group('one check at a time per user', () {
    test('concurrent requests share a single refresh', () async {
      // Refresh tokens rotate: two refreshes racing on the same token means
      // one of them is rejected and the stored token points at a retired
      // grant, logging out a valid user.
      var user = await seedUser(age: const Duration(hours: 1));

      await Future.wait([
        for (var i = 0; i < 5; i++) validator.ensureValid(user),
      ]);

      expect(provider.refreshCalls, 1);
    });
  });

  group('the background sweep', () {
    test('re-checks users holding live sessions', () async {
      await seedUser(age: const Duration(hours: 1));
      await validator.sweep();
      expect(provider.refreshCalls, 1);
    });

    test('leaves freshly confirmed users alone', () async {
      await seedUser(age: const Duration(seconds: 5));
      await validator.sweep();
      expect(provider.refreshCalls, 0);
    });

    test('catches a revocation without the user making a request', () async {
      await seedUser(age: const Duration(hours: 1));
      provider.userInfoError = IdentityRevokedException('HTTP 401');

      await validator.sweep();

      expect(
          (await store.getUser('user-1'))!.status, UserStatus.blockedUpstream);
      expect((await store.getSession('session-1'))!.isRevoked, isTrue);
    });

    test('clears out sessions that have aged out', () async {
      var now = DateTime.now();
      await store.createSession(StoredSession(
        id: 'old',
        userId: 'user-9',
        secretHash: 'hash',
        rotatedAt: now,
        uaHash: 'ua',
        ip: '',
        createdAt: now.subtract(const Duration(days: 3)),
        lastSeenAt: now.subtract(const Duration(days: 3)),
        expiresAt: now.subtract(const Duration(days: 2)),
      ));

      await validator.sweep();
      expect(await store.getSession('old'), isNull);
    });
  });
}

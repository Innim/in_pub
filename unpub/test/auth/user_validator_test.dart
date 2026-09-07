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

  void build(AuthConfig cfg, {MemoryAuthStore? withStore}) {
    config = cfg;
    store = withStore ?? MemoryAuthStore();
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

  group('a provider that stops reporting an address', () {
    test('does not clear the one already on record', () async {
      // `/userinfo` answers with an empty `email` when the claim is missing —
      // a scope dropped on the client, a directory entry with the field
      // cleared. Written through, it takes the account out of every address
      // lookup: `findUsersByEmail` then answers nothing for it, so a
      // *blocked* publisher's legacy Google credential reads as "maps to
      // nobody here" and is accepted as provisional. It also collapses every
      // such account onto the `uploader: ''` identity the token-issue guard
      // exists to keep empty.
      var user = await seedUser(age: const Duration(hours: 1));
      provider.profile = const AuthenticatedUser(
          id: 'user-1',
          email: '',
          displayName: 'Someone',
          groups: ['developers']);

      await validator.ensureValid(user);

      var stored = await store.getUser('user-1');
      expect(stored!.email, 'someone@example.org');
      expect((await store.findUsersByEmail('someone@example.org')).single.id,
          'user-1',
          reason: 'the block on this account has to keep being findable by '
              'address');
    });

    test('an address that really did change is still written', () async {
      // The guard is about nothing, not about difference: a rename must
      // still land, or the record would disagree with the provider forever.
      var user = await seedUser(age: const Duration(hours: 1));
      provider.profile = const AuthenticatedUser(
          id: 'user-1',
          email: 'someone.else@example.org',
          displayName: 'Someone Else',
          groups: ['developers']);

      await validator.ensureValid(user);

      expect(
          (await store.getUser('user-1'))!.email, 'someone.else@example.org');
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

    test('is refused for a credential without blocking or ending sessions',
        () async {
      // The revocation is real and the credential is refused for it — but a
      // `dart pub publish` from CI is no place to end the owner's browser
      // sessions: they did not run it, may not be at a keyboard, and cannot
      // act on the sign-in prompt that would follow. The evidence is softer
      // than it looks, too: `invalid_grant` is also what a refresh token
      // that was merely *spent* earns, which is what a credential check
      // racing a rotation produces.
      var user = await seedUser(age: const Duration(hours: 1));
      provider.refreshError = IdentityRevokedException('invalid_grant');

      var result = await validator.ensureValid(user, interactive: false);

      expect(result.isAllowed, isFalse);
      expect(result.reason, contains('no longer authorised'));
      expect((await store.getUser('user-1'))!.status, UserStatus.active,
          reason: 'the block belongs to the next interactive check, not to a '
              'job the account owner does not control');
      expect((await store.getSession('session-1'))!.isRevoked, isFalse);

      // And it stays refused: nothing was written that would soften the
      // answer, so the grace the "could not confirm" branch extends to an
      // operator's lost signing key is not handed to a revoked account.
      var again = await validator.ensureValid((await store.getUser('user-1'))!,
          interactive: false);
      expect(again.isAllowed, isFalse);
    });

    test('is refused for a credential over the groups, with the same restraint',
        () async {
      // The starker half: whether the groups still allow this account is a
      // decision taken here, from `--auth-allowed-groups`. Editing that flag
      // used to sign every affected person out of every browser as soon as
      // any CI job of theirs published.
      build(makeConfig(allowedGroups: ['developers']));
      var user = await seedUser(age: const Duration(hours: 1));
      provider.profile = const AuthenticatedUser(
          id: 'user-1',
          email: 'someone@example.org',
          displayName: 'Someone',
          groups: ['everyone']);

      var result = await validator.ensureValid(user, interactive: false);

      expect(result.isAllowed, isFalse);
      expect(result.reason, contains('group'));
      expect((await store.getUser('user-1'))!.status, UserStatus.active);
      expect((await store.getSession('session-1'))!.isRevoked, isFalse);
    });

    test('is refused on the next credential check inside the soft window too',
        () async {
      // The soft window answers from the stored record and revalidates
      // behind the request, so the check that meets the refusal is the one
      // whose answer nobody is waiting for. Written nowhere and remembered
      // nowhere, that refusal was rediscovered and thrown away on every
      // request: the record it declined to touch still looked exactly as
      // fresh, the same branch was taken again, and the revoked credential
      // went on publishing until `--auth-revalidate-hard` — hours, by
      // default.
      var user = await seedUser(age: const Duration(minutes: 10));
      provider.refreshError = IdentityRevokedException('invalid_grant');

      var first = await validator.ensureValid(user, interactive: false);
      expect(first.isAllowed, isTrue,
          reason: 'the soft window answers from the record, as it always has');
      await settle();

      var second = await validator.ensureValid((await store.getUser('user-1'))!,
          interactive: false);

      expect(second.isAllowed, isFalse);
      expect(second.reason, contains('no longer authorised'));
      expect(provider.refreshCalls, 1,
          reason: 'the answer is remembered, not asked for a second time');
      expect((await store.getUser('user-1'))!.status, UserStatus.active,
          reason: 'still nothing written onto somebody else\'s account');
      expect((await store.getSession('session-1'))!.isRevoked, isFalse);
      expect((await store.getUser('user-1'))!.validationFailures, 0,
          reason: 'a refusal is not an unreachable provider, and must not '
              'spend the budget the unconfirmable are served on');
    });

    test('and an unreachable provider does not hand the refusal back',
        () async {
      // The refusal is remembered rather than written, so what retires that
      // memory is load-bearing. Versioning it on `updatedAt` — which every
      // store write moves — meant a recorded *failure* retired it: the
      // provider goes unreachable, an interactive check counts the attempt,
      // and the next credential request finds an active record inside the
      // soft window and is served again. An outage is not evidence that a
      // revoked account has been reinstated.
      var user = await seedUser(age: const Duration(minutes: 10));
      provider.refreshError = IdentityRevokedException('invalid_grant');
      await validator.ensureValid(user, interactive: false);
      await settle();

      // The provider stops answering, and something interactive counts it.
      provider.refreshError = IdentityUnavailableException('timeout');
      await validator.sweep();
      var after = (await store.getUser('user-1'))!;
      expect(after.validationFailures, 1,
          reason: 'the failure was recorded, which is what used to clear the '
              'refusal');
      expect(after.status, UserStatus.active);

      var next = await validator.ensureValid(after, interactive: false);

      expect(next.isAllowed, isFalse);
      expect(next.reason, contains('no longer authorised'));
    });

    test('but an administrator restoring access does hand it back', () async {
      // The other half of the same rule, and the reason the note is retired
      // by anything at all: `lastValidatedAt` backdated to the epoch is what
      // an unblock writes to force a fresh check, and a note that outlived
      // it would leave CI refused until somebody signed in from a browser.
      var user = await seedUser(age: const Duration(hours: 1));
      provider.refreshError = IdentityRevokedException('invalid_grant');
      expect((await validator.ensureValid(user, interactive: false)).isAllowed,
          isFalse);

      // What the administration screen does, and the provider relents.
      await store.setUserStatus('user-1', UserStatus.active);
      await store.recordValidation('user-1',
          validatedAt: DateTime.fromMillisecondsSinceEpoch(0), failures: 0);
      provider.refreshError = null;

      var next = await validator.ensureValid((await store.getUser('user-1'))!,
          interactive: false);

      expect(next.isAllowed, isTrue);
    });

    test('but a browser request asks for itself rather than taking that note',
        () async {
      // The note is an unverified answer, possibly from a check that raced a
      // token rotation — `invalid_grant` is what a spent refresh token earns
      // too. Refusing somebody their own UI on it, with no block recorded to
      // explain it and no sign-in offered, is the write-free version of the
      // harm this path exists to avoid. And once the interactive check says
      // yes, the note is gone.
      var user = await seedUser(age: const Duration(hours: 1));
      provider.refreshError = IdentityRevokedException('invalid_grant');
      await validator.ensureValid(user, interactive: false);

      provider.refreshError = null;
      var browser =
          await validator.ensureValid((await store.getUser('user-1'))!);

      expect(browser.isAllowed, isTrue);
      expect(provider.refreshCalls, 2, reason: 'it did the round trip itself');
      expect(
          (await validator.ensureValid((await store.getUser('user-1'))!,
                  interactive: false))
              .isAllowed,
          isTrue,
          reason: 'a confirmation retires the refusal remembered for it');
    });

    test(
        'and the block a credential check left undone lands on the next '
        'browser request', () async {
      // Deferred, not dropped. Somebody who can be told is told.
      var user = await seedUser(age: const Duration(hours: 1));
      provider.userInfoError = IdentityRevokedException('HTTP 401');

      await validator.ensureValid(user, interactive: false);
      var browser =
          await validator.ensureValid((await store.getUser('user-1'))!);

      expect(browser.isAllowed, isFalse);
      expect(
          (await store.getUser('user-1'))!.status, UserStatus.blockedUpstream);
      expect((await store.getSession('session-1'))!.isRevoked, isTrue);
    });

    test('or on the sweep, which is what reaches the sessions unprompted',
        () async {
      // The other half of the deferral, and the reason it is bounded: the
      // sweep walks exactly the accounts holding live sessions — the ones
      // with something to lose — every `--auth-revalidate-interval`.
      var user = await seedUser(age: const Duration(hours: 1));
      provider.userInfoError = IdentityRevokedException('HTTP 401');

      await validator.ensureValid(user, interactive: false);
      expect((await store.getSession('session-1'))!.isRevoked, isFalse);

      await validator.sweep();

      expect(
          (await store.getUser('user-1'))!.status, UserStatus.blockedUpstream);
      expect((await store.getSession('session-1'))!.isRevoked, isTrue);
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

    test('is asked to sign in again, not blocked, when nothing can check it',
        () async {
      // Blocking would say the provider revoked them, which is untrue, shows
      // that way to an administrator, and leaves no way back. An account
      // blocked by an older build — which discarded the refresh token —
      // arrives here on the first request after being unblocked.
      var now = DateTime.now();
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-3', email: 'x@example.org', displayName: 'No Token'),
          validatedAt: now.subtract(const Duration(hours: 2)));
      await store.createSession(StoredSession(
        id: 'session-3',
        userId: 'user-3',
        secretHash: 'hash',
        rotatedAt: now,
        uaHash: 'ua',
        ip: '10.0.0.1',
        createdAt: now,
        lastSeenAt: now,
        expiresAt: now.add(const Duration(hours: 24)),
      ));

      var result =
          await validator.ensureValid((await store.getUser('user-3'))!);

      expect(result.isAllowed, isFalse);
      expect(result.reason, contains('sign in again'));
      expect((await store.getUser('user-3'))!.status, UserStatus.needsSignIn,
          reason: 'not a block: nobody withdrew this access, and the way back '
              'is a sign-in');
      expect((await store.getSession('session-3'))!.isRevoked, isTrue,
          reason: 'signing in again is what restores the ability to check');
      expect(result.recoverable, isTrue,
          reason: 'the whole point of this state is that a sign-in fixes it; '
              'reported as a denial it lands on a page that says an '
              'administrator withdrew access, with no link to the one thing '
              'that would help');
    });

    test(
        'but a credential is still served when the stored token will not '
        'decrypt', () async {
      // The other cause of "cannot confirm", and the one the deadline must
      // not act on. A lost or rotated `INPUB_AUTH_SESSION_SECRET` leaves
      // every stored refresh token undecipherable: the record is intact, the
      // account is fine, and the fault is the operator's. Refusing over it
      // stopped every CI job in the deployment at once, which is why this
      // path exists — and it has to survive the deadline now being enforced
      // for credentials, because the two causes are not the same evidence.
      await seedUser(age: const Duration(hours: 2));
      var stranger =
          CryptoBox(utf8.encode('another-signing-secret-of-sufficient-len!!'));
      await store.recordValidation('user-1',
          refreshTokenEnc: stranger.encrypt('refresh-1'));

      var result = await validator.ensureValid((await store.getUser('user-1'))!,
          interactive: false);

      expect(result.isAllowed, isTrue);
      expect(provider.refreshCalls, 0,
          reason: 'there was nothing to ask the provider with');
      expect((await store.getUser('user-1'))!.status, UserStatus.active,
          reason: 'nobody withdrew this access and no CI job can act on a '
              'prompt, so the status and the sessions are left as they were');
      expect((await store.getSession('session-1'))!.isRevoked, isFalse);
      expect((await store.getUser('user-1'))!.validationFailures, 1,
          reason: 'the attempt itself is recorded — it is the only thing '
              'that keeps this from being served forever');
    });

    test('but the grace it gets is a few requests, not forever', () async {
      // What this branch used to do was write nothing whatsoever, and that
      // was the defect: with neither the timestamp nor the failure count
      // moving, every later request took the same branch, the provider was
      // never asked about the account again, and one disabled upstream kept
      // publishing and reading private packages for as long as the server
      // ran. The operator's mistake is still not held against the account —
      // no block, no prompt, no sessions ended — but "we cannot confirm
      // this" is bounded by the same budget an unreachable provider spends.
      build(makeConfig(maxFailures: 3));
      await seedUser(age: const Duration(hours: 2));
      var stranger =
          CryptoBox(utf8.encode('another-signing-secret-of-sufficient-len!!'));
      await store.recordValidation('user-1',
          refreshTokenEnc: stranger.encrypt('refresh-1'));

      Future<ValidationResult> check() async => validator
          .ensureValid((await store.getUser('user-1'))!, interactive: false);

      expect((await check()).isAllowed, isTrue,
          reason: 'a lost signing secret puts every account here at once, so '
              'refusing on the first request stops all of CI');
      expect((await check()).isAllowed, isTrue);
      expect((await check()).isAllowed, isFalse,
          reason: 'the budget is spent; the account cannot be confirmed and '
              'is not served on trust indefinitely');

      // Still not a withdrawal, and still nothing a CI job did to somebody
      // else's browser: a sign-in is what restores the ability to check.
      expect((await store.getUser('user-1'))!.status, UserStatus.active);
      expect((await store.getSession('session-1'))!.isRevoked, isFalse);
      expect((await check()).reason, contains('sign in'));

      expect((await store.getUser('user-1'))!.validationFailures, 3,
          reason: 'the count stops at the budget: past it every request is '
              'refused anyway, and counting on would buy a database write '
              'per refused request and nothing else');
    });

    test('and a credential is refused outright when the record is gone',
        () async {
      // Admin cleanup, a half-finished migration, a dropped collection. The
      // guard here used to read "no record, so nothing says this account is
      // blocked" and serve the credential on the stale copy the caller still
      // held in memory — the one credential state that no deletion could
      // ever end.
      var user = await seedUser(age: const Duration(hours: 2));
      var stranger =
          CryptoBox(utf8.encode('another-signing-secret-of-sufficient-len!!'));
      await store.recordValidation('user-1',
          refreshTokenEnc: stranger.encrypt('refresh-1'));
      var stale = (await store.getUser('user-1'))!;
      store.users.remove(user.id);

      var result = await validator.ensureValid(stale, interactive: false);

      expect(result.isAllowed, isFalse,
          reason: 'deletion is the plainest withdrawal of access there is');
    });

    test('a real block is not recoverable by signing in', () async {
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-4', email: 'blocked@example.org', displayName: 'B'),
          validatedAt: DateTime.now());
      await store.setUserStatus('user-4', UserStatus.blockedLocal,
          reason: 'withdrawn by an administrator');

      var result =
          await validator.ensureValid((await store.getUser('user-4'))!);

      expect(result.isAllowed, isFalse);
      expect(result.recoverable, isFalse);
    });

    test('and does not repeat itself on every later request', () async {
      // Leaving the state unrecorded meant the check ran again on each
      // request — a database write per request, and a token used by CI
      // ending the owner's browser sessions over and over.
      var now = DateTime.now();
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-4', email: 'y@example.org', displayName: 'No Token'),
          validatedAt: now.subtract(const Duration(hours: 2)));

      var user = (await store.getUser('user-4'))!;
      await validator.ensureValid(user);
      var afterFirst = (await store.getUser('user-4'))!;

      // What a later request sees: the recorded state, refused outright.
      var again = await validator.ensureValid(afterFirst);
      expect(again.isAllowed, isFalse);
      expect(again.reason, contains('sign in again'));
      expect(provider.refreshCalls, 0,
          reason: 'nothing to refresh with, and no reason to keep trying');
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

    test('stops serving a bearer credential too, once the deadline passes',
        () async {
      // `--auth-revalidate-hard` says it "bounds how long a provider outage
      // can be used to keep a revoked account alive". Credentials used to be
      // waved through this check on the grounds that a CI job cannot act on a
      // prompt — but this is not a prompt, and with `--auth-protect-pub-api`
      // a token is the only credential there is, so the bound the flag
      // promises applied to nothing that mattered. An account disabled during
      // the outage kept publishing for as long as the outage lasted.
      var user = await seedUser(age: const Duration(hours: 2));
      provider.refreshError = IdentityUnavailableException('timeout');

      var result = await validator.ensureValid(user, interactive: false);

      expect(result.isAllowed, isFalse);
      expect((await store.getUser('user-1'))!.status, UserStatus.active,
          reason: 'refused for now, not blocked: a check must not write a '
              'withdrawal onto an account it merely could not reach');
      expect((await store.getSession('session-1'))!.isRevoked, isFalse,
          reason: 'a publish from CI has no business ending the owner\'s '
              'browser sessions');
    });

    test('and after too many consecutive failures, credential or not',
        () async {
      build(makeConfig(maxFailures: 2));
      var user = await seedUser(age: const Duration(minutes: 10), failures: 2);
      provider.refreshError = IdentityUnavailableException('timeout');

      expect((await validator.ensureValid(user, interactive: false)).isAllowed,
          isFalse);
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

    test('a credential check may share a browser request\'s answer', () async {
      // This direction is safe: the interactive check is the more thorough
      // of the two, so its answer holds for a credential as well, and the
      // point of sharing — one refresh per user — is preserved.
      var user = await seedUser(age: const Duration(hours: 1));

      var browser = validator.ensureValid(user);
      var credential = validator.ensureValid(user, interactive: false);
      var results = await Future.wait([browser, credential]);

      expect(results.every((r) => r.isAllowed), isTrue);
      expect(provider.refreshCalls, 1);
    });

    test('but a browser request never takes a credential check\'s answer',
        () async {
      // A credential check deliberately leaves an account it cannot confirm
      // alone: nobody at a CI job can act on a prompt, and marking the record
      // would sign its owner out of every browser they had open. Joining that
      // check handed the browser the same "could not confirm", which
      // `ensureValid` turns into the access-withdrawn page — no sign-in link,
      // nothing recorded, and the same page again on the next load, forever.
      var now = DateTime.now();
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-5', email: 'z@example.org', displayName: 'No Token'),
          validatedAt: now.subtract(const Duration(hours: 2)));
      await store.createSession(StoredSession(
        id: 'session-5',
        userId: 'user-5',
        secretHash: 'hash',
        rotatedAt: now,
        uaHash: 'ua',
        ip: '10.0.0.1',
        createdAt: now,
        lastSeenAt: now,
        expiresAt: now.add(const Duration(hours: 24)),
      ));
      var user = (await store.getUser('user-5'))!;

      // The publish arrives first; the person's browser lands mid-flight.
      var credential = validator.ensureValid(user, interactive: false);
      var browser = validator.ensureValid(user);
      var results = await Future.wait([credential, browser]);

      expect(results[1].isAllowed, isFalse);
      expect(results[1].reason, contains('sign in again'));
      expect(results[1].recoverable, isTrue,
          reason: 'reported as a plain denial it lands on a page that says an '
              'administrator withdrew access, with no link to the one thing '
              'that would help');
      expect((await store.getUser('user-5'))!.status, UserStatus.needsSignIn,
          reason: 'the browser request is the one that may record this, and '
              'until it does every later page load repeats the refusal');
    });
  });

  group('the service-token clash warning', () {
    test('is not asked about an address that is not one', () async {
      // It runs on every first sign-in, and a provider that sends no `email`
      // claim makes that an empty string. `storedAddressPattern('')` is
      // `^\\s*\\s*$`: no index can serve it, so every such sign-in scans the
      // whole token collection — and it matches any legacy row whose address
      // is empty, logging a SEVERE about an account that "now uses " followed
      // by nothing. Guarded inside the function rather than at each call
      // site, because one of the two call sites had already forgotten.
      var spy = _CountingStore();

      await warnOnServiceTokenClash(spy, '', 'user-1');
      await warnOnServiceTokenClash(spy, '   ', 'user-1');

      expect(spy.addressLookups, 0);
    });

    test('but a real address is still checked', () async {
      var spy = _CountingStore();

      await warnOnServiceTokenClash(spy, 'ci@example.org', 'user-1');

      expect(spy.addressLookups, 1);
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

  group('a store fault while the check is running', () {
    // The sweep was given a `try`/`catch` per user for exactly this, because
    // an escape there reaches the root zone. The request path, where the same
    // writes run, was never given the equivalent: `ensureValid` awaited them
    // bare, and neither `SessionManager.resolve` nor `TokenService.resolve`
    // nor the gate catches anything — so a momentary database fault came back
    // as an unhandled exception. What that costs is not the failure but its
    // shape: both callers already turn a refusal into something the caller
    // can act on, and a 500 is the one answer neither can.
    late _StoreThatCannotRecord failing;

    setUp(() {
      failing = _StoreThatCannotRecord();
      build(makeConfig(), withStore: failing);
    });

    test('is refused in words rather than left to escape', () async {
      var user = await seedUser(age: const Duration(hours: 1));
      failing.broken = true;

      var result = await validator.ensureValid(user);
      expect(result.isAllowed, isFalse,
          reason: 'a store that cannot answer is not evidence that the '
              'account is still allowed');
      expect(result.reason, contains('try again in a moment'));
      // No sign-in offered. It would take the same trip through the identity
      // provider and fail on the same write at the far end, so the prompt
      // asks somebody to spend a minute answering a question nobody asked.
      expect(result.recoverable, isFalse);
    });

    test('refuses a credential without remembering the refusal', () async {
      var user = await seedUser(age: const Duration(hours: 1));
      failing.broken = true;

      expect((await validator.ensureValid(user, interactive: false)).isAllowed,
          isFalse);

      // The note in `_refusals` is retired only by something that
      // re-establishes the account, so one written for a database fault would
      // go on refusing the credential long after the store came back —
      // demanding the account be confirmed against the provider to clear a
      // verdict the provider never gave.
      failing.broken = false;
      expect((await validator.ensureValid(user, interactive: false)).isAllowed,
          isTrue);
    });

    test('is refused for the check queued behind it too', () async {
      var user = await seedUser(age: const Duration(hours: 1));
      failing.broken = true;

      // The browser's check cannot join a credential check's answer, so it
      // queues behind it — and inherits its error through
      // `existing.result.then(...)`. One fault therefore reaches both
      // requests, and both have to come back with a refusal of their own.
      var credential = validator.ensureValid(user, interactive: false);
      var browser = validator.ensureValid(user);

      expect((await credential).isAllowed, isFalse);
      var joined = await browser;
      expect(joined.isAllowed, isFalse);
      expect(joined.reason, contains('try again in a moment'));
    });
  });
}

/// Lets an unawaited background revalidation run to the end.
///
/// The soft window's whole point is that the check does not sit in front of
/// the request, so the interesting write happens some turns of the event loop
/// after `ensureValid` has answered.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Counts the one query the clash warning makes, which is the query that
/// cannot use an index.
class _CountingStore extends MemoryAuthStore {
  int addressLookups = 0;

  @override
  Future<List<StoredToken>> serviceTokensForEmail(String email) {
    addressLookups++;
    return super.serviceTokensForEmail(email);
  }
}

/// A store whose validation write fails from the moment [broken] is set, the
/// way a momentary database fault does.
class _StoreThatCannotRecord extends MemoryAuthStore {
  bool broken = false;

  @override
  Future<void> recordValidation(
    String id, {
    DateTime? validatedAt,
    int? failures,
    String? refreshTokenEnc,
    List<String>? groups,
    String? email,
    String? displayName,
  }) async {
    if (broken) throw StateError('the database is unreachable');
    return super.recordValidation(id,
        validatedAt: validatedAt,
        failures: failures,
        refreshTokenEnc: refreshTokenEnc,
        groups: groups,
        email: email,
        displayName: displayName);
  }
}

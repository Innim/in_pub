import 'dart:convert';

import 'package:in_pub/src/auth/auth_config.dart';
import 'package:in_pub/src/auth/auth_store.dart';
import 'package:in_pub/src/auth/crypto_box.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:in_pub/src/auth/token_service.dart';
import 'package:in_pub/src/auth/user_validator.dart';
import 'package:test/test.dart';

import 'fake_provider.dart';
import 'memory_auth_store.dart';

/// Tokens are what `dart pub` carries, since it cannot perform a browser
/// redirect. A personal one is only ever as good as the account behind it,
/// which is the whole point: it means the same revocation machinery that
/// governs a browser session governs a CI job.
void main() {
  late MemoryAuthStore store;
  late FakeIdentityProvider provider;
  late TokenService tokens;
  late AuthConfig config;
  late CryptoBox crypto;

  AuthConfig makeConfig({List<String> allowedGroups = const []}) => AuthConfig(
        enabled: true,
        issuer: 'https://id.example.org',
        clientId: 'in-pub',
        clientSecret: 'secret',
        publicUrl: Uri.parse('https://pub.example.org'),
        secret: utf8.encode('a-test-signing-secret-of-sufficient-length!!'),
        allowedGroups: allowedGroups,
        // Revalidation has its own tests; keep it out of the way here.
        revalidateInterval: const Duration(days: 365),
        revalidateHard: const Duration(days: 365),
      );

  void build([AuthConfig? cfg]) {
    config = cfg ?? makeConfig();
    store = MemoryAuthStore();
    provider = FakeIdentityProvider();
    crypto = CryptoBox(config.secret);
    tokens = TokenService(
      config: config,
      store: store,
      validator: UserValidator(
          config: config, store: store, provider: provider, crypto: crypto),
    );
  }

  setUp(build);

  Future<StoredUser> seedUser({
    String id = 'user-1',
    List<String> groups = const ['developers'],
    bool withRefreshToken = false,
  }) async {
    await store.upsertUser(
      AuthenticatedUser(
          id: id,
          email: '$id@example.org',
          displayName: 'Someone',
          groups: groups),
      refreshTokenEnc: withRefreshToken ? crypto.encrypt('refresh-1') : null,
      validatedAt: DateTime.now(),
    );
    return (await store.getUser(id))!;
  }

  group('issuing', () {
    test('hands back a value that works', () async {
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'laptop');

      var result = await tokens.resolve(issued.value);
      expect(result.isAccepted, isTrue);
      expect(result.user!.email, 'user-1@example.org');
      expect(result.token!.name, 'laptop');
    });

    test('stores only a hash of the secret', () async {
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'laptop');

      var stored = store.tokens.values.single;
      expect(issued.value, contains(stored.id));
      expect(issued.value, isNot(contains(stored.secretHash)));
      // Nothing kept can be turned back into the value.
      var secret = issued.value.split('.').last;
      expect(stored.secretHash, isNot(contains(secret)));
      expect(stored.secretHash, CryptoBox.hash(secret));
    });

    test('marks the value so a leak scanner can spot it', () async {
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'laptop');
      expect(issued.value, startsWith('inpub_'));
      expect(TokenService.looksLikeOurs(issued.value), isTrue);
    });

    test('is refused when the account carries no address', () async {
      // A service token's address gets four checks; a personal one was
      // copied off the account with none. A provider that sends no `email`
      // claim leaves it empty — and an empty uploader is not an identity but
      // a bucket every such account shares: the first publish records
      // `uploader: ''`, and the second such person is on that list already.
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-9', email: '', displayName: 'No Address'),
          validatedAt: DateTime.now());
      var owner = (await store.getUser('user-9'))!;

      expect(() => tokens.issuePersonal(owner: owner, name: 'ci'),
          throwsA(isA<TokenIssueRefused>()));
      expect(store.tokens, isEmpty,
          reason: 'nothing may be written for an identity that cannot be '
              'recorded against a publish');
    });

    test('and when it carries something that is not an address', () async {
      // Same rule as the service-token screen applies: whatever is here is
      // matched against uploader lists exactly as written.
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-9', email: 'not-an-address', displayName: 'Odd'),
          validatedAt: DateTime.now());
      var owner = (await store.getUser('user-9'))!;

      expect(() => tokens.issuePersonal(owner: owner, name: 'ci'),
          throwsA(isA<TokenIssueRefused>()));
    });

    test('an address the provider padded is folded, not refused', () async {
      // Padding is not part of an address, and every comparison of one folds
      // it already — so refusing the token would lock a person out of
      // publishing over their provider's spacing, and storing the padded
      // form would leave the record disagreeing with the lookups.
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-8', email: ' Alice@Example.org ', displayName: 'Alice'),
          validatedAt: DateTime.now());

      var issued = await tokens.issuePersonal(
          owner: (await store.getUser('user-8'))!, name: 'laptop');

      expect(issued.record.email, 'alice@example.org');
    });

    test('two tokens are never the same', () async {
      var owner = await seedUser();
      var a = await tokens.issuePersonal(owner: owner, name: 'one');
      var b = await tokens.issuePersonal(owner: owner, name: 'two');
      expect(a.value, isNot(b.value));
      expect(a.record.id, isNot(b.record.id));
    });
  });

  group('refusing', () {
    test('a credential that is not ours is left for another scheme', () async {
      // Not a failure: the legacy Google credential still has to get a turn.
      var result = await tokens.resolve('ya29.some-google-token');
      expect(result.recognised, isFalse);
      expect(result.isAccepted, isFalse);
    });

    test('a token of ours with the wrong secret is a definite refusal',
        () async {
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'laptop');
      var tampered = '${issued.value.split('.').first}.wrong-secret';

      var result = await tokens.resolve(tampered);
      expect(result.recognised, isTrue,
          reason: 'falling through to another scheme would only confuse the '
              'error message');
      expect(result.isAccepted, isFalse);
    });

    test('an unknown id', () async {
      var result = await tokens.resolve('inpub_nosuchid.secret');
      expect(result.isAccepted, isFalse);
      expect(result.message, isNotNull);
    });

    test('a malformed value', () async {
      for (var value in const [
        'inpub_',
        'inpub_nodot',
        'inpub_.',
        'inpub_x.'
      ]) {
        var result = await tokens.resolve(value);
        expect(result.isAccepted, isFalse, reason: value);
      }
    });

    test('a revoked token, and says so', () async {
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'laptop');
      await store.revokeToken(
          issued.record.id, 'revoked by someone@example.org');

      var result = await tokens.resolve(issued.value);
      expect(result.isAccepted, isFalse);
      expect(result.message, contains('revoked'));
    });

    test('an expired token, and suggests a new one', () async {
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(
          owner: owner, name: 'laptop', lifetime: const Duration(days: 1));
      // Rewind the record rather than waiting a day.
      store.tokens[issued.record.id] = StoredToken(
        id: issued.record.id,
        secretHash: issued.record.secretHash,
        kind: issued.record.kind,
        userId: issued.record.userId,
        email: issued.record.email,
        displayName: issued.record.displayName,
        name: issued.record.name,
        createdBy: issued.record.createdBy,
        createdAt: issued.record.createdAt,
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      var result = await tokens.resolve(issued.value);
      expect(result.isAccepted, isFalse);
      expect(result.message, contains('expired'));
    });
  });

  group('a personal token follows its owner', () {
    test('stops working when the account is blocked', () async {
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'ci');
      expect((await tokens.resolve(issued.value)).isAccepted, isTrue);

      await store.setUserStatus('user-1', UserStatus.blockedLocal,
          reason: 'blocked by an administrator');

      var result = await tokens.resolve(issued.value);
      expect(result.isAccepted, isFalse);
      expect(result.message, contains('blocked by an administrator'));
    });

    test('works again once the account is unblocked', () async {
      // Tokens are checked against the owner on every use rather than being
      // revoked outright, so undoing a block does not mean reissuing every
      // token the person had.
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'ci');
      await store.setUserStatus('user-1', UserStatus.blockedLocal);
      await store.setUserStatus('user-1', UserStatus.active);

      expect((await tokens.resolve(issued.value)).isAccepted, isTrue);
    });

    test('unblocking restores the token without marking the account', () async {
      // A local block discards the provider credential: it may stand for
      // years, nothing ever removes the row, and keeping a usable one for
      // somebody who has left is a liability in every backup. So the first
      // check after an unblock has nothing to ask the provider with.
      //
      // What matters is *which* state that produces. `needsSignIn` is a
      // prompt its owner can act on; the earlier behaviour recorded it as
      // revoked by the provider, which no administrator could undo.
      var owner = await seedUser(withRefreshToken: true);
      var issued = await tokens.issuePersonal(owner: owner, name: 'ci');

      await store.setUserStatus('user-1', UserStatus.blockedLocal,
          reason: 'blocked by an administrator');
      expect(store.users['user-1']!.refreshTokenEnc, isNull,
          reason: 'the provider credential goes with the block');

      await store.setUserStatus('user-1', UserStatus.active);
      // What the administration screen does: force the next use to check.
      await store.recordValidation('user-1',
          validatedAt: DateTime.fromMillisecondsSinceEpoch(0), failures: 0);

      // Accepted: an administrator has just decided this person may work
      // again, and the only thing missing is a way to re-check them — which
      // is this server's own doing, not evidence against the account. The
      // status is left alone, so a credential check never marks somebody
      // else's account or ends their browser sessions; the next sign-in
      // records the state properly.
      expect((await tokens.resolve(issued.value)).isAccepted, isTrue);
      expect(store.users['user-1']!.status, UserStatus.active);
    });

    test('stops working when the account is gone', () async {
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'ci');
      store.users.remove('user-1');

      var result = await tokens.resolve(issued.value);
      expect(result.isAccepted, isFalse);
      expect(result.message, contains('no longer exists'));
    });

    test('stops working when the account leaves an allowed group', () async {
      build(makeConfig(allowedGroups: ['developers']));
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'ci');
      expect((await tokens.resolve(issued.value)).isAccepted, isTrue);

      await store.recordValidation('user-1', groups: ['everyone']);

      expect((await tokens.resolve(issued.value)).isAccepted, isFalse);
    });

    test('stops working when the account has no usable address', () async {
      // What a token publishes as is the account's address as it stands now,
      // not as it stood when the token was minted. `_issue` refuses to hand
      // out a token that would publish as nothing; nothing re-asked that
      // question on use, so an account that ends up address-less left an
      // already-issued token recording `uploader: ''` — the one bucket every
      // address-less account shares.
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'ci');
      expect((await tokens.resolve(issued.value)).isAccepted, isTrue);

      // A record with nothing in the field: an account whose very first
      // sign-in carried no `email` claim, or one an older build wrote.
      var now = DateTime.now();
      store.users['user-1'] = StoredUser(
        id: 'user-1',
        email: '',
        displayName: 'Someone',
        groups: const ['developers'],
        status: UserStatus.active,
        createdAt: now,
        updatedAt: now,
        lastValidatedAt: now,
      );

      var result = await tokens.resolve(issued.value);
      expect(result.isAccepted, isFalse);
      expect(result.message, contains('no usable email address'));
    });

    test('but a sign-in that reports no address does not put it there',
        () async {
      // The state above must not be reachable from a provider that simply
      // stops sending the claim — a dropped scope, a directory entry with the
      // field cleared. `upsertUser` used to write it through, so one sign-in
      // refused every token the account held, with no operator action and
      // nothing in the log to connect the two. It also took the record out of
      // `findUsersByEmail`, which is how a blocked publisher's legacy Google
      // credential came to read as belonging to nobody here.
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'ci');

      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-1',
              email: '',
              displayName: 'Someone',
              groups: ['developers']),
          validatedAt: DateTime.now());

      var result = await tokens.resolve(issued.value);
      expect(result.isAccepted, isTrue,
          reason: 'the address already on record is what a token publishes '
              'as; a claim that went missing says nothing about it');
      expect(result.user!.email, 'user-1@example.org');
      expect((await store.findUsersByEmail('user-1@example.org')).single.id,
          'user-1');
    });

    test('reports the owner as its identity', () async {
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'ci');
      var result = await tokens.resolve(issued.value);
      expect(result.user!.id, 'user-1');
      expect(result.user!.email, 'user-1@example.org');
    });
  });

  group('a service token stands alone', () {
    Future<IssuedToken> service() => tokens.issueService(
          createdBy: 'admin-1',
          name: 'release pipeline',
          email: 'ci@example.org',
          displayName: 'Release pipeline',
        );

    test('is refused when its stored address is not an address', () async {
      // A build older than the check at issue time could write anything
      // here, and nothing upstream can revoke a service token — this is the
      // only place left to notice.
      var issued = await service();
      var record = store.tokens[issued.record.id]!;
      store.tokens[record.id] = StoredToken(
        id: record.id,
        secretHash: record.secretHash,
        kind: record.kind,
        email: 'release pipeline',
        displayName: record.displayName,
        name: record.name,
        createdBy: record.createdBy,
        createdAt: record.createdAt,
      );

      var result = await tokens.resolve(issued.value);
      expect(result.isAccepted, isFalse);
      expect(result.message, contains('no usable email address'));
    });

    test('needs no account behind it', () async {
      var issued = await service();
      var result = await tokens.resolve(issued.value);
      expect(result.isAccepted, isTrue);
      expect(result.user!.email, 'ci@example.org');
      expect(result.token!.userId, isNull);
    });

    test('outlives the person who created it', () async {
      // The point of the thing: a pipeline must not stop when someone leaves.
      await seedUser(id: 'admin-1');
      var issued = await service();
      store.users.remove('admin-1');

      expect((await tokens.resolve(issued.value)).isAccepted, isTrue);
    });

    test('records who to ask about it', () async {
      var issued = await service();
      expect(issued.record.createdBy, 'admin-1');
    });

    test('can only be stopped here', () async {
      var issued = await service();
      await store.revokeToken(issued.record.id, 'no longer needed');
      expect((await tokens.resolve(issued.value)).isAccepted, isFalse);
    });

    test('is listed apart from personal ones', () async {
      var owner = await seedUser();
      await tokens.issuePersonal(owner: owner, name: 'laptop');
      await service();

      expect(await store.listServiceTokens(), hasLength(1));
      expect(await store.listTokensOfUser('user-1'), hasLength(1));
    });
  });

  group('usage tracking', () {
    test('records when and where a token was last used', () async {
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'ci');

      await tokens.resolve(issued.value, ip: '10.0.0.7');

      var stored = store.tokens[issued.record.id]!;
      expect(stored.lastUsedAt, isNotNull);
      expect(stored.lastUsedIp, '10.0.0.7');
    });

    test('does not write on every request from the same place', () async {
      // A CI run makes many requests with one token; none of them needs its
      // own database write.
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'ci');

      await tokens.resolve(issued.value, ip: '10.0.0.7');
      var first = store.tokens[issued.record.id]!.lastUsedAt;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await tokens.resolve(issued.value, ip: '10.0.0.7');

      expect(store.tokens[issued.record.id]!.lastUsedAt, first);
    });

    test('a changed address does not force a write of its own', () async {
      // Tempting, but a CI fleet sharing one token behind a proxy presents a
      // different address on nearly every request: resolving two hundred
      // dependencies would cost two hundred writes on the request path. The
      // address is recorded on whatever write the clock allows.
      var owner = await seedUser();
      var issued = await tokens.issuePersonal(owner: owner, name: 'ci');

      await tokens.resolve(issued.value, ip: '10.0.0.7');
      var first = store.tokens[issued.record.id]!.lastUsedAt;
      await tokens.resolve(issued.value, ip: '203.0.113.9');

      expect(store.tokens[issued.record.id]!.lastUsedAt, first);
      expect(store.tokens[issued.record.id]!.lastUsedIp, '10.0.0.7');
    });
  });

  group('reading a stored record', () {
    test('an unrecognised status is refused, not waved through', () {
      // Only a newer build writes a value this one does not know, so a
      // rollback would otherwise read an account that some version of this
      // server decided it could not vouch for as fully active.
      var user = StoredUser.fromJson({
        '_id': 'user-1',
        'email': 'someone@example.org',
        'displayName': 'Someone',
        'status': 'somethingFromTheFuture',
      });
      expect(user.isActive, isFalse);
    });

    test('but a record with no status at all is active', () {
      // Absent means the field predates the column, not that anybody
      // disagrees about it.
      var user = StoredUser.fromJson({
        '_id': 'user-1',
        'email': 'someone@example.org',
        'displayName': 'Someone',
      });
      expect(user.isActive, isTrue);
    });

    test('a token with no secret hash reads as unusable, not as a crash', () {
      // `TokenService.resolve` guards on an empty hash, which a hard cast
      // here made unreachable: the record threw on the way out of the store
      // and every request presenting it became a 500.
      var token = StoredToken.fromJson({
        '_id': 'tok-1',
        'kind': 'personal',
        'name': 'laptop',
        'email': 'someone@example.org',
      });
      expect(token.secretHash, isEmpty);
    });
  });
}

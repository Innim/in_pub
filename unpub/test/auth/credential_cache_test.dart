import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:in_pub/src/auth/auth_config.dart';
import 'package:in_pub/src/auth/auth_service.dart';
import 'package:in_pub/src/auth/auth_store.dart';
import 'package:in_pub/src/auth/google_credential.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'fake_provider.dart';
import 'memory_auth_store.dart';

/// Checking a bearer credential costs two store reads — the token row and
/// the account behind it — and with `--auth-protect-pub-api` one
/// `dart pub get` over a workspace makes hundreds of gated requests. An
/// accepted answer is held for `--auth-credential-cache`.
///
/// What is worth testing about a cache is not that it is fast. It is every
/// case where an answer must *not* be reused: a revoked token, a blocked
/// account, a refusal of any kind, and a fault that reached no verdict at
/// all. Those are what this file is for, and they are pinned by counting the
/// reads rather than by timing anything.
void main() {
  const userAgent = 'Mozilla/5.0 (test)';

  late _CountingStore store;
  late FakeIdentityProvider provider;
  late AuthService auth;
  late shelf.Handler handler;

  AuthService? built;

  /// Long enough that nothing here can pass by an entry quietly expiring.
  /// `revalidateInterval` is pinned open above it because the config refuses
  /// a cache longer than that interval.
  const held = Duration(minutes: 5);

  void build({
    Duration credentialCache = held,
    bool withLegacy = false,
    List<String> allowedGroups = const [],
  }) {
    built?.close();
    store = _CountingStore();
    provider = FakeIdentityProvider();
    auth = AuthService(
      config: AuthConfig(
        enabled: true,
        issuer: 'https://id.example.org',
        clientId: 'in-pub',
        clientSecret: 'client-secret',
        publicUrl: Uri.parse('https://pub.example.org'),
        secret: utf8.encode('a-test-signing-secret-of-sufficient-length!!'),
        allowedGroups: allowedGroups,
        adminGroups: const ['pubadmins'],
        revalidateInterval: const Duration(days: 365),
        revalidateHard: const Duration(days: 365),
        credentialCache: credentialCache,
      ),
      store: store,
      provider: provider,
      googleAuth: withLegacy,
      legacyResolver: withLegacy ? _FakeGoogle() : null,
    );
    built = auth;
    handler = const shelf.Pipeline().addMiddleware(auth.gate).addHandler(
      (req) async {
        if (req.requestedUri.path.startsWith('/auth/')) {
          return auth.handler(req);
        }
        return shelf.Response.ok('package listing');
      },
    );
  }

  setUp(build);
  tearDown(() => built?.close());

  Future<StoredUser> seedUser({
    String id = 'user-1',
    String email = 'someone@example.org',
    List<String> groups = const ['developers'],
    bool withRefreshToken = false,
  }) async {
    await store.upsertUser(
      AuthenticatedUser(
          id: id, email: email, displayName: 'Someone', groups: groups),
      refreshTokenEnc:
          withRefreshToken ? auth.crypto.encrypt('refresh-1') : null,
      validatedAt: DateTime.now(),
    );
    return (await store.getUser(id))!;
  }

  /// A token for [id], issued the way the account screen issues one.
  Future<String> tokenFor({String id = 'user-1'}) async => (await auth.tokens
          .issuePersonal(owner: (await store.getUser(id))!, name: 'ci'))
      .value;

  /// A browser cookie for [id], without walking the whole sign-in flow.
  Future<String> cookieFor(String id) async {
    var user = (await store.getUser(id))!;
    var header = await auth.sessions.create(
      shelf.Request('GET', Uri.parse('https://pub.example.org/'),
          headers: {'user-agent': userAgent}),
      AuthenticatedUser(
          id: user.id,
          email: user.email,
          displayName: user.displayName,
          groups: user.groups),
    );
    return header.split(';').first;
  }

  Future<Map<String, dynamic>> getJson(String path, String cookie) async {
    var res = await handler(shelf.Request(
      'GET',
      Uri.parse('https://pub.example.org$path'),
      headers: {
        'user-agent': userAgent,
        'sec-fetch-mode': 'cors',
        'accept': 'application/json',
        'cookie': cookie,
      },
    ));
    var body = await res.readAsString();
    expect(res.statusCode, HttpStatus.ok, reason: body);
    // The routes answer `{"data": ...}`; the screens read the envelope.
    return (jsonDecode(body) as Map<String, dynamic>)['data']
        as Map<String, dynamic>;
  }

  Future<shelf.Response> postJson(String path, String cookie, String csrf,
          Map<String, Object?> body) async =>
      await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org$path'),
        headers: {
          'user-agent': userAgent,
          'sec-fetch-mode': 'cors',
          'accept': 'application/json',
          'content-type': 'application/json',
          'cookie': cookie,
          'x-csrf-token': csrf,
        },
        body: jsonEncode(body),
      ));

  group('a token of ours', () {
    test('is resolved from the store once, not once per request', () async {
      await seedUser();
      var token = await tokenFor();
      var reads = store.reads;

      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);
      expect(store.reads - reads, 2,
          reason: 'the token row and the account behind it');

      for (var i = 0; i < 10; i++) {
        expect((await auth.tokens.resolve(token)).isAccepted, isTrue);
      }
      expect(store.reads - reads, 2,
          reason: 'the ten requests after the first cost nothing: this is the '
              'whole point of the cache, and one `dart pub get` makes '
              'hundreds of them');
    });

    test('is read again once the entry has expired', () async {
      build(credentialCache: const Duration(milliseconds: 20));
      await seedUser();
      var token = await tokenFor();
      var reads = store.reads;

      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);

      expect(store.reads - reads, 4, reason: 'two reads on each side of it');
    });

    test('is not remembered at all when the cache is switched off', () async {
      build(credentialCache: Duration.zero);
      await seedUser();
      var token = await tokenFor();
      var reads = store.reads;

      for (var i = 0; i < 3; i++) {
        expect((await auth.tokens.resolve(token)).isAccepted, isTrue);
      }
      expect(store.reads - reads, 6,
          reason: 'an operator who turns this off has turned it off');
    });

    test('does not answer for a value carrying the wrong secret', () async {
      // The entry is keyed on the whole presented value rather than on the
      // token id, so it cannot stand in for the secret check. Keyed on the
      // id, anyone who learned an id — it is half of what a leaked value
      // shows, and it is printed on the account screen — could ride an
      // entry somebody else's request had just put there.
      await seedUser();
      var token = await tokenFor();
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);

      var forged = '${token.split('.').first}.wrong-secret';
      var result = await auth.tokens.resolve(forged);
      expect(result.isAccepted, isFalse);
      expect(result.recognised, isTrue);
    });

    test('stops on the very next request when it is revoked', () async {
      // Through the account API, which is how a person revokes one. The
      // handler and the cache are in the same process, so this does not have
      // to wait for the entry to expire — and it must not, because "revoke"
      // is the one word in this subsystem that means *now*.
      var owner = await seedUser();
      var token = await tokenFor();
      var issued = (await store.listTokensOfUser(owner.id)).single;
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);

      var cookie = await cookieFor('user-1');
      var view = await getJson('/auth/api/account', cookie);
      var res = await postJson('/auth/api/account/tokens/revoke', cookie,
          view['csrfToken'] as String, {'token': issued.id});
      expect(res.statusCode, HttpStatus.ok, reason: await res.readAsString());

      var result = await auth.tokens.resolve(token);
      expect(result.isAccepted, isFalse);
      expect(result.message, contains('revoked'));
    });

    test('stops on the very next request when an administrator revokes it',
        () async {
      // A service token is the administrator's to revoke, and it arrives at
      // the same handler by a different permission — so the entry has to go
      // on that path too.
      await seedUser(id: 'admin-1', groups: const ['pubadmins']);
      var issued = await auth.tokens.issueService(
          createdBy: 'admin-1',
          name: 'release pipeline',
          email: 'ci@example.org',
          displayName: 'Release pipeline');
      expect((await auth.tokens.resolve(issued.value)).isAccepted, isTrue);

      var cookie = await cookieFor('admin-1');
      var view = await getJson('/auth/api/account', cookie);
      var res = await postJson('/auth/api/account/tokens/revoke', cookie,
          view['csrfToken'] as String, {'token': issued.record.id});
      expect(res.statusCode, HttpStatus.ok, reason: await res.readAsString());

      expect((await auth.tokens.resolve(issued.value)).isAccepted, isFalse);
    });

    test('stops on the very next request when its owner is blocked', () async {
      // Blocking somebody does not revoke their tokens — deliberately, so
      // that unblocking restores them rather than costing everybody a
      // reissue — which leaves the owner check as the only thing that stops
      // one. That check is exactly what a cache hit skips.
      await seedUser(id: 'admin-1', groups: const ['pubadmins']);
      await seedUser(id: 'user-2', email: 'them@example.org');
      var token = await tokenFor(id: 'user-2');
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);

      var cookie = await cookieFor('admin-1');
      var view = await getJson('/auth/api/admin', cookie);
      var res = await postJson('/auth/api/admin/action', cookie,
          view['csrfToken'] as String, {'user': 'user-2', 'do': 'block'});
      expect(res.statusCode, HttpStatus.ok, reason: await res.readAsString());

      var result = await auth.tokens.resolve(token);
      expect(result.isAccepted, isFalse);
      expect(result.message, contains('administrator'));
    });

    test('is not re-armed by a request that landed mid-revocation', () async {
      // The reason the entry is dropped on both sides of the write. A bearer
      // request that arrives while `revokeToken` is in flight reads a row
      // that is still live and is rightly accepted — and if that acceptance
      // were left in the map, the revocation would take a full window to
      // land instead of landing on the next request.
      var owner = await seedUser();
      var token = await tokenFor();
      var issued = (await store.listTokensOfUser(owner.id)).single;
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);

      var cookie = await cookieFor('user-1');
      var view = await getJson('/auth/api/account', cookie);
      var gate = _Gate();
      store.revokeTokenGate = gate;
      var revoking = postJson('/auth/api/account/tokens/revoke', cookie,
          view['csrfToken'] as String, {'token': issued.id});
      await gate.arrived;

      // Mid-write, and legitimately accepted: the row still says so.
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);

      gate.release();
      expect((await revoking).statusCode, HttpStatus.ok);

      expect((await auth.tokens.resolve(token)).isAccepted, isFalse,
          reason: 'the acceptance written during the write has to go with '
              'it, or the revocation lands a window late');
    });

    test('is not written by a resolution that outlived the revocation',
        () async {
      // The other half, and the one a second drop cannot reach: this request
      // has not written its entry yet when the revocation finishes, so there
      // is nothing there to drop. It is refused the write instead.
      await seedUser();
      var token = await tokenFor();
      var issued = (await store.listTokensOfUser('user-1')).single;
      var cookie = await cookieFor('user-1');
      var view = await getJson('/auth/api/account', cookie);

      var gate = _Gate();
      store.getUserGate = gate;
      var resolving = auth.tokens.resolve(token);
      await gate.arrived;

      // The whole revocation, start to finish, while that resolution is
      // parked on the account read.
      var res = await postJson('/auth/api/account/tokens/revoke', cookie,
          view['csrfToken'] as String, {'token': issued.id});
      expect(res.statusCode, HttpStatus.ok, reason: await res.readAsString());

      gate.release();
      expect((await resolving).isAccepted, isTrue,
          reason: 'it read a live row and is answered on what it read');

      expect((await auth.tokens.resolve(token)).isAccepted, isFalse,
          reason: 'but it may not leave that answer behind for the next one');
    });

    test('is not re-armed by a request that landed mid-block', () async {
      // The same race on the account rather than the token.
      await seedUser(id: 'admin-1', groups: const ['pubadmins']);
      await seedUser(id: 'user-2', email: 'them@example.org');
      var token = await tokenFor(id: 'user-2');
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);

      var cookie = await cookieFor('admin-1');
      var view = await getJson('/auth/api/admin', cookie);
      var gate = _Gate();
      store.setUserStatusGate = gate;
      var blocking = postJson('/auth/api/admin/action', cookie,
          view['csrfToken'] as String, {'user': 'user-2', 'do': 'block'});
      await gate.arrived;

      expect((await auth.tokens.resolve(token)).isAccepted, isTrue,
          reason: 'the account is still active as far as the store is '
              'concerned');

      gate.release();
      expect((await blocking).statusCode, HttpStatus.ok);

      expect((await auth.tokens.resolve(token)).isAccepted, isFalse);
    });

    test('stops when the validator refuses the account elsewhere', () async {
      // The refusals that need saying out loud are the ones nobody is
      // waiting for: a background revalidation, the sweep, or — as here —
      // another request for the same account. They are reached on the
      // validator's schedule and recorded in its own note map, so a cache
      // keyed on the credential would never see one.
      await seedUser(withRefreshToken: true);
      var token = await tokenFor();
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);

      // The account is now due a check, and the provider has stopped
      // vouching for it. A browser request is what discovers this.
      await store.recordValidation('user-1',
          validatedAt: DateTime.fromMillisecondsSinceEpoch(0));
      provider.refreshError =
          IdentityRevokedException('the account is disabled');
      var verdict =
          await auth.validator.ensureValid((await store.getUser('user-1'))!);
      expect(verdict.isAllowed, isFalse);

      expect((await auth.tokens.resolve(token)).isAccepted, isFalse,
          reason: 'the entry must not outlive the verdict');
    });

    test('is refused, not cached, while the validator is withdrawing access',
        () async {
      // The validator serialises one check per account, and a credential
      // check that arrives while an interactive one is running joins it
      // rather than starting a second — so this resolution cannot slip past
      // the refusal being written, and takes the refusal as its own answer.
      // What is being pinned is that it also leaves nothing behind: the next
      // request is refused too, on the store rather than on a stale entry.
      await seedUser(withRefreshToken: true);
      var token = await tokenFor();
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);

      await store.recordValidation('user-1',
          validatedAt: DateTime.fromMillisecondsSinceEpoch(0));
      provider.refreshError =
          IdentityRevokedException('the account is disabled');

      var gate = _Gate();
      store.setUserStatusGate = gate;
      var withdrawing =
          auth.validator.ensureValid((await store.getUser('user-1'))!);
      await gate.arrived;

      var racing = auth.tokens.resolve(token);
      gate.release();
      expect((await withdrawing).isAllowed, isFalse);
      expect((await racing).isAccepted, isFalse);

      expect((await auth.tokens.resolve(token)).isAccepted, isFalse);
    });

    test('is not held for an account that has to sign in again', () async {
      // `needsSignIn` is a prompt rather than a withdrawal, but `ensureValid`
      // refuses on it all the same — so an entry standing behind it would be
      // answering for an account this server has just said it cannot vouch
      // for.
      await seedUser(withRefreshToken: true);
      var token = await tokenFor();
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);

      // Nothing left to re-check with — a local block discards the provider
      // credential, and it is not put back — discovered by a browser request
      // once the account is due a check.
      await store.recordValidation('user-1',
          validatedAt: DateTime.fromMillisecondsSinceEpoch(0));
      await store.setUserStatus('user-1', UserStatus.blockedLocal);
      await store.setUserStatus('user-1', UserStatus.active);
      await auth.validator.ensureValid((await store.getUser('user-1'))!);
      expect(store.users['user-1']!.status, UserStatus.needsSignIn);

      expect((await auth.tokens.resolve(token)).isAccepted, isFalse);
    });
  });

  group('a refusal', () {
    test('is never remembered, so unblocking works on the next request',
        () async {
      // The other half of the rule the cache rests on. If refusals were
      // held, an account blocked between two requests would be refused for
      // the length of the window after it was put back — and, worse, a
      // caller with no credential at all could fill the map with values they
      // invented, since a refusal is the answer anyone can provoke.
      await seedUser();
      var token = await tokenFor();
      await store.setUserStatus('user-1', UserStatus.blockedLocal,
          reason: 'blocked by an administrator');
      expect((await auth.tokens.resolve(token)).isAccepted, isFalse);

      await store.setUserStatus('user-1', UserStatus.active);
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue,
          reason: 'nothing was written down about the refusal');
    });

    test('costs the same two reads every time', () async {
      await seedUser();
      var token = await tokenFor();
      await store.setUserStatus('user-1', UserStatus.blockedLocal);
      var reads = store.reads;

      for (var i = 0; i < 3; i++) {
        expect((await auth.tokens.resolve(token)).isAccepted, isFalse);
      }
      expect(store.reads - reads, 6, reason: 'no refusal was remembered');
    });

    test('of an unknown token leaves nothing behind', () async {
      // The keys are hashes of whatever was presented, so this is the shape
      // an unauthenticated caller would use to make the server allocate.
      var reads = store.reads;
      for (var i = 0; i < 20; i++) {
        expect((await auth.tokens.resolve('inpub_id$i.secret$i')).isAccepted,
            isFalse);
      }
      expect(store.reads - reads, 20,
          reason: 'every invented value cost its own read and bought no '
              'entry: had they been remembered, the map would now hold '
              'twenty of them');
    });
  });

  group('a store fault', () {
    test('is not remembered as a verdict either way', () async {
      // The fault produces `ValidationResult.inconclusive`: a refusal,
      // because a store this server cannot read is no evidence the account
      // is still permitted, but one that says nothing *about the account*.
      // Memoising it would turn a one-second database fault into a window of
      // refusals for a credential that was fine all along.
      build();
      await seedUser(withRefreshToken: true);
      var token = await tokenFor();
      // Past the hard deadline, so the check has to be current before
      // anything is served and its writes sit on the request path.
      await store.recordValidation('user-1',
          validatedAt: DateTime.fromMillisecondsSinceEpoch(0));

      store.recordValidationFails = true;
      var refused = await auth.tokens.resolve(token);
      expect(refused.isAccepted, isFalse);
      expect(refused.message, contains('try again in a moment'));

      store.recordValidationFails = false;
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue,
          reason: 'the very next request, with no window to wait out');
    });

    test('does not leave an acceptance standing', () async {
      build();
      await seedUser(withRefreshToken: true);
      var token = await tokenFor();
      expect((await auth.tokens.resolve(token)).isAccepted, isTrue);

      // The account is blocked while the store is unreadable, so the
      // remembered acceptance is the only thing that could serve it.
      await store.setUserStatus('user-1', UserStatus.blockedLocal,
          reason: 'blocked by an administrator');
      auth.tokens.forgetEverything();
      expect((await auth.tokens.resolve(token)).isAccepted, isFalse);
    });
  });

  group('usage tracking', () {
    test('records the first use of a token as it always did', () async {
      await seedUser();
      var token = await tokenFor();
      var id = (await store.listTokensOfUser('user-1')).single.id;

      await auth.tokens.resolve(token, ip: '10.0.0.7');

      expect(store.tokens[id]!.lastUsedAt, isNotNull);
      expect(store.tokens[id]!.lastUsedIp, '10.0.0.7');
    });

    test('keeps the throttle across a cache hit rather than losing it',
        () async {
      // Both directions are bugs. Reading `lastUsedAt` off the frozen
      // snapshot would write on every request once the interval had passed;
      // skipping the write on a hit would freeze the account screen's "last
      // used" column, which is what somebody reads to decide whether a token
      // is still in use before revoking it.
      await seedUser();
      var token = await tokenFor();
      var writes = store.touchCalls;

      for (var i = 0; i < 5; i++) {
        await auth.tokens.resolve(token, ip: '10.0.0.7');
      }
      expect(store.touchCalls - writes, 1,
          reason: 'one write for five requests, exactly as before');
    });

    test('starts recording again once the entry is gone', () async {
      await seedUser();
      var token = await tokenFor();
      var id = (await store.listTokensOfUser('user-1')).single.id;
      await auth.tokens.resolve(token, ip: '10.0.0.7');
      var first = store.tokens[id]!.lastUsedAt;

      // What the clock does after the entry expires: the record is read
      // afresh, and its `lastUsedAt` is old enough to write again.
      await store.touchToken(
          id, DateTime.now().subtract(const Duration(hours: 1)));
      auth.tokens.forgetEverything();
      await auth.tokens.resolve(token, ip: '10.0.0.9');

      expect(store.tokens[id]!.lastUsedAt, isNot(first));
      expect(store.tokens[id]!.lastUsedIp, '10.0.0.9',
          reason: 'a cache must not quietly stop the column moving');
    });
  });

  group('the legacy Google credential', () {
    setUp(() => build(withLegacy: true));

    Future<void> seedLegacyUser({String id = 'user-legacy'}) =>
        seedUser(id: id, email: 'old@example.org');

    test('looks its address up once, not once per handshake request', () async {
      // `dart pub publish` makes three gated requests. Each one used to cost
      // an address lookup and a validation for every identity that address
      // resolves to — and only the *credential* half of the path was ever
      // memoised.
      await seedLegacyUser();
      var lookups = store.findUsersByEmailCalls;

      for (var i = 0; i < 3; i++) {
        var result = await auth.resolveBearer('legacy-ok', allowLegacy: true);
        expect(result.isAccepted, isTrue);
        expect(result.provisional, isFalse);
      }
      expect(store.findUsersByEmailCalls - lookups, 1);
    });

    test('looks it up again once the entry has expired', () async {
      build(
          withLegacy: true, credentialCache: const Duration(milliseconds: 20));
      await seedLegacyUser();
      var lookups = store.findUsersByEmailCalls;

      expect(
          (await auth.resolveBearer('legacy-ok', allowLegacy: true)).isAccepted,
          isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(
          (await auth.resolveBearer('legacy-ok', allowLegacy: true)).isAccepted,
          isTrue);

      expect(store.findUsersByEmailCalls - lookups, 2);
    });

    test('may not be held longer than the revalidation interval', () async {
      // The argument for holding this verdict at all is that nothing
      // consults the provider about an account inside
      // `--auth-revalidate-interval`, so a cache no longer than it changes
      // nothing about when a revocation lands. Past that the cache would be
      // the thing deciding it, against what that flag's help text promises.
      var errors = AuthConfig(
        enabled: true,
        issuer: 'https://id.example.org',
        clientId: 'in-pub',
        clientSecret: 'client-secret',
        publicUrl: Uri.parse('https://pub.example.org'),
        secret: utf8.encode('a-test-signing-secret-of-sufficient-length!!'),
        revalidateInterval: const Duration(minutes: 5),
        revalidateHard: const Duration(minutes: 30),
        credentialCache: const Duration(minutes: 6),
      ).validate();
      expect(errors, hasLength(1));
      expect(errors.single, contains('--auth-credential-cache'));
    });

    test('remembers no refusal, so a block lifts on the next request',
        () async {
      await seedLegacyUser();
      await store.setUserStatus('user-legacy', UserStatus.blockedLocal,
          reason: 'blocked by an administrator');
      expect(
          (await auth.resolveBearer('legacy-ok', allowLegacy: true)).isAccepted,
          isFalse);

      await store.setUserStatus('user-legacy', UserStatus.active);
      expect(
          (await auth.resolveBearer('legacy-ok', allowLegacy: true)).isAccepted,
          isTrue);
    });

    test('stops on the very next request when its owner is blocked', () async {
      // The same demand made of a token, and it needs its own wiring: this
      // verdict is keyed on the address rather than on any credential, so
      // forgetting a user has to reach the entries their address is in.
      await seedUser(id: 'admin-1', groups: const ['pubadmins']);
      await seedLegacyUser();
      expect(
          (await auth.resolveBearer('legacy-ok', allowLegacy: true)).isAccepted,
          isTrue);

      var cookie = await cookieFor('admin-1');
      var view = await getJson('/auth/api/admin', cookie);
      var res = await postJson('/auth/api/admin/action', cookie,
          view['csrfToken'] as String, {'user': 'user-legacy', 'do': 'block'});
      expect(res.statusCode, HttpStatus.ok, reason: await res.readAsString());

      expect(
          (await auth.resolveBearer('legacy-ok', allowLegacy: true)).isAccepted,
          isFalse);
    });

    test('is not re-armed by a request that landed mid-block', () async {
      // The address-keyed verdict has the same before/after question as the
      // token cache, and is answered by the same hook — so it needs the same
      // check that the answer written during the block goes with it.
      await seedUser(id: 'admin-1', groups: const ['pubadmins']);
      await seedLegacyUser();
      expect(
          (await auth.resolveBearer('legacy-ok', allowLegacy: true)).isAccepted,
          isTrue);

      var cookie = await cookieFor('admin-1');
      var view = await getJson('/auth/api/admin', cookie);
      var gate = _Gate();
      store.setUserStatusGate = gate;
      var blocking = postJson('/auth/api/admin/action', cookie,
          view['csrfToken'] as String, {'user': 'user-legacy', 'do': 'block'});
      await gate.arrived;

      expect(
          (await auth.resolveBearer('legacy-ok', allowLegacy: true)).isAccepted,
          isTrue,
          reason: 'the account is still active in the store');

      gate.release();
      expect((await blocking).statusCode, HttpStatus.ok);

      expect(
          (await auth.resolveBearer('legacy-ok', allowLegacy: true)).isAccepted,
          isFalse);
    });

    test('a second identity behind one address also retires the verdict',
        () async {
      // An address is not unique here — a provider migration leaves two
      // identities behind one — and the verdict says every one of them was
      // in good standing. Any of them ceasing to be has to take it down,
      // which is why the entry remembers all of the ids it covered.
      await seedUser(id: 'admin-1', groups: const ['pubadmins']);
      await seedLegacyUser(id: 'user-old');
      await seedLegacyUser(id: 'user-new');
      expect(
          (await auth.resolveBearer('legacy-ok', allowLegacy: true)).isAccepted,
          isTrue);

      var cookie = await cookieFor('admin-1');
      var view = await getJson('/auth/api/admin', cookie);
      await postJson('/auth/api/admin/action', cookie,
          view['csrfToken'] as String, {'user': 'user-old', 'do': 'block'});

      expect(
          (await auth.resolveBearer('legacy-ok', allowLegacy: true)).isAccepted,
          isFalse);
    });
  });

  group('the flag', () {
    test('needs --auth, like the other flags that would do nothing without it',
        () {
      var errors =
          AuthConfig.disabled(credentialCache: const Duration(seconds: 5))
              .validate();
      expect(errors, hasLength(1));
      expect(errors.single, contains('--auth-credential-cache needs --auth'));
    });

    test('is not reported when it was never stated', () {
      expect(AuthConfig.disabled().validate(), isEmpty);
      expect(AuthConfig.disabled().credentialCache,
          AuthConfig.defaultCredentialCache);
    });
  });
}

/// A store that counts what it was asked for, and can be made to fail the
/// way a momentary database fault does.
class _CountingStore extends MemoryAuthStore {
  int getTokenCalls = 0;
  int getUserCalls = 0;
  int touchCalls = 0;
  int findUsersByEmailCalls = 0;

  /// Set to fail the validation write, which is what a check that has to be
  /// current reaches on the request path.
  bool recordValidationFails = false;

  /// One-shot stalls, so a test can drive a request into the gap between a
  /// withdrawal starting and its write landing. One-shot because the
  /// handlers under test call these methods for their own reasons too, and a
  /// standing stall would deadlock the request that is meant to be running.
  _Gate? getUserGate;
  _Gate? revokeTokenGate;
  _Gate? setUserStatusGate;

  /// The two reads one credential check costs when nothing is remembered.
  int get reads => getTokenCalls + getUserCalls;

  @override
  Future<StoredToken?> getToken(String id) {
    getTokenCalls++;
    return super.getToken(id);
  }

  @override
  Future<StoredUser?> getUser(String id) async {
    getUserCalls++;
    await _pass(() => getUserGate, (g) => getUserGate = g);
    return super.getUser(id);
  }

  @override
  Future<bool> revokeToken(String id, String reason) async {
    await _pass(() => revokeTokenGate, (g) => revokeTokenGate = g);
    return super.revokeToken(id, reason);
  }

  @override
  Future<void> setUserStatus(String id, UserStatus status,
      {String? reason}) async {
    await _pass(() => setUserStatusGate, (g) => setUserStatusGate = g);
    return super.setUserStatus(id, status, reason: reason);
  }

  Future<void> _pass(
      _Gate? Function() read, void Function(_Gate?) write) async {
    var gate = read();
    if (gate == null) return;
    write(null);
    await gate.pass();
  }

  @override
  Future<List<StoredUser>> findUsersByEmail(String email) {
    findUsersByEmailCalls++;
    return super.findUsersByEmail(email);
  }

  @override
  Future<void> touchToken(String id, DateTime usedAt, {String? ip}) {
    touchCalls++;
    return super.touchToken(id, usedAt, ip: ip);
  }

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
    if (recordValidationFails) throw StateError('the database is unreachable');
    return super.recordValidation(id,
        validatedAt: validatedAt,
        failures: failures,
        refreshTokenEnc: refreshTokenEnc,
        groups: groups,
        email: email,
        displayName: displayName);
  }
}

/// A one-shot stall: it reports when a call arrives and holds it until the
/// test lets go.
class _Gate {
  final _arrived = Completer<void>();
  final _release = Completer<void>();

  /// Completes once the call under test has reached the store.
  Future<void> get arrived => _arrived.future.timeout(const Duration(
        seconds: 5,
      ));

  Future<void> pass() {
    if (!_arrived.isCompleted) _arrived.complete();
    return _release.future;
  }

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

/// Stands in for the original Google credential.
class _FakeGoogle extends GoogleCredentialResolver {
  @override
  Future<String?> resolve(String token) async =>
      token == 'legacy-ok' ? 'old@example.org' : null;
}

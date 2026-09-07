import 'package:in_pub/src/auth/auth_store.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:in_pub/src/auth/mongo_auth_store.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:test/test.dart';

import 'memory_auth_store.dart';

/// The store is where address equality is actually decided, and the queries
/// that decide it cannot be exercised through the in-memory double: the
/// legacy-record path exists precisely for documents the double cannot
/// represent, and a folded key written by the wrong rule is invisible until
/// something queries on it. These run against a real MongoDB, as
/// `unpub_test.dart` does.
///
/// Every question asked of the Mongo store here is asked of the double as
/// well. A double that answers more generously than production is how the
/// untrimmed-address bugs stayed hidden through four rounds of review.
void main() {
  late Db db;
  late MongoAuthStore store;

  setUpAll(() async {
    db = Db('mongodb://localhost:27017/dart_pub_test');
    await db.open();
  });

  tearDownAll(() => db.close());

  setUp(() async {
    // Delete rather than drop, for the reason `unpub_test.dart` gives: in
    // mongo_dart 0.7.4 `dropCollection` silently no-ops on some servers.
    await db.collection(authUserCollection).deleteMany(<String, dynamic>{});
    await db.collection(authTokenCollection).deleteMany(<String, dynamic>{});
    await db.collection(authSessionCollection).deleteMany(<String, dynamic>{});
    store = MongoAuthStore(db);
  });

  /// A record as an older build wrote it: an address exactly as the provider
  /// spelled it, and no folded key at all.
  Future<void> seedLegacyUser(String email,
      {String id = 'legacy-1', UserStatus status = UserStatus.blockedLocal}) {
    return db.collection(authUserCollection).insertOne(<String, dynamic>{
      '_id': id,
      'email': email,
      'displayName': 'Legacy',
      'groups': <String>[],
      'status': status.name,
      'createdAt': DateTime.now(),
      'updatedAt': DateTime.now(),
    });
  }

  Future<Map<String, dynamic>?> readRaw(String id) =>
      db.collection(authUserCollection).findOne(where.eq('_id', id));

  group('the folded key', () {
    test('a revalidation writes it trimmed, not merely folded', () async {
      // `userinfo` does not trim. A provider answering `"alice@example.org "`
      // had the sweep overwrite a correct key with an untrimmed one, and from
      // then on the address check — which matches on this field — found
      // nothing. What that buys is the one outcome it must not: a blocked
      // publisher's legacy Google credential reads as belonging to no account
      // here, which is the case that is accepted.
      await store.upsertUser(const AuthenticatedUser(
          id: 'user-1', email: 'alice@example.org', displayName: 'Alice'));
      await store.setUserStatus('user-1', UserStatus.blockedLocal,
          reason: 'withdrawn');

      await store.recordValidation('user-1', email: ' Alice@Example.org ');

      expect((await readRaw('user-1'))!['emailKey'], 'alice@example.org');
      var found = await store.findUsersByEmail('alice@example.org');
      expect(found.map((u) => u.id), ['user-1']);
      expect(found.single.isActive, isFalse,
          reason: 'the block has to keep being found by address');
    });

    test('and the double agrees', () async {
      var double = MemoryAuthStore();
      await double.upsertUser(const AuthenticatedUser(
          id: 'user-1', email: 'alice@example.org', displayName: 'Alice'));
      await double.recordValidation('user-1', email: ' Alice@Example.org ');

      expect((await double.findUsersByEmail('alice@example.org')).single.id,
          'user-1');
    });

    test('an address that is not one does not overwrite a good one', () async {
      // `/userinfo` answers with an empty `email` when the claim is missing —
      // a scope dropped on the client, a directory entry with the field
      // cleared. Written through, it clears the address and the key with it,
      // so this record answers no address lookup at all: a blocked
      // publisher's legacy credential then reads as belonging to nobody
      // here, which is the one case that is accepted.
      await store.upsertUser(const AuthenticatedUser(
          id: 'user-1', email: 'alice@example.org', displayName: 'Alice'));
      await store.setUserStatus('user-1', UserStatus.blockedLocal,
          reason: 'withdrawn');

      await store.recordValidation('user-1', email: '  ');

      var raw = (await readRaw('user-1'))!;
      expect(raw['email'], 'alice@example.org');
      expect(raw['emailKey'], 'alice@example.org');
      expect((await store.findUsersByEmail('alice@example.org')).single.id,
          'user-1');
    });

    test('and the double agrees about that as well', () async {
      var double = MemoryAuthStore();
      await double.upsertUser(const AuthenticatedUser(
          id: 'user-1', email: 'alice@example.org', displayName: 'Alice'));

      await double.recordValidation('user-1', email: '  ');

      expect((await double.getUser('user-1'))!.email, 'alice@example.org');
      expect((await double.findUsersByEmail('alice@example.org')).single.id,
          'user-1');
    });

    test('nor does a sign-in that carries no address', () async {
      // The same hazard as the revalidation above, one door along. A sign-in
      // goes through `upsertUser`, which wrote the claim unconditionally: a
      // provider that stops sending `email` blanked a good stored address on
      // the owner's next visit. Every personal token the account holds is
      // refused from that moment — `looksLikeEmailAddress('')` is false — and
      // the record answers no address lookup, so a *blocked* publisher's
      // legacy Google credential reads as belonging to nobody here, which is
      // the one case that is accepted.
      await store.upsertUser(const AuthenticatedUser(
          id: 'user-1', email: 'alice@example.org', displayName: 'Alice'));
      await store.setUserStatus('user-1', UserStatus.blockedLocal,
          reason: 'withdrawn');

      await store.upsertUser(const AuthenticatedUser(
          id: 'user-1', email: '  ', displayName: 'Alice'));

      var raw = (await readRaw('user-1'))!;
      expect(raw['email'], 'alice@example.org');
      expect(raw['emailKey'], 'alice@example.org');
      expect((await store.findUsersByEmail('alice@example.org')).single.id,
          'user-1');
    });

    test('and the double agrees about sign-in too', () async {
      var double = MemoryAuthStore();
      await double.upsertUser(const AuthenticatedUser(
          id: 'user-1', email: 'alice@example.org', displayName: 'Alice'));

      await double.upsertUser(const AuthenticatedUser(
          id: 'user-1', email: '  ', displayName: 'Alice'));

      expect((await double.getUser('user-1'))!.email, 'alice@example.org');
      expect((await double.findUsersByEmail('alice@example.org')).single.id,
          'user-1');
    });

    test('an account created without one still carries the field', () async {
      // Leaving it off entirely would put the record in the startup
      // backfill's `emailKey: null` bucket forever, and make it shaped
      // unlike every other row.
      await store.upsertUser(const AuthenticatedUser(
          id: 'user-2', email: '', displayName: 'No Address'));

      var raw = (await readRaw('user-2'))!;
      expect(raw['email'], '');
      expect(raw['emailKey'], '');
    });
  });

  group('a record written before the folded key existed', () {
    test('is still found by address', () async {
      await seedLegacyUser('alice@example.org');

      var found = await store.findUsersByEmail('alice@example.org');
      expect(found.single.id, 'legacy-1');
    });

    test('is found even with stored whitespace around it', () async {
      // The three queries that decide address equality disagreed: this one
      // anchored on the raw argument, while the service-token lookup and the
      // uploader lookup tolerate stored padding. A record kept as
      // `" alice@example.org"` slipped past the check that stops a service
      // token being handed somebody else's address, and the token minted
      // from it could publish as them.
      await seedLegacyUser(' alice@example.org');

      expect((await store.findUsersByEmail('alice@example.org')).single.id,
          'legacy-1');
    });

    test('is found whatever the case either side is written in', () async {
      await seedLegacyUser('Alice@Example.org');

      expect((await store.findUsersByEmail(' ALICE@example.ORG ')).single.id,
          'legacy-1');
    });

    test('but a different address is not', () async {
      await seedLegacyUser('alice@example.org');

      expect(await store.findUsersByEmail('bob@example.org'), isEmpty);
      expect(await store.findUsersByEmail('alice@example.orgx'), isEmpty);
    });

    test('and a regular expression typed as an address matches nothing',
        () async {
      await seedLegacyUser('alice@example.org');

      expect(await store.findUsersByEmail('.*'), isEmpty);
      expect(await store.findUsersByEmail('alice@example.or.'), isEmpty);
    });

    test('is returned alongside a migrated record sharing the address',
        () async {
      // An address is not unique here — a provider migration, an address
      // reissued to a new hire — which is why this answers with a list at
      // all. Stopping at the indexed hit meant one migrated record hid every
      // unmigrated one beside it: the blocked person was never returned,
      // never checked, and went on publishing with their legacy Google
      // credential under their other identity. Which is the outcome the
      // method's own doc comment says it prevents.
      await seedLegacyUser('alice@example.org', id: 'blocked-before-upgrade');
      await store.upsertUser(const AuthenticatedUser(
          id: 'migrated', email: 'Alice@Example.org', displayName: 'Alice'));

      var found = await store.findUsersByEmail('alice@example.org');

      expect(found.map((u) => u.id),
          unorderedEquals(<String>['blocked-before-upgrade', 'migrated']));
      expect(found.where((u) => !u.isActive), hasLength(1),
          reason: 'the block has to be among what the caller is handed');
    });

    test('and nobody is reported twice', () async {
      // The two queries are disjoint only while nothing writes an `emailKey`
      // between them, and the caller reads this as a list of distinct
      // identities.
      await store.upsertUser(const AuthenticatedUser(
          id: 'user-1', email: 'alice@example.org', displayName: 'Alice'));

      expect(await store.findUsersByEmail('alice@example.org'), hasLength(1));
    });

    test('and the double agrees that an address maps to every record',
        () async {
      // The double cannot hold an unmigrated record — its key is derived,
      // not stored — but it can hold two identities at one address, and it
      // has to hand back both for the same reason.
      var double = MemoryAuthStore();
      await double.upsertUser(const AuthenticatedUser(
          id: 'user-1', email: 'alice@example.org', displayName: 'Alice'));
      await double.upsertUser(const AuthenticatedUser(
          id: 'user-2', email: 'Alice@Example.org ', displayName: 'Alice'));

      expect(
          (await double.findUsersByEmail('alice@example.org')).map((u) => u.id),
          unorderedEquals(<String>['user-1', 'user-2']));
    });
  });

  group('sessions', () {
    Future<void> seedSession(String id, {String userId = 'user-1'}) =>
        store.createSession(StoredSession(
          id: id,
          userId: userId,
          secretHash: 'hash',
          rotatedAt: DateTime.now().toUtc(),
          uaHash: 'ua',
          ip: '127.0.0.1',
          createdAt: DateTime.now().toUtc(),
          lastSeenAt: DateTime.now().toUtc(),
          expiresAt: DateTime.now().toUtc().add(const Duration(hours: 8)),
        ));

    test('revoking says whether this call is the one that did it', () async {
      // The update is conditional on the row still being live, exactly as
      // the token one is. Answering `void` left the account screen reporting
      // an end that had not happened and writing it into the log.
      await seedSession('sess-1');

      expect(await store.revokeSession('sess-1', 'ended'), isTrue);
      expect(await store.revokeSession('sess-1', 'ended'), isFalse);
      expect(await store.revokeSession('sess-absent', 'ended'), isFalse,
          reason: 'nothing was matched, so nothing was revoked');
    });

    test('and the double agrees about that', () async {
      var double = MemoryAuthStore();
      await double.createSession(StoredSession(
        id: 'sess-1',
        userId: 'user-1',
        secretHash: 'hash',
        rotatedAt: DateTime.now().toUtc(),
        uaHash: 'ua',
        ip: '127.0.0.1',
        createdAt: DateTime.now().toUtc(),
        lastSeenAt: DateTime.now().toUtc(),
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 8)),
      ));

      expect(await double.revokeSession('sess-1', 'ended'), isTrue);
      expect(await double.revokeSession('sess-1', 'ended'), isFalse);
      expect(await double.revokeSession('sess-absent', 'ended'), isFalse);
    });
  });

  group('the startup backfill', () {
    test('gives an older record a key that matches what is written today',
        () async {
      await seedLegacyUser(' Alice@Example.org ');

      await store.runMigrations();

      expect((await readRaw('legacy-1'))!['emailKey'], 'alice@example.org',
          reason: 'folding alone leaves a key no later write would produce, '
              'so the indexed lookup keeps missing the record');
    });

    test('falls back per document when the server rejects the pipeline',
        () async {
      // An update pipeline needs MongoDB 4.2, and an older server does not
      // throw for one: `updateMany` hands back a failed `WriteResult`. Read
      // only for an exception, the fallback never ran on the deployments it
      // exists for — nothing was backfilled and nothing was logged, so a
      // blocked publisher stayed unfindable by address indefinitely.
      await seedLegacyUser(' Alice@Example.org ');

      await _OldServerStore(db).runMigrations();

      expect((await readRaw('legacy-1'))!['emailKey'], 'alice@example.org');
    });

    test('leaves records that already have one alone', () async {
      await store.upsertUser(const AuthenticatedUser(
          id: 'user-1', email: 'bob@example.org', displayName: 'Bob'));

      await store.runMigrations();

      expect((await readRaw('user-1'))!['emailKey'], 'bob@example.org');
    });
  });

  group('the indexes the queries need', () {
    /// Removes every index but `_id`, so that what [MongoAuthStore.ensureIndexes]
    /// declares is what these tests see.
    ///
    /// The test database outlives a run, and an index it created on an
    /// earlier one stays there: without this the assertions below would hold
    /// on any machine that had ever run the build that lacked them.
    Future<void> dropIndexes(String collection) async {
      try {
        await db.executeDbCommand(DbCommand.createQueryDbCommand(
            db, {'dropIndexes': collection, 'index': '*'}));
      } catch (_) {
        // A collection this database has never held has no indexes to drop.
      }
    }

    setUp(() async {
      await dropIndexes(authSessionCollection);
      await dropIndexes(authTokenCollection);
    });

    /// Every field any index on [collection] is keyed by.
    Future<Set<String>> indexedFields(String collection) async {
      var indexes = await db.collection(collection).getIndexes();
      return indexes
          .expand((index) => (index['key'] as Map).keys)
          .whereType<String>()
          .toSet();
    }

    test('cover both range fields the session sweep asks about', () async {
      // The sweep deletes on `expiresAt < now OR lastSeenAt < now - idle`,
      // and MongoDB uses indexes for an `$or` only when every branch has
      // one. A missing index on the second field is therefore not a slower
      // sweep but a full scan of the collection on every tick — and
      // `_liveSessions` filters on it as well, which is every load of the
      // account and administration screens.
      await store.ensureIndexes();

      expect(await indexedFields(authSessionCollection),
          containsAll(<String>['expiresAt', 'lastSeenAt']));
    });

    test('and the address a service token is looked up by', () async {
      // `serviceTokensForEmail` runs on the sign-in path. Answering it by
      // regex meant scanning every token row, revoked ones included, so the
      // cost grew with how often tokens were rotated.
      await store.ensureIndexes();

      expect(await indexedFields(authTokenCollection), contains('emailKey'));
    });
  });

  group('service tokens by address', () {
    /// A row as a build before the folding wrote it: the address exactly as
    /// somebody typed it, and no folded key at all.
    Future<void> seedLegacyServiceToken(String email,
            {String id = 'legacy-tok'}) =>
        db.collection(authTokenCollection).insertOne(<String, dynamic>{
          '_id': id,
          'secretHash': 'hash',
          'kind': TokenKind.service.name,
          'email': email,
          'displayName': 'CI',
          'name': 'legacy ci',
          'createdBy': 'admin-1',
          'createdAt': DateTime.now().toUtc(),
        });

    Future<void> seedServiceToken(String email, {String id = 'tok-1'}) =>
        store.createToken(StoredToken(
          id: id,
          secretHash: 'hash',
          kind: TokenKind.service,
          email: email,
          displayName: 'CI',
          name: 'ci',
          createdBy: 'admin-1',
          createdAt: DateTime.now().toUtc(),
        ));

    test('are matched the way every other address is', () async {
      await seedServiceToken(' CI@Example.org ');

      expect((await store.serviceTokensForEmail('ci@example.org')).single.id,
          'tok-1');
      expect(await store.serviceTokensForEmail('other@example.org'), isEmpty);
    });

    test('and the double agrees', () async {
      var double = MemoryAuthStore();
      await double.createToken(StoredToken(
        id: 'tok-1',
        secretHash: 'hash',
        kind: TokenKind.service,
        email: ' CI@Example.org ',
        displayName: 'CI',
        name: 'ci',
        createdBy: 'admin-1',
        createdAt: DateTime.now().toUtc(),
      ));

      expect((await double.serviceTokensForEmail('ci@example.org')).single.id,
          'tok-1');
      expect(await double.serviceTokensForEmail('other@example.org'), isEmpty);
    });

    test('a revoked one no longer holds the address', () async {
      await seedServiceToken('ci@example.org');
      await store.revokeToken('tok-1', 'no longer needed');

      expect(await store.serviceTokensForEmail('ci@example.org'), isEmpty);
    });

    test('revoking says whether this call is the one that did it', () async {
      // The update is conditional on the row still being live, so a second
      // attempt changes nothing. Answering `void` left the account screen
      // reporting a success that had not happened and writing a revocation
      // into the log that nobody performed.
      await seedServiceToken('ci@example.org');

      expect(await store.revokeToken('tok-1', 'no longer needed'), isTrue);
      expect(await store.revokeToken('tok-1', 'no longer needed'), isFalse);
      expect(await store.revokeToken('tok-absent', 'no longer needed'), isFalse,
          reason: 'nothing was matched, so nothing was revoked');
    });

    test('and the double agrees about that', () async {
      var double = MemoryAuthStore();
      await double.createToken(StoredToken(
        id: 'tok-1',
        secretHash: 'hash',
        kind: TokenKind.service,
        email: 'ci@example.org',
        displayName: 'CI',
        name: 'ci',
        createdBy: 'admin-1',
        createdAt: DateTime.now().toUtc(),
      ));

      expect(await double.revokeToken('tok-1', 'no longer needed'), isTrue);
      expect(await double.revokeToken('tok-1', 'no longer needed'), isFalse);
      expect(
          await double.revokeToken('tok-absent', 'no longer needed'), isFalse);
    });

    test('every one carrying the address is reported, not just the first',
        () async {
      // A deployment that raced, or that predates the check, holds more than
      // one — and an administrator has to be told which they all are.
      await seedServiceToken('ci@example.org', id: 'tok-1');
      await seedServiceToken('CI@example.org', id: 'tok-2');

      expect(
          (await store.serviceTokensForEmail('ci@example.org'))
              .map((t) => t.id),
          unorderedEquals(<String>['tok-1', 'tok-2']));
    });

    test('a row written now carries the folded key the lookup asks for',
        () async {
      // The whole point of the field: without it the lookup falls back to
      // the pattern, which no index can serve.
      await seedServiceToken(' CI@Example.org ');

      expect(
          (await db
              .collection(authTokenCollection)
              .findOne(where.eq('_id', 'tok-1')))!['emailKey'],
          'ci@example.org');
    });

    test('and one written before the folding is still found beside it',
        () async {
      // The indexed key answers for every row this build writes. A row from
      // before it carries none, and reading "no such token" off a missing
      // field is exactly how a second credential for one identity gets
      // issued — so the address itself is still matched, over those rows
      // alone.
      await seedLegacyServiceToken(' CI@Example.org ');
      await seedServiceToken('ci@example.org', id: 'tok-1');

      expect(
          (await store.serviceTokensForEmail('ci@example.org'))
              .map((t) => t.id),
          unorderedEquals(<String>['tok-1', 'legacy-tok']));
      expect(await store.serviceTokensForEmail('other@example.org'), isEmpty);
    });

    test('unless it is revoked, as for any other row', () async {
      await seedLegacyServiceToken('ci@example.org');
      await store.revokeToken('legacy-tok', 'no longer needed');

      expect(await store.serviceTokensForEmail('ci@example.org'), isEmpty);
    });
  });

  group("a user's sessions", () {
    Future<void> seedSession(String id,
        {String userId = 'user-1',
        Duration since = Duration.zero,
        Duration ttl = const Duration(days: 7),
        DateTime? revokedAt}) {
      var now = DateTime.now().toUtc();
      return store.createSession(StoredSession(
        id: id,
        userId: userId,
        secretHash: 'hash',
        rotatedAt: now,
        uaHash: 'ua',
        ip: '10.0.0.1',
        createdAt: now.subtract(since),
        lastSeenAt: now.subtract(since),
        expiresAt: now.add(ttl),
        revokedAt: revokedAt,
      ));
    }

    const idle = Duration(hours: 8);

    test('are the ones the rest of the store also calls live', () async {
      // The listing spelled "live" out itself and left the idle window off,
      // so the account screen re-applied that half in Dart while the
      // administration screen took it from `_liveSessions`. Two screens
      // disagreeing about a session by exactly the window an operator
      // configures.
      await seedSession('fresh');
      await seedSession('idle', since: const Duration(hours: 9));
      await seedSession('expired', ttl: const Duration(days: -1));
      await seedSession('revoked', revokedAt: DateTime.now().toUtc());

      expect((await store.listUserSessions('user-1', idle)).map((s) => s.id),
          ['fresh']);
      expect(await store.liveSessionCounts(idle), {'user-1': 1},
          reason: 'and the administration screen counts the same one');
    });

    test('and the double agrees', () async {
      var double = MemoryAuthStore();
      var now = DateTime.now().toUtc();
      for (var entry in {
        'fresh': Duration.zero,
        'idle': const Duration(hours: 9)
      }.entries) {
        await double.createSession(StoredSession(
          id: entry.key,
          userId: 'user-1',
          secretHash: 'hash',
          rotatedAt: now,
          uaHash: 'ua',
          ip: '10.0.0.1',
          createdAt: now.subtract(entry.value),
          lastSeenAt: now.subtract(entry.value),
          expiresAt: now.add(const Duration(days: 7)),
        ));
      }

      expect((await double.listUserSessions('user-1', idle)).map((s) => s.id),
          ['fresh']);
      expect(await double.liveSessionCounts(idle), {'user-1': 1});
    });
  });
}

/// A store standing in for a server too old for update pipelines, which is
/// the one case a working MongoDB cannot be made to reproduce.
class _OldServerStore extends MongoAuthStore {
  _OldServerStore(super.db);

  @override
  Future<bool> backfillWithPipeline() async => false;
}

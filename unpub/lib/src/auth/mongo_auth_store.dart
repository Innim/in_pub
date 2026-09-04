import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:mongo_dart/mongo_dart.dart';

import 'auth_store.dart';
import 'identity.dart';

final _log = Logger('in_pub.auth.store');

const authUserCollection = 'auth_users';
const authSessionCollection = 'auth_sessions';
const authTokenCollection = 'auth_tokens';

/// Mongo-backed [AuthStore], living in the same database as the package
/// metadata so a deployment still has exactly one datastore to run.
class MongoAuthStore extends AuthStore {
  final Db db;

  MongoAuthStore(this.db);

  DbCollection get _users => db.collection(authUserCollection);
  DbCollection get _sessions => db.collection(authSessionCollection);
  DbCollection get _tokens => db.collection(authTokenCollection);

  @override
  Future<void> ensureIndexes() async {
    // Expiry is enforced by the background sweep rather than a TTL index:
    // the driver version pinned here does not expose `expireAfterSeconds`,
    // and the sweep has to run anyway to apply the idle timeout, which a TTL
    // index cannot express.
    await db.ensureIndex(authSessionCollection, key: 'userId');
    await db.ensureIndex(authSessionCollection, key: 'expiresAt');
    await db.ensureIndex(authTokenCollection, key: 'userId');
    // `listServiceTokens` filters on this, and it is read every time an
    // administrator opens the account screen.
    await db.ensureIndex(authTokenCollection, key: 'kind');
    // Read on every publish that arrives with the legacy credential.
    await db.ensureIndex(authUserCollection, key: 'emailKey');
    // Both are range predicates in the token sweep.
    await db.ensureIndex(authTokenCollection, key: 'expiresAt');
    await db.ensureIndex(authTokenCollection, key: 'revokedAt');
  }

  /// What counts as a live session: not revoked, not expired, and used
  /// recently enough. One builder rather than two copies, because the whole
  /// point of passing `idle` in is that the sweep and the account screen
  /// cannot disagree about it.
  static SelectorBuilder _liveSessions(DateTime now, Duration idle) => where
      .eq('revokedAt', null)
      .gt('expiresAt', now)
      .gt('lastSeenAt', now.subtract(idle));

  @override
  Future<void> runMigrations() async {
    // Never fatal: a server that refuses to start is worse than one whose
    // older records acquire the field on their owner's next sign-in.
    try {
      await _backfillEmailKeys();
    } catch (e) {
      _log.severe('could not backfill emailKey; accounts blocked before this '
          'upgrade may not be matched by address until their owner signs in '
          'again: $e');
    }
  }

  /// Gives records written before `emailKey` existed one.
  ///
  /// The address check matches on that field alone, and a record without it
  /// matches nothing — which now means the credential is refused as
  /// belonging to no account here. Left to acquire the field whenever its
  /// owner next signs in, every existing publisher would be locked out
  /// until they did.
  Future<void> _backfillEmailKeys() async {
    if (await backfillWithPipeline()) return;
    // Update pipelines need a reasonably recent server. Falling back is
    // slower but keeps an older deployment correct, and correctness here
    // means a blocked account stays blocked.
    var pending = await _users
        .find(where.eq('emailKey', null))
        .map(StoredUser.fromJson)
        .toList();
    for (var user in pending) {
      await _users.updateOne(
          where.eq('_id', user.id), modify.set('emailKey', user.emailKey));
    }
    if (pending.isNotEmpty) {
      _log.info('backfilled emailKey on ${pending.length} record(s) one at a '
          'time');
    }
  }

  /// Derives the field on the server in one round trip, and says whether the
  /// server did it.
  ///
  /// The alternative — reading every user and writing each back — sits in
  /// front of the listener, so a large collection makes a restart look like
  /// a hang. Update pipelines need MongoDB 4.2, though, and an older server
  /// does not throw: it answers `ok: 0`, which `updateMany` hands back as a
  /// failed [WriteResult]. Reading only the exception meant the fallback
  /// below never ran on exactly the deployments it exists for — nothing was
  /// backfilled and nothing was logged.
  ///
  /// Overridable so a test can stand in for that older server, which is the
  /// one case a working MongoDB cannot be made to reproduce.
  @visibleForTesting
  Future<bool> backfillWithPipeline() async {
    WriteResult result;
    try {
      result = await _users.updateMany(where.eq('emailKey', null), [
        {
          r'$set': {
            // Trimmed as well as folded: `normalizeAddress` does both, and a
            // key derived by folding alone does not match what every other
            // write of this field stores.
            'emailKey': {
              r'$toLower': {
                r'$trim': {'input': r'$email'}
              }
            }
          }
        }
      ]);
    } catch (e) {
      _log.warning('the server-side emailKey backfill failed: $e');
      return false;
    }
    if (!result.isSuccess) {
      _log.warning('the server rejected the emailKey backfill pipeline '
          '(${result.errmsg ?? result.writeError?.errmsg ?? 'ok: ${result.ok}'})'
          '; falling back '
          'to per-document updates');
      return false;
    }
    return true;
  }

  @override
  Future<StoredUser?> getUser(String id) async {
    var json = await _users.findOne(where.eq('_id', id));
    return json == null ? null : StoredUser.fromJson(json);
  }

  @override
  Future<List<StoredUser>> findUsersByEmail(String email) async {
    if (email.isEmpty) return const [];
    var key = normalizeAddress(email);
    var byKey = await _users
        .find(where.eq('emailKey', key))
        .map(StoredUser.fromJson)
        .toList();

    // The indexed key answers for migrated records. It is not the whole
    // answer: a record written before `emailKey` existed carries none, and
    // reading "no such record" off a missing field is how a blocked account
    // would have got its old credential accepted again. The startup backfill
    // is meant to remove them all and may have failed; correctness must not
    // rest on it having run, so the address itself is checked as well.
    //
    // Both, rather than the second only when the first came back empty. An
    // address is not unique here — that is why this answers with a list —
    // and stopping at the indexed hit meant one migrated record hid every
    // unmigrated one beside it. Two identities sharing an address, one
    // blocked before the upgrade and never seen since, the other active and
    // migrated: only the active one was returned, only it was checked, and
    // the blocked person went on publishing with their legacy credential.
    // Which is the outcome this method exists to prevent.
    //
    // The second query is restricted to records that actually lack the
    // field. A case-insensitive regex cannot use an index, and this now runs
    // on every lookup rather than only on a miss. `emailKey: null` is an
    // indexed predicate, so the scan is over the unmigrated records rather
    // than the whole collection, and is empty once the backfill has run.
    var unmigrated = await _users
        .find(where
            .eq('emailKey', null)
            .match('email', storedAddressPattern(email), caseInsensitive: true))
        .map(StoredUser.fromJson)
        .toList();

    // By `_id`, because the two predicates are disjoint only as long as
    // nothing writes an `emailKey` between the queries — a sign-in or the
    // backfill landing in that window would otherwise report one person
    // twice, and the caller reads this as a list of distinct identities.
    var found = <String, StoredUser>{for (var user in byKey) user.id: user};
    for (var user in unmigrated) {
      found.putIfAbsent(user.id, () => user);
    }
    return found.values.toList();
  }

  @override
  Future<StoredUser> upsertUser(
    AuthenticatedUser user, {
    String? refreshTokenEnc,
    DateTime? validatedAt,
  }) async {
    var now = DateTime.now();
    var update = modify
        .set('displayName', user.displayName)
        .set('groups', user.groups)
        .set('validationFailures', 0)
        .set('updatedAt', now)
        .setOnInsert('createdAt', now)
        .setOnInsert('status', UserStatus.active.name);
    // Blank counts as absent, the same rule [recordValidation] applies and
    // for the same reason: a provider that stops sending the `email` claim
    // answers with an empty one on every sign-in too, and writing it here
    // clears the address and the folded key together. That instantly refuses
    // every personal token the account holds — `looksLikeEmailAddress('')` is
    // false — and takes the record out of `findUsersByEmail`, so a *blocked*
    // publisher's legacy Google credential reads as belonging to no account
    // here and is admitted as provisional. A record being created still gets
    // the field, so it is shaped like every other one and the startup
    // backfill has something to fold.
    if (user.email.trim().isEmpty) {
      update = update.setOnInsert('email', '').setOnInsert('emailKey', '');
    } else {
      update = update
          .set('email', user.email)
          .set('emailKey', normalizeAddress(user.email));
    }
    if (refreshTokenEnc != null) {
      update = update.set('refreshTokenEnc', refreshTokenEnc);
    }
    if (validatedAt != null) {
      update = update.set('lastValidatedAt', validatedAt);
    }

    await _users.updateOne(where.eq('_id', user.id), update, upsert: true);
    var stored = await getUser(user.id);
    if (stored == null) {
      throw StateError('failed to persist user ${user.id}');
    }
    return stored;
  }

  @override
  Future<void> setUserStatus(String id, UserStatus status,
      {String? reason}) async {
    // For the two states that expect to be confirmed again — the provider
    // withdrew access, or there is nothing left to check with — the refresh
    // token stays. It is encrypted, the account is refused on its status
    // regardless, and it is the only thing that can vouch for the account
    // again; discarding it made unblocking impossible, since the next check
    // found nothing to ask with and re-blocked the account.
    //
    // A local block is different. It is an administrator's decision, it may
    // stand for years, and nothing ever removes the row — so keeping a
    // usable provider credential for somebody who has left is a liability in
    // every database backup. Unblocking them asks them to sign in again,
    // which is a fair price.
    var update = modify
        .set('status', status.name)
        .set('blockedReason', reason)
        .set('updatedAt', DateTime.now());
    if (status == UserStatus.blockedLocal) {
      update = update.set('refreshTokenEnc', null);
    }
    await _users.updateOne(where.eq('_id', id), update);
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
    var update = modify.set('updatedAt', DateTime.now());
    if (validatedAt != null)
      update = update.set('lastValidatedAt', validatedAt);
    if (failures != null) update = update.set('validationFailures', failures);
    if (refreshTokenEnc != null) {
      update = update.set('refreshTokenEnc', refreshTokenEnc);
    }
    if (groups != null) update = update.set('groups', groups);
    // Blank counts as absent. A provider that stops sending the `email`
    // claim answers with an empty one, and writing that here clears both the
    // address and the folded key the address checks match on.
    if (email != null && email.trim().isNotEmpty) {
      // `normalizeAddress`, not a bare fold: userinfo does not trim, and a
      // provider answering `"alice@example.org "` would otherwise have the
      // sweep overwrite a correctly folded key with an untrimmed one. The
      // address check matches on this field, so from then on it finds
      // nothing — and a blocked publisher's legacy credential reads as
      // belonging to no account here, which is the one case that is
      // accepted.
      update =
          update.set('email', email).set('emailKey', normalizeAddress(email));
    }
    if (displayName != null) update = update.set('displayName', displayName);
    await _users.updateOne(where.eq('_id', id), update);
  }

  @override
  Future<List<StoredUser>> usersWithLiveSessions(Duration idle) async {
    var now = DateTime.now();
    var ids = await _sessions
        .find(_liveSessions(now, idle))
        .map((json) => json['userId'] as String)
        .toSet();
    if (ids.isEmpty) return const [];
    return _users
        .find(where.oneFrom('_id', ids.toList()))
        .map(StoredUser.fromJson)
        .toList();
  }

  @override
  Future<List<StoredUser>> listUsers({int limit = 200}) => _users
      .find(where.sortBy('updatedAt', descending: true).limit(limit))
      .map(StoredUser.fromJson)
      .toList();

  @override
  Future<Map<String, int>> liveSessionCounts(Duration idle) async {
    var now = DateTime.now();
    var counts = <String, int>{};
    await _sessions.find(_liveSessions(now, idle)).forEach((json) {
      var userId = json['userId'] as String;
      counts[userId] = (counts[userId] ?? 0) + 1;
    });
    return counts;
  }

  @override
  Future<void> createSession(StoredSession session) async {
    await _sessions.insertOne(session.toJson());
  }

  @override
  Future<StoredSession?> getSession(String id) async {
    var json = await _sessions.findOne(where.eq('_id', id));
    return json == null ? null : StoredSession.fromJson(json);
  }

  @override
  Future<bool> rotateSession(
    String id, {
    required String expectedSecretHash,
    required String newSecretHash,
    required String prevSecretHash,
    required DateTime prevValidUntil,
    required DateTime rotatedAt,
  }) async {
    // Conditional on the secret we read, so two requests racing to rotate
    // produce one winner rather than two chained rotations that would
    // invalidate each other's cookie.
    var result = await _sessions.updateOne(
        where.eq('_id', id).eq('secretHash', expectedSecretHash),
        modify
            .set('secretHash', newSecretHash)
            .set('prevSecretHash', prevSecretHash)
            .set('prevValidUntil', prevValidUntil)
            .set('currentSecretSeen', false)
            .set('rotatedAt', rotatedAt));
    return result.nModified == 1;
  }

  @override
  Future<void> confirmSecretSeen(String id, String secretHash) async {
    // Conditional on the secret still being current: a rotation that landed
    // between our read and this write must not have its fresh previous-secret
    // record wiped by a late confirmation of the older one.
    await _sessions.updateOne(
        where.eq('_id', id).eq('secretHash', secretHash),
        modify
            .set('currentSecretSeen', true)
            .set('prevSecretHash', null)
            .set('prevValidUntil', null));
  }

  @override
  Future<void> touchSession(String id, DateTime lastSeenAt,
      {String? ip, List<String>? ipHistory}) async {
    var update = modify.set('lastSeenAt', lastSeenAt);
    if (ip != null) update = update.set('ip', ip);
    if (ipHistory != null) update = update.set('ipHistory', ipHistory);
    await _sessions.updateOne(where.eq('_id', id), update);
  }

  @override
  Future<bool> revokeSession(String id, String reason) async {
    var result = await _sessions.updateOne(
        where.eq('_id', id).eq('revokedAt', null),
        modify
            .set('revokedAt', DateTime.now())
            .set('revokedReason', reason)
            // The secrets are dead weight once revoked, and holding them
            // serves no purpose the audit fields do not already serve.
            .set('secretHash', '')
            .set('prevSecretHash', null));
    return result.nModified == 1;
  }

  @override
  Future<int> revokeUserSessions(String userId, String reason,
      {String? exceptSessionId}) async {
    var selector = where.eq('userId', userId).eq('revokedAt', null);
    if (exceptSessionId != null) {
      selector = selector.ne('_id', exceptSessionId);
    }
    var result = await _sessions.updateMany(
        selector,
        modify
            .set('revokedAt', DateTime.now())
            .set('revokedReason', reason)
            .set('secretHash', '')
            .set('prevSecretHash', null));
    return result.nModified;
  }

  @override
  Future<List<StoredSession>> listUserSessions(String userId) {
    // Live rows only, decided by the query. The account screen dropped the
    // revoked and expired ones in Dart afterwards, so every load shipped
    // every session the user had ever held that the sweep had not yet caught
    // — which for somebody signing in and out repeatedly is the whole
    // `sessionTtl` window. The same treatment the token listings got.
    var now = DateTime.now();
    return _sessions
        .find(where
            .eq('userId', userId)
            .eq('revokedAt', null)
            .gt('expiresAt', now)
            .sortBy('lastSeenAt', descending: true)
            .limit(sessionListLimit))
        .map(StoredSession.fromJson)
        .toList();
  }

  /// A backstop rather than paging: the account screen renders these whole,
  /// and nobody legitimately holds this many at once.
  ///
  /// Public so the in-memory double used by the tests can truncate at the
  /// same point instead of carrying a second copy of the number.
  static const sessionListLimit = 200;

  @override
  Future<int> purgeExpiredSessions(Duration idle) async {
    var now = DateTime.now();
    var result = await _sessions.deleteMany(where
        .lt('expiresAt', now)
        .or(where.lt('lastSeenAt', now.subtract(idle))));
    return result.nRemoved;
  }

  @override
  Future<void> createToken(StoredToken token) async {
    await _tokens.insertOne(token.toJson());
  }

  @override
  Future<StoredToken?> getToken(String id) async {
    var json = await _tokens.findOne(where.eq('_id', id));
    return json == null ? null : StoredToken.fromJson(json);
  }

  @override
  Future<void> touchToken(String id, DateTime usedAt, {String? ip}) async {
    var update = modify.set('lastUsedAt', usedAt);
    if (ip != null && ip.isNotEmpty) update = update.set('lastUsedIp', ip);
    await _tokens.updateOne(where.eq('_id', id), update);
  }

  @override
  Future<bool> revokeToken(String id, String reason) async {
    var result = await _tokens.updateOne(
        where.eq('_id', id).eq('revokedAt', null),
        modify.set('revokedAt', DateTime.now()).set('revokedReason', reason));
    return result.nModified == 1;
  }

  @override
  Future<List<StoredToken>> listTokensOfUser(String userId) =>
      _live(where.eq('userId', userId));

  @override
  Future<List<StoredToken>> listServiceTokens() =>
      _live(where.eq('kind', TokenKind.service.name));

  /// Deliberately uncapped, unlike [_live]. This answer decides whether a
  /// second credential may be issued for an identity, and a decision has no
  /// business being trimmed to fit a screen: a deployment holding more rows
  /// for one address than the listing shows is exactly the one where the
  /// duplicate has already happened.
  @override
  Future<List<StoredToken>> serviceTokensForEmail(String email) => _tokens
      .find(_stillLive(where
          .eq('kind', TokenKind.service.name)
          .match('email', storedAddressPattern(email), caseInsensitive: true)))
      .map(StoredToken.fromJson)
      .toList();

  /// Narrows [selector] to tokens still worth having: neither revoked nor
  /// expired.
  ///
  /// The predicate belongs in the query. Every caller dropped the dead rows
  /// in Dart afterwards, so a fleet that rotates service tokens shipped its
  /// whole history to the process on each account-page load — and the sweep
  /// only removes rows past `tokenRetention`, so recently revoked ones stay.
  static SelectorBuilder _stillLive(SelectorBuilder selector) =>
      selector.eq('revokedAt', null).and(where
          .eq('expiresAt', null)
          .or(where.gt('expiresAt', DateTime.now())));

  /// A listing for a screen that renders what it is handed, newest first.
  Future<List<StoredToken>> _live(SelectorBuilder selector) => _tokens
      .find(_stillLive(selector)
          .sortBy('createdAt', descending: true)
          .limit(tokenListLimit))
      .map(StoredToken.fromJson)
      .toList();

  /// Far above any real fleet, and a backstop rather than paging: these
  /// lists are rendered whole. Public for the same reason as
  /// [sessionListLimit].
  static const tokenListLimit = 500;

  @override
  Future<int> purgeDeadTokens(Duration keepRevoked) async {
    var now = DateTime.now();
    var cutoff = now.subtract(keepRevoked);
    var result = await _tokens.deleteMany(
        where.lt('expiresAt', cutoff).or(where.lt('revokedAt', cutoff)));
    return result.nRemoved;
  }
}

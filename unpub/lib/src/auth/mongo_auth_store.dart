import 'package:mongo_dart/mongo_dart.dart';

import 'auth_store.dart';
import 'identity.dart';

const authUserCollection = 'auth_users';
const authSessionCollection = 'auth_sessions';

/// Mongo-backed [AuthStore], living in the same database as the package
/// metadata so a deployment still has exactly one datastore to run.
class MongoAuthStore extends AuthStore {
  final Db db;

  MongoAuthStore(this.db);

  DbCollection get _users => db.collection(authUserCollection);
  DbCollection get _sessions => db.collection(authSessionCollection);

  @override
  Future<void> ensureIndexes() async {
    // Expiry is enforced by the background sweep rather than a TTL index:
    // the driver version pinned here does not expose `expireAfterSeconds`,
    // and the sweep has to run anyway to apply the idle timeout, which a TTL
    // index cannot express.
    await db.ensureIndex(authSessionCollection, key: 'userId');
    await db.ensureIndex(authSessionCollection, key: 'expiresAt');
  }

  @override
  Future<StoredUser?> getUser(String id) async {
    var json = await _users.findOne(where.eq('_id', id));
    return json == null ? null : StoredUser.fromJson(json);
  }

  @override
  Future<StoredUser> upsertUser(
    AuthenticatedUser user, {
    String? refreshTokenEnc,
    DateTime? validatedAt,
  }) async {
    var now = DateTime.now();
    var update = modify
        .set('email', user.email)
        .set('displayName', user.displayName)
        .set('groups', user.groups)
        .set('validationFailures', 0)
        .set('updatedAt', now)
        .setOnInsert('createdAt', now)
        .setOnInsert('status', UserStatus.active.name);
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
    var update = modify
        .set('status', status.name)
        .set('blockedReason', reason)
        .set('updatedAt', DateTime.now());
    // A blocked user's refresh token is useless to us and is one more secret
    // to keep, so it goes when they do.
    if (status != UserStatus.active) {
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
    if (email != null) update = update.set('email', email);
    if (displayName != null) update = update.set('displayName', displayName);
    await _users.updateOne(where.eq('_id', id), update);
  }

  @override
  Future<List<StoredUser>> usersWithLiveSessions() async {
    var now = DateTime.now();
    var ids = await _sessions
        .find(where.eq('revokedAt', null).gt('expiresAt', now))
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
  Future<Map<String, int>> liveSessionCounts() async {
    var now = DateTime.now();
    var counts = <String, int>{};
    await _sessions
        .find(where.eq('revokedAt', null).gt('expiresAt', now))
        .forEach((json) {
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
  Future<void> revokeSession(String id, String reason) async {
    await _sessions.updateOne(
        where.eq('_id', id).eq('revokedAt', null),
        modify
            .set('revokedAt', DateTime.now())
            .set('revokedReason', reason)
            // The secrets are dead weight once revoked, and holding them
            // serves no purpose the audit fields do not already serve.
            .set('secretHash', '')
            .set('prevSecretHash', null));
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
  Future<List<StoredSession>> listUserSessions(String userId) => _sessions
      .find(where.eq('userId', userId).sortBy('lastSeenAt', descending: true))
      .map(StoredSession.fromJson)
      .toList();

  @override
  Future<int> purgeExpiredSessions(Duration idle) async {
    var now = DateTime.now();
    var result = await _sessions.deleteMany(where
        .lt('expiresAt', now)
        .or(where.lt('lastSeenAt', now.subtract(idle))));
    return result.nRemoved;
  }
}

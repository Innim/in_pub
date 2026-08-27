import 'package:in_pub/src/auth/auth_store.dart';
import 'package:in_pub/src/auth/identity.dart';

/// In-memory [AuthStore] for tests, with the same compare-and-set semantics
/// as the Mongo implementation.
class MemoryAuthStore extends AuthStore {
  final users = <String, StoredUser>{};
  final sessions = <String, StoredSession>{};

  @override
  Future<void> ensureIndexes() async {}

  @override
  Future<StoredUser?> getUser(String id) async => users[id];

  @override
  Future<StoredUser> upsertUser(
    AuthenticatedUser user, {
    String? refreshTokenEnc,
    DateTime? validatedAt,
  }) async {
    var now = DateTime.now();
    var existing = users[user.id];
    var stored = StoredUser(
      id: user.id,
      email: user.email,
      displayName: user.displayName,
      groups: user.groups,
      status: existing?.status ?? UserStatus.active,
      blockedReason: existing?.blockedReason,
      refreshTokenEnc: refreshTokenEnc ?? existing?.refreshTokenEnc,
      lastValidatedAt: validatedAt ?? existing?.lastValidatedAt,
      validationFailures: 0,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );
    users[user.id] = stored;
    return stored;
  }

  @override
  Future<void> setUserStatus(String id, UserStatus status,
      {String? reason}) async {
    var user = users[id];
    if (user == null) return;
    users[id] = _copyUser(user,
        status: status,
        blockedReason: reason,
        refreshTokenEnc:
            status == UserStatus.active ? user.refreshTokenEnc : null,
        clearRefreshToken: status != UserStatus.active);
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
    var user = users[id];
    if (user == null) return;
    users[id] = _copyUser(user,
        lastValidatedAt: validatedAt ?? user.lastValidatedAt,
        validationFailures: failures ?? user.validationFailures,
        refreshTokenEnc: refreshTokenEnc ?? user.refreshTokenEnc,
        groups: groups ?? user.groups,
        email: email ?? user.email,
        displayName: displayName ?? user.displayName);
  }

  @override
  Future<List<StoredUser>> usersWithLiveSessions() async {
    var now = DateTime.now();
    var ids = sessions.values
        .where((s) => !s.isRevoked && s.expiresAt.isAfter(now))
        .map((s) => s.userId)
        .toSet();
    return ids.map((id) => users[id]).whereType<StoredUser>().toList();
  }

  @override
  Future<List<StoredUser>> listUsers({int limit = 200}) async =>
      users.values.take(limit).toList();

  @override
  Future<Map<String, int>> liveSessionCounts() async {
    var now = DateTime.now();
    var counts = <String, int>{};
    for (var session in sessions.values) {
      if (session.isRevoked || !session.expiresAt.isAfter(now)) continue;
      counts[session.userId] = (counts[session.userId] ?? 0) + 1;
    }
    return counts;
  }

  @override
  Future<void> createSession(StoredSession session) async {
    sessions[session.id] = session;
  }

  @override
  Future<StoredSession?> getSession(String id) async => sessions[id];

  @override
  Future<bool> rotateSession(
    String id, {
    required String expectedSecretHash,
    required String newSecretHash,
    required String prevSecretHash,
    required DateTime prevValidUntil,
    required DateTime rotatedAt,
  }) async {
    var session = sessions[id];
    if (session == null || session.secretHash != expectedSecretHash) {
      return false;
    }
    sessions[id] = _copySession(session,
        secretHash: newSecretHash,
        prevSecretHash: prevSecretHash,
        prevValidUntil: prevValidUntil,
        currentSecretSeen: false,
        rotatedAt: rotatedAt);
    return true;
  }

  @override
  Future<void> confirmSecretSeen(String id, String secretHash) async {
    var session = sessions[id];
    if (session == null || session.secretHash != secretHash) return;
    sessions[id] = _copySession(session,
        currentSecretSeen: true,
        prevSecretHash: null,
        prevValidUntil: null,
        clearPrevious: true);
  }

  @override
  Future<void> touchSession(String id, DateTime lastSeenAt,
      {String? ip, List<String>? ipHistory}) async {
    var session = sessions[id];
    if (session == null) return;
    sessions[id] = _copySession(session,
        lastSeenAt: lastSeenAt,
        ip: ip ?? session.ip,
        ipHistory: ipHistory ?? session.ipHistory);
  }

  @override
  Future<void> revokeSession(String id, String reason) async {
    var session = sessions[id];
    if (session == null || session.isRevoked) return;
    sessions[id] = _copySession(session,
        revokedAt: DateTime.now(),
        revokedReason: reason,
        secretHash: '',
        prevSecretHash: null,
        clearPrevious: true);
  }

  @override
  Future<int> revokeUserSessions(String userId, String reason,
      {String? exceptSessionId}) async {
    var count = 0;
    for (var session in sessions.values.toList()) {
      if (session.userId != userId ||
          session.isRevoked ||
          session.id == exceptSessionId) {
        continue;
      }
      await revokeSession(session.id, reason);
      count++;
    }
    return count;
  }

  @override
  Future<List<StoredSession>> listUserSessions(String userId) async =>
      sessions.values.where((s) => s.userId == userId).toList();

  @override
  Future<int> purgeExpiredSessions(Duration idle) async {
    var now = DateTime.now();
    var doomed = sessions.values
        .where((s) =>
            now.isAfter(s.expiresAt) || now.difference(s.lastSeenAt) > idle)
        .map((s) => s.id)
        .toList();
    for (var id in doomed) {
      sessions.remove(id);
    }
    return doomed.length;
  }

  StoredUser _copyUser(
    StoredUser user, {
    UserStatus? status,
    String? blockedReason,
    String? refreshTokenEnc,
    bool clearRefreshToken = false,
    DateTime? lastValidatedAt,
    int? validationFailures,
    List<String>? groups,
    String? email,
    String? displayName,
  }) =>
      StoredUser(
        id: user.id,
        email: email ?? user.email,
        displayName: displayName ?? user.displayName,
        groups: groups ?? user.groups,
        status: status ?? user.status,
        blockedReason: blockedReason ?? user.blockedReason,
        refreshTokenEnc:
            clearRefreshToken ? null : refreshTokenEnc ?? user.refreshTokenEnc,
        lastValidatedAt: lastValidatedAt ?? user.lastValidatedAt,
        validationFailures: validationFailures ?? user.validationFailures,
        createdAt: user.createdAt,
        updatedAt: DateTime.now(),
      );

  StoredSession _copySession(
    StoredSession session, {
    String? secretHash,
    String? prevSecretHash,
    DateTime? prevValidUntil,
    bool clearPrevious = false,
    bool? currentSecretSeen,
    DateTime? rotatedAt,
    String? ip,
    List<String>? ipHistory,
    DateTime? lastSeenAt,
    DateTime? revokedAt,
    String? revokedReason,
  }) =>
      StoredSession(
        id: session.id,
        userId: session.userId,
        secretHash: secretHash ?? session.secretHash,
        prevSecretHash:
            clearPrevious ? null : prevSecretHash ?? session.prevSecretHash,
        prevValidUntil:
            clearPrevious ? null : prevValidUntil ?? session.prevValidUntil,
        currentSecretSeen: currentSecretSeen ?? session.currentSecretSeen,
        rotatedAt: rotatedAt ?? session.rotatedAt,
        uaHash: session.uaHash,
        ip: ip ?? session.ip,
        ipHistory: ipHistory ?? session.ipHistory,
        createdAt: session.createdAt,
        lastSeenAt: lastSeenAt ?? session.lastSeenAt,
        expiresAt: session.expiresAt,
        revokedAt: revokedAt ?? session.revokedAt,
        revokedReason: revokedReason ?? session.revokedReason,
        idToken: session.idToken,
      );
}

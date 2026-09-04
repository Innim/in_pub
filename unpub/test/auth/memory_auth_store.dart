import 'package:in_pub/src/auth/auth_store.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:in_pub/src/auth/mongo_auth_store.dart';

/// In-memory [AuthStore] for tests, with the same compare-and-set semantics
/// as the Mongo implementation.
class MemoryAuthStore extends AuthStore {
  final users = <String, StoredUser>{};
  final sessions = <String, StoredSession>{};
  final tokens = <String, StoredToken>{};

  @override
  Future<void> ensureIndexes() async {}

  @override
  Future<StoredUser?> getUser(String id) async => users[id];

  @override
  Future<List<StoredUser>> findUsersByEmail(String email) async {
    if (email.isEmpty) return const [];
    // `normalizeAddress`, the same rule the Mongo store folds the stored key
    // with. A bare `toLowerCase` here made the double answer for
    // `'alice@example.org '` where production does not, so the whole class of
    // untrimmed-address bugs was invisible to every test that used it.
    var wanted = normalizeAddress(email);
    return users.values.where((u) => u.emailKey == wanted).toList();
  }

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
      // Blank counts as absent, exactly as `MongoAuthStore` has it. A double
      // that let an empty claim overwrite a good address would hide the bug
      // the guard there exists for: the record drops out of every address
      // lookup, so a blocked publisher's legacy credential reads as belonging
      // to nobody here.
      email: user.email.trim().isEmpty ? (existing?.email ?? '') : user.email,
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
    // The Mongo store writes `blockedReason` unconditionally, so a null
    // clears it — which is what unblocking relies on. Keeping the old reason
    // here made every test of that path assert behaviour the real store does
    // not have.
    // Same rule as the Mongo store: a local block discards the provider
    // credential, the other states keep it so the account can be confirmed
    // again. Test doubles drifting from the real store have bitten this
    // branch more than once.
    users[id] = _copyUser(user,
        status: status,
        blockedReason: reason,
        clearBlockedReason: reason == null,
        clearRefreshToken: status == UserStatus.blockedLocal);
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
        // Blank counts as absent, exactly as `MongoAuthStore` has it: a
        // double that accepted an empty address would hide the very bug the
        // guard there exists for.
        email: (email == null || email.trim().isEmpty) ? user.email : email,
        displayName: displayName ?? user.displayName);
  }

  @override
  Future<List<StoredUser>> usersWithLiveSessions(Duration idle) async {
    var now = DateTime.now();
    var ids = sessions.values
        .where((s) => !s.isRevoked && !s.isExpired(now, idle))
        .map((s) => s.userId)
        .toSet();
    return ids.map((id) => users[id]).whereType<StoredUser>().toList();
  }

  @override
  Future<List<StoredUser>> listUsers({int limit = 200}) async {
    // Newest first, as Mongo sorts them. The administration screen renders
    // the order it receives and the list is capped, so insertion order here
    // would show a different set of people than production does.
    var all = users.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return all.take(limit).toList();
  }

  @override
  Future<Map<String, int>> liveSessionCounts(Duration idle) async {
    var now = DateTime.now();
    var counts = <String, int>{};
    for (var session in sessions.values) {
      if (session.isRevoked || session.isExpired(now, idle)) continue;
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
  Future<bool> revokeSession(String id, String reason) async {
    var session = sessions[id];
    // Conditional on the row still being live, and reported, exactly as the
    // Mongo update is — the same drift that let a second token revocation
    // report a success nobody performed.
    if (session == null || session.isRevoked) return false;
    sessions[id] = _copySession(session,
        revokedAt: DateTime.now(),
        revokedReason: reason,
        secretHash: '',
        prevSecretHash: null,
        clearPrevious: true);
    return true;
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
      if (await revokeSession(session.id, reason)) count++;
    }
    return count;
  }

  @override
  Future<List<StoredSession>> listUserSessions(String userId) async {
    // Live rows only, newest first and capped, as the Mongo query returns
    // them. The cap is borrowed from that store rather than re-typed: a
    // number written out twice is the drift this double keeps producing.
    var now = DateTime.now();
    var live = sessions.values
        .where((s) =>
            s.userId == userId && !s.isRevoked && s.expiresAt.isAfter(now))
        .toList()
      ..sort((a, b) => b.lastSeenAt.compareTo(a.lastSeenAt));
    return live.take(MongoAuthStore.sessionListLimit).toList();
  }

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
    bool clearBlockedReason = false,
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
        blockedReason:
            clearBlockedReason ? null : blockedReason ?? user.blockedReason,
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

  @override
  Future<void> createToken(StoredToken token) async {
    tokens[token.id] = token;
  }

  @override
  Future<StoredToken?> getToken(String id) async => tokens[id];

  @override
  Future<void> touchToken(String id, DateTime usedAt, {String? ip}) async {
    var token = tokens[id];
    if (token == null) return;
    // Guarded like the Mongo one: `clientIp` answers '' when there is no
    // connection information, and letting that overwrite a real address
    // would make the double disagree with production.
    tokens[id] = _copyToken(token,
        lastUsedAt: usedAt, lastUsedIp: (ip?.isEmpty ?? true) ? null : ip);
  }

  @override
  Future<bool> revokeToken(String id, String reason) async {
    var token = tokens[id];
    // Conditional on the row still being live, and reported, exactly as the
    // Mongo update is: a double that always said "yes, I revoked it" would
    // hide a second revocation being answered as a success.
    if (token == null || token.isRevoked) return false;
    tokens[id] =
        _copyToken(token, revokedAt: DateTime.now(), revokedReason: reason);
    return true;
  }

  @override
  Future<List<StoredToken>> listTokensOfUser(String userId) async =>
      _newestFirst(_live.where((t) => t.userId == userId));

  @override
  Future<List<StoredToken>> listServiceTokens() async =>
      _newestFirst(_live.where((t) => t.kind == TokenKind.service));

  @override
  Future<List<StoredToken>> serviceTokensForEmail(String email) async {
    // Uncapped, as the Mongo query is: this answer decides whether a second
    // credential may be issued for an identity, and a cap would drop the
    // older token that should have stopped it.
    var wanted = normalizeAddress(email);
    return _live
        .where((t) =>
            t.kind == TokenKind.service && normalizeAddress(t.email) == wanted)
        .toList();
  }

  /// The Mongo store drops revoked and expired rows in the query, so the
  /// double has to as well — a caller that filters afterwards would pass
  /// here and read history in production.
  Iterable<StoredToken> get _live {
    var now = DateTime.now();
    return tokens.values.where((t) => t.isUsable(now));
  }

  /// Mongo sorts these newest-first and caps them, and the account screen
  /// renders them in the order it receives them — so the double has to do
  /// the same or that ordering, and that truncation, are production
  /// behaviour no test can check.
  static List<StoredToken> _newestFirst(Iterable<StoredToken> tokens) {
    var sorted = tokens.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sorted.take(MongoAuthStore.tokenListLimit).toList();
  }

  StoredToken _copyToken(
    StoredToken token, {
    String? secretHash,
    DateTime? lastUsedAt,
    String? lastUsedIp,
    DateTime? revokedAt,
    String? revokedReason,
  }) =>
      StoredToken(
        id: token.id,
        secretHash: secretHash ?? token.secretHash,
        kind: token.kind,
        userId: token.userId,
        email: token.email,
        displayName: token.displayName,
        name: token.name,
        createdBy: token.createdBy,
        createdAt: token.createdAt,
        expiresAt: token.expiresAt,
        lastUsedAt: lastUsedAt ?? token.lastUsedAt,
        lastUsedIp: lastUsedIp ?? token.lastUsedIp,
        revokedAt: revokedAt ?? token.revokedAt,
        revokedReason: revokedReason ?? token.revokedReason,
      );

  @override
  Future<int> purgeDeadTokens(Duration keepRevoked) async {
    var now = DateTime.now();
    var doomed = tokens.values
        .where((t) =>
            (t.expiresAt != null &&
                now.difference(t.expiresAt!) > keepRevoked) ||
            (t.revokedAt != null && now.difference(t.revokedAt!) > keepRevoked))
        .map((t) => t.id)
        .toList();
    for (var id in doomed) {
      tokens.remove(id);
    }
    return doomed.length;
  }
}

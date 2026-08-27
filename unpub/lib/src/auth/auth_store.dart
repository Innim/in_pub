import 'identity.dart';

/// Why a user is currently denied access.
enum UserStatus {
  active,

  /// Blocked from this server by an administrator here. Survives the user
  /// still being perfectly fine on the identity provider.
  blockedLocal,

  /// The identity provider stopped vouching for them — account disabled or
  /// deleted, or they lost the group membership that granted access.
  blockedUpstream,
}

/// A user as this server remembers them between requests.
class StoredUser {
  /// OIDC `sub`. Stable across email and display name changes.
  final String id;
  final String email;
  final String displayName;
  final List<String> groups;
  final UserStatus status;
  final String? blockedReason;

  /// Refresh token, encrypted. Null once it has been spent or rejected, in
  /// which case the user must log in again.
  final String? refreshTokenEnc;

  /// When the provider last confirmed this account. Drives revalidation.
  final DateTime? lastValidatedAt;

  /// Consecutive transport-level failures while revalidating. Reset on the
  /// first success; never on its own a reason to block.
  final int validationFailures;

  final DateTime createdAt;
  final DateTime updatedAt;

  const StoredUser({
    required this.id,
    required this.email,
    required this.displayName,
    required this.groups,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.blockedReason,
    this.refreshTokenEnc,
    this.lastValidatedAt,
    this.validationFailures = 0,
  });

  bool get isActive => status == UserStatus.active;

  AuthenticatedUser toAuthenticatedUser() => AuthenticatedUser(
      id: id, email: email, displayName: displayName, groups: groups);

  Map<String, dynamic> toJson() => {
        '_id': id,
        'email': email,
        'displayName': displayName,
        'groups': groups,
        'status': status.name,
        'blockedReason': blockedReason,
        'refreshTokenEnc': refreshTokenEnc,
        'lastValidatedAt': lastValidatedAt,
        'validationFailures': validationFailures,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
      };

  static StoredUser fromJson(Map<String, dynamic> json) => StoredUser(
        id: json['_id'] as String,
        email: json['email'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        groups:
            (json['groups'] as List?)?.whereType<String>().toList() ?? const [],
        status: UserStatus.values.firstWhere((s) => s.name == json['status'],
            orElse: () => UserStatus.active),
        blockedReason: json['blockedReason'] as String?,
        refreshTokenEnc: json['refreshTokenEnc'] as String?,
        lastValidatedAt: json['lastValidatedAt'] as DateTime?,
        validationFailures: (json['validationFailures'] as num?)?.toInt() ?? 0,
        createdAt: json['createdAt'] as DateTime? ?? DateTime.now(),
        updatedAt: json['updatedAt'] as DateTime? ?? DateTime.now(),
      );
}

/// One browser session.
///
/// The cookie handed to the browser is `<id>.<secret>`; only a hash of the
/// secret is stored, so a leaked database cannot be turned into a working
/// cookie.
class StoredSession {
  final String id;
  final String userId;

  final String secretHash;

  /// The secret this session used before the last rotation, and the instant
  /// it stops being accepted at the latest.
  ///
  /// It is kept because a client can miss a `Set-Cookie` — an aborted fetch,
  /// a cancelled navigation — and legitimately come back still holding the
  /// old value. Such a client is not a clone and must not be locked out.
  final String? prevSecretHash;
  final DateTime? prevValidUntil;

  /// Whether anyone has yet presented the *current* secret.
  ///
  /// This is what separates a client that missed a cookie update from a
  /// stolen cookie. While it is false, nobody is known to hold the new
  /// secret, so a request bearing the old one is just a client catching up.
  /// Once it flips to true the previous secret is dropped, and a request
  /// still carrying it proves two different clients hold this session.
  final bool currentSecretSeen;

  final DateTime rotatedAt;

  /// Hash of the User-Agent this session was created with. A mismatch means
  /// the cookie moved to a different client.
  final String uaHash;

  final String ip;

  /// Addresses this session has been used from, newest last. Kept for the
  /// session list and for after-the-fact investigation.
  final List<String> ipHistory;

  final DateTime createdAt;
  final DateTime lastSeenAt;
  final DateTime expiresAt;
  final DateTime? revokedAt;
  final String? revokedReason;

  /// Kept only to pass as `id_token_hint` when signing the user out of the
  /// provider.
  final String? idToken;

  const StoredSession({
    required this.id,
    required this.userId,
    required this.secretHash,
    required this.rotatedAt,
    required this.uaHash,
    required this.ip,
    required this.createdAt,
    required this.lastSeenAt,
    required this.expiresAt,
    this.prevSecretHash,
    this.prevValidUntil,
    this.currentSecretSeen = true,
    this.ipHistory = const [],
    this.revokedAt,
    this.revokedReason,
    this.idToken,
  });

  bool get isRevoked => revokedAt != null;

  bool isExpired(DateTime now, Duration idle) =>
      now.isAfter(expiresAt) || now.difference(lastSeenAt) > idle;

  Map<String, dynamic> toJson() => {
        '_id': id,
        'userId': userId,
        'secretHash': secretHash,
        'prevSecretHash': prevSecretHash,
        'prevValidUntil': prevValidUntil,
        'currentSecretSeen': currentSecretSeen,
        'rotatedAt': rotatedAt,
        'uaHash': uaHash,
        'ip': ip,
        'ipHistory': ipHistory,
        'createdAt': createdAt,
        'lastSeenAt': lastSeenAt,
        'expiresAt': expiresAt,
        'revokedAt': revokedAt,
        'revokedReason': revokedReason,
        'idToken': idToken,
      };

  static StoredSession fromJson(Map<String, dynamic> json) => StoredSession(
        id: json['_id'] as String,
        userId: json['userId'] as String,
        secretHash: json['secretHash'] as String,
        prevSecretHash: json['prevSecretHash'] as String?,
        prevValidUntil: json['prevValidUntil'] as DateTime?,
        currentSecretSeen: json['currentSecretSeen'] as bool? ?? true,
        rotatedAt: json['rotatedAt'] as DateTime? ?? DateTime.now(),
        uaHash: json['uaHash'] as String? ?? '',
        ip: json['ip'] as String? ?? '',
        ipHistory: (json['ipHistory'] as List?)?.whereType<String>().toList() ??
            const [],
        createdAt: json['createdAt'] as DateTime? ?? DateTime.now(),
        lastSeenAt: json['lastSeenAt'] as DateTime? ?? DateTime.now(),
        expiresAt: json['expiresAt'] as DateTime? ?? DateTime.now(),
        revokedAt: json['revokedAt'] as DateTime?,
        revokedReason: json['revokedReason'] as String?,
        idToken: json['idToken'] as String?,
      );
}

/// Persistence for users and sessions.
///
/// Sessions are stored server side rather than carried in a signed cookie
/// because all three things the deployment needs — administrative logout,
/// detecting a cloned cookie, and following a revocation on the identity
/// provider — require state that can be changed without the client's help.
abstract class AuthStore {
  Future<void> ensureIndexes();

  Future<StoredUser?> getUser(String id);

  /// Creates or refreshes a user record from what the provider just said.
  /// Does not touch [StoredUser.status]; blocking and unblocking go through
  /// [setUserStatus].
  Future<StoredUser> upsertUser(
    AuthenticatedUser user, {
    String? refreshTokenEnc,
    DateTime? validatedAt,
  });

  Future<void> setUserStatus(String id, UserStatus status, {String? reason});

  /// Records the outcome of a revalidation attempt.
  Future<void> recordValidation(
    String id, {
    DateTime? validatedAt,
    int? failures,
    String? refreshTokenEnc,
    List<String>? groups,
    String? email,
    String? displayName,
  });

  /// Users that currently hold at least one live session. Only these need
  /// revalidating — nobody else can be making requests.
  Future<List<StoredUser>> usersWithLiveSessions();

  /// Everyone who has ever signed in, most recently active first. Backs the
  /// administration page.
  Future<List<StoredUser>> listUsers({int limit = 200});

  /// Number of live sessions per user id, for the administration page.
  Future<Map<String, int>> liveSessionCounts();

  Future<void> createSession(StoredSession session);

  Future<StoredSession?> getSession(String id);

  /// Atomically swaps the session secret, but only if [expectedSecretHash] is
  /// still current. Returns false when another concurrent request rotated
  /// first, which is normal and not an error.
  ///
  /// The new secret starts out unconfirmed
  /// ([StoredSession.currentSecretSeen] false).
  ///
  /// [prevSecretHash] is stated explicitly rather than assumed to be the
  /// expected one: when a client is catching up after missing a cookie
  /// update, the secret that stays valid is the one it just presented, not
  /// the one it never received.
  Future<bool> rotateSession(
    String id, {
    required String expectedSecretHash,
    required String newSecretHash,
    required String prevSecretHash,
    required DateTime prevValidUntil,
    required DateTime rotatedAt,
  });

  /// Marks the current secret as delivered and drops the previous one.
  ///
  /// From this point a request carrying the previous secret can only come
  /// from a second holder of the cookie.
  Future<void> confirmSecretSeen(String id, String secretHash);

  /// Updates activity bookkeeping. [ipHistory], when given, replaces the
  /// stored list wholesale — the caller caps it so the document cannot grow
  /// without bound.
  Future<void> touchSession(String id, DateTime lastSeenAt,
      {String? ip, List<String>? ipHistory});

  Future<void> revokeSession(String id, String reason);

  /// Revokes every live session of a user, optionally sparing one. Returns
  /// how many were ended.
  Future<int> revokeUserSessions(String userId, String reason,
      {String? exceptSessionId});

  Future<List<StoredSession>> listUserSessions(String userId);

  /// Drops sessions that are past their expiry or idle deadline. Called from
  /// the background sweep.
  Future<int> purgeExpiredSessions(Duration idle);
}

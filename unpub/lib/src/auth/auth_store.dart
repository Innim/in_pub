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

  /// There is nothing left to confirm the account with, so it cannot be
  /// checked until its owner signs in again.
  ///
  /// Distinct from the two blocks on purpose: nobody withdrew this access,
  /// and the way back is a sign-in rather than an administrator. Recording
  /// it as a state is also what stops the check repeating on every request.
  needsSignIn,
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

  /// Whether signing in again is what fixes this, as opposed to an
  /// administrator or the identity provider. Distinguished because the two
  /// are answered differently: one gets a sign-in link, the other a page
  /// explaining that access was withdrawn.
  bool get needsSignIn => status == UserStatus.needsSignIn;

  AuthenticatedUser toAuthenticatedUser() => AuthenticatedUser(
      id: id, email: email, displayName: displayName, groups: groups);

  /// The address folded for comparison. Stored alongside the original
  /// because the legacy credential is matched by address, and a provider
  /// that reports `Alice@Example.org` where Google reports
  /// `alice@example.org` would otherwise slip past the check entirely.
  String get emailKey => normalizeAddress(email);

  /// Reads a stored status, refusing access on anything unrecognised.
  ///
  /// A value this build does not know can only come from a newer one — a
  /// rollback, most likely — and defaulting to `active` there hands full
  /// access to an account some other version of this server had decided it
  /// could not vouch for. An absent field is the exception: records predate
  /// the column rather than disagreeing about it.
  static UserStatus _statusFrom(Object? value) {
    if (value == null) return UserStatus.active;
    return UserStatus.values.firstWhere((s) => s.name == value,
        orElse: () => UserStatus.blockedLocal);
  }

  Map<String, dynamic> toJson() => {
        '_id': id,
        'email': email,
        'emailKey': emailKey,
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
        status: _statusFrom(json['status']),
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
  /// The provider's id token, encrypted.
  ///
  /// Held only for `end_session_endpoint`'s `id_token_hint`. Encrypted for
  /// the same reason the refresh token is: it is a signed assertion carrying
  /// the account's identity and group claims, and the provider accepts it —
  /// so a leaked backup should not also hand over everyone's profile and the
  /// ability to end their sessions upstream. Read it through
  /// `SessionManager.idTokenOf`.
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
        secretHash: json['secretHash'] as String? ?? '',
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

/// What a token stands for.
enum TokenKind {
  /// Issued by a person, for themselves. Carries their identity, and dies
  /// with their account: blocking them or losing them upstream takes the
  /// token with it.
  personal,

  /// Issued by an administrator and tied to no provider account, so it
  /// outlives staff changes. The trade is that nothing upstream can revoke
  /// it — only an administrator here can.
  service,
}

/// A bearer token for the pub client.
///
/// The value handed out is `inpub_<id>.<secret>`: the prefix makes it
/// recognisable to a leak scanner, the id turns verification into one
/// indexed lookup, and only a hash of the secret is stored, so a database
/// dump yields nothing usable.
class StoredToken {
  final String id;
  final String secretHash;
  final TokenKind kind;

  /// The account this belongs to. Null for a service token, which is exactly
  /// what makes it survive its creator leaving.
  final String? userId;

  /// The identity recorded against anything published with this token. For a
  /// personal token it mirrors the owner; for a service token an
  /// administrator chooses it.
  final String email;
  final String displayName;

  /// Human-readable label, so a list of tokens can be reasoned about.
  final String name;

  /// Who issued it. For a personal token, the owner themselves.
  final String createdBy;

  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? lastUsedAt;
  final String? lastUsedIp;
  final DateTime? revokedAt;
  final String? revokedReason;

  const StoredToken({
    required this.id,
    required this.secretHash,
    required this.kind,
    required this.email,
    required this.displayName,
    required this.name,
    required this.createdBy,
    required this.createdAt,
    this.userId,
    this.expiresAt,
    this.lastUsedAt,
    this.lastUsedIp,
    this.revokedAt,
    this.revokedReason,
  });

  bool get isRevoked => revokedAt != null;

  bool isExpired(DateTime now) {
    var expiry = expiresAt;
    return expiry != null && now.isAfter(expiry);
  }

  bool isUsable(DateTime now) => !isRevoked && !isExpired(now);

  AuthenticatedUser toAuthenticatedUser({List<String> groups = const []}) =>
      AuthenticatedUser(
          id: userId ?? 'token:$id',
          email: email,
          displayName: displayName,
          groups: groups);

  Map<String, dynamic> toJson() => {
        '_id': id,
        'secretHash': secretHash,
        'kind': kind.name,
        'userId': userId,
        'email': email,
        'displayName': displayName,
        'name': name,
        'createdBy': createdBy,
        'createdAt': createdAt,
        'expiresAt': expiresAt,
        'lastUsedAt': lastUsedAt,
        'lastUsedIp': lastUsedIp,
        'revokedAt': revokedAt,
        'revokedReason': revokedReason,
      };

  static StoredToken fromJson(Map<String, dynamic> json) => StoredToken(
        id: json['_id'] as String,
        secretHash: json['secretHash'] as String? ?? '',
        kind: TokenKind.values.firstWhere((k) => k.name == json['kind'],
            orElse: () => TokenKind.personal),
        userId: json['userId'] as String?,
        email: json['email'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        name: json['name'] as String? ?? '',
        createdBy: json['createdBy'] as String? ?? '',
        createdAt: json['createdAt'] as DateTime? ?? DateTime.now(),
        expiresAt: json['expiresAt'] as DateTime?,
        lastUsedAt: json['lastUsedAt'] as DateTime?,
        lastUsedIp: json['lastUsedIp'] as String?,
        revokedAt: json['revokedAt'] as DateTime?,
        revokedReason: json['revokedReason'] as String?,
      );
}

/// How this server decides two email addresses are the same one.
///
/// Case-folded and trimmed, in one place. It used to be spelled out
/// separately in `App`, in `MongoAuthStore` and in the uploader-lookup
/// closure in `bin/in_pub.dart`, and they did not agree: the closure's regex
/// did not trim, so an uploader entry with a stray space slipped past the
/// check that stops a service token being given somebody else's address,
/// while `App` trimmed and let that same token publish as them.
String normalizeAddress(String email) => email.trim().toLowerCase();

/// The pattern that matches a *stored* address equal to [email], for the two
/// queries that cannot go through a folded key.
///
/// User records written before `emailKey` existed hold only the address as
/// the provider spelled it, and the uploader arrays in the package metadata
/// hold whatever an earlier publish recorded — neither is folded, and both
/// may carry stray whitespace. Callers must ask for a case-insensitive
/// match; the pattern folds nothing itself.
///
/// It exists because this rule was written out by hand in three places and
/// they did not agree: the uploader lookup did not trim, so an entry with a
/// stray space slipped past the check that stops a service token being given
/// somebody else's address, and `findUsersByEmail` did not fold, so a legacy
/// record matched nothing and a blocked publisher's credential was taken for
/// one belonging to no account here.
String storedAddressPattern(String email) =>
    '^\\s*${RegExp.escape(normalizeAddress(email))}\\s*\$';

/// Enough of a check to catch a name typed where an address belongs.
///
/// Deliberately not an attempt at the full grammar — [normalizeAddress], not
/// this, decides what two addresses being equal means. What it is for is the
/// value that is not an address at all: a token's address is recorded as the
/// uploader of everything it publishes and matched against uploader lists,
/// and an empty one is an identity every account with no `email` claim
/// shares.
///
/// The dot in the domain is required on purpose, and it is the part worth
/// stating because it refuses things that do exist: `alice@corp`,
/// `ci@internal`, every single-label intranet name a directory might hold.
/// Only addresses that could be delivered to are wanted here, so
/// `dart pub uploader add ops@intranet` is refused — and on a provider that
/// reports dotless addresses, so is every token an account could create,
/// which with `--auth-protect-pub-api` leaves that person unable to
/// authenticate at all. The answer to that is a real address on the
/// directory entry, not a looser rule here.
bool looksLikeEmailAddress(String value) =>
    RegExp(r'^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$').hasMatch(value);

/// Persistence for users, sessions and access tokens.
///
/// Sessions are stored server side rather than carried in a signed cookie
/// because all three things the deployment needs — administrative logout,
/// detecting a cloned cookie, and following a revocation on the identity
/// provider — require state that can be changed without the client's help.
abstract class AuthStore {
  /// Creates whatever the queries below need. Awaited before the server
  /// starts listening, so it must stay quick.
  Future<void> ensureIndexes();

  /// Brings records written by an older build up to date.
  ///
  /// Separate from [ensureIndexes] and run in the background, because it
  /// touches every row: on a large collection it would otherwise sit in
  /// front of the listening socket and make a restart look like a hang.
  /// Nothing may depend on this having run. It exists to put older records
  /// on the indexed path, not to make them findable — every query has to
  /// answer correctly against a record it has not reached yet, because it
  /// runs in the background and may fail outright.
  Future<void> runMigrations() async {}

  Future<StoredUser?> getUser(String id);

  /// Every user carrying this address.
  ///
  /// A list rather than one record, because the legacy credential identifies
  /// people by email and nothing else, and an address is not unique here: a
  /// provider migration or a reissued address leaves two identities behind
  /// it. Picking whichever the index happened to reach first would let a
  /// blocked person keep publishing under their other record.
  Future<List<StoredUser>> findUsersByEmail(String email);

  /// Creates or refreshes a user record from what the provider just said.
  /// Does not touch [StoredUser.status]; blocking and unblocking go through
  /// [setUserStatus].
  ///
  /// A blank [AuthenticatedUser.email] leaves an address already on record
  /// alone, for the reason [recordValidation] gives — a sign-in carrying no
  /// `email` claim is the same event as a revalidation carrying none, and it
  /// must not be the one that empties the field. Implementations must agree
  /// on this, doubles included.
  Future<StoredUser> upsertUser(
    AuthenticatedUser user, {
    String? refreshTokenEnc,
    DateTime? validatedAt,
  });

  Future<void> setUserStatus(String id, UserStatus status, {String? reason});

  /// Records the outcome of a revalidation attempt.
  ///
  /// A null field is left as it was. An [email] that is empty or blank counts
  /// as null for the same reason: it is not an address, and overwriting a
  /// good one with it takes the record out of every address lookup — which is
  /// how a blocked publisher's legacy credential came to read as belonging to
  /// no account here. Implementations must agree on this, doubles included.
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
  ///
  /// [idle] is how long a session may go unused before it stops counting,
  /// so that this and the account screen agree on what "live" means.
  Future<List<StoredUser>> usersWithLiveSessions(Duration idle);

  /// Everyone who has ever signed in, most recently active first. Backs the
  /// administration page.
  Future<List<StoredUser>> listUsers({int limit = 200});

  /// Number of live sessions per user id, for the administration page.
  Future<Map<String, int>> liveSessionCounts(Duration idle);

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

  /// Revokes a session, and says whether this call is the one that did it.
  ///
  /// Conditional on the row still being live, exactly as [revokeToken] is,
  /// and reported for the same reason: the account screen's only way to
  /// avoid answering "ended" — and writing an end into the log — for a
  /// session somebody else, or an earlier click, had already ended.
  Future<bool> revokeSession(String id, String reason);

  /// Revokes every live session of a user, optionally sparing one. Returns
  /// how many were ended.
  Future<int> revokeUserSessions(String userId, String reason,
      {String? exceptSessionId});

  Future<List<StoredSession>> listUserSessions(String userId);

  /// Drops sessions that are past their expiry or idle deadline. Called from
  /// the background sweep.
  Future<int> purgeExpiredSessions(Duration idle);

  /// Drops tokens that expired or were revoked longer than [keepRevoked]
  /// ago. Both are kept a while so that whoever presents one is told which
  /// it was, rather than that it is simply unknown; after that the record is
  /// only bulk the collection would carry forever.
  Future<int> purgeDeadTokens(Duration keepRevoked);

  // ------------------------------------------------------------ tokens

  Future<void> createToken(StoredToken token);

  /// Looks a token up by the id embedded in its value. The caller still has
  /// to check the secret; finding the record is not authentication.
  Future<StoredToken?> getToken(String id);

  /// Records that a token was used. Throttled by the caller, since a busy
  /// CI run would otherwise write on every request.
  Future<void> touchToken(String id, DateTime usedAt, {String? ip});

  /// Revokes a token, and says whether this call is the one that did it.
  ///
  /// The write is conditional on the token not already being revoked, so a
  /// second attempt changes nothing. Reporting that honestly is the caller's
  /// only way to avoid answering "revoked" — and logging a revocation — for
  /// a row that was already dead.
  Future<bool> revokeToken(String id, String reason);

  /// This user's tokens that are still live — neither revoked nor expired.
  ///
  /// Dead rows are dropped by the query rather than by every caller: they
  /// linger until the sweep passes `tokenRetention`, and a fleet that
  /// rotates tokens would otherwise ship its whole history on each read.
  Future<List<StoredToken>> listTokensOfUser(String userId);

  /// Live service tokens, for the administration page. These belong to no
  /// user, so they appear nowhere else.
  ///
  /// Capped, so it must not be used to decide anything: see
  /// [serviceTokensForEmail].
  Future<List<StoredToken>> listServiceTokens();

  /// Every live service token publishing as [email].
  ///
  /// Asked directly rather than by scanning [listServiceTokens], which is
  /// capped — past the cap the older token carrying an address simply would
  /// not be in the page, and a second credential for the same identity would
  /// be issued.
  ///
  /// A list rather than the first match, because more than one is the
  /// condition worth reporting: the address check runs before the token is
  /// written, so a deployment that raced, or that predates the check, can
  /// hold several and an administrator has to be told which they are.
  Future<List<StoredToken>> serviceTokensForEmail(String email);
}

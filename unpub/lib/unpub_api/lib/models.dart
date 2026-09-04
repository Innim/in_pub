import 'package:json_annotation/json_annotation.dart';

part 'models.g.dart';

@JsonSerializable()
class ListApi {
  int count;
  List<ListApiPackage> packages;

  ListApi(this.count, this.packages);

  factory ListApi.fromJson(Map<String, dynamic> map) => _$ListApiFromJson(map);
  Map<String, dynamic> toJson() => _$ListApiToJson(this);
}

@JsonSerializable()
class ListApiPackage {
  String name;
  String? description;
  List<String> tags;
  String latest;
  DateTime updatedAt;

  ListApiPackage(
      this.name, this.description, this.tags, this.latest, this.updatedAt);

  factory ListApiPackage.fromJson(Map<String, dynamic> map) =>
      _$ListApiPackageFromJson(map);
  Map<String, dynamic> toJson() => _$ListApiPackageToJson(this);
}

@JsonSerializable()
class DetailViewVersion {
  String version;
  DateTime createdAt;

  DetailViewVersion(this.version, this.createdAt);

  factory DetailViewVersion.fromJson(Map<String, dynamic> map) =>
      _$DetailViewVersionFromJson(map);

  Map<String, dynamic> toJson() => _$DetailViewVersionToJson(this);
}

@JsonSerializable()
class DependencyView {
  /// Package name.
  String name;

  /// Absolute URL to the dependency's page on an external pub server
  /// (e.g. pub.dev or another hosted server).
  ///
  /// `null` when [internal] is `true`, or when the dependency is not linkable
  /// to a pub page (sdk/git/path sources).
  String? url;

  /// `true` when the dependency is hosted on this server and should be linked
  /// with an internal router link.
  bool internal;

  DependencyView(this.name, {this.url, this.internal = false});

  factory DependencyView.fromJson(Map<String, dynamic> map) =>
      _$DependencyViewFromJson(map);

  Map<String, dynamic> toJson() => _$DependencyViewToJson(this);
}

@JsonSerializable()
class WebapiDetailView {
  String name;
  String version;
  String description;
  String homepage;
  List<String> uploaders;
  DateTime createdAt;
  final String? readme;
  final String? changelog;
  List<DetailViewVersion> versions;
  List<String> authors;
  List<DependencyView>? dependencies;
  List<String> tags;

  /// Whether this server can serve generated API documentation for this
  /// package (i.e. a doc store is configured). Controls the "API reference"
  /// link in the web UI.
  bool hasDocs;

  WebapiDetailView(
      this.name,
      this.version,
      this.description,
      this.homepage,
      this.uploaders,
      this.createdAt,
      this.readme,
      this.changelog,
      this.versions,
      this.authors,
      this.dependencies,
      this.tags,
      {this.hasDocs = false});

  factory WebapiDetailView.fromJson(Map<String, dynamic> map) =>
      _$WebapiDetailViewFromJson(map);

  Map<String, dynamic> toJson() => _$WebapiDetailViewToJson(this);
}

/// Everything the account screen needs in one request: who you are, your
/// live sessions and your tokens.
///
/// Sent as a whole rather than as three endpoints because the screen is
/// useless without all of it, and because [csrfToken] has to come from
/// somewhere before anything can be changed.
@JsonSerializable()
class AccountView {
  String id;
  String email;
  String name;
  List<String> groups;
  bool isAdmin;

  /// Must be echoed back in the `X-CSRF-Token` header on every change.
  String csrfToken;

  /// Id of the session this page is being viewed from, so it can be marked
  /// and its "sign out" button worded differently.
  String currentSessionId;

  List<AccountSession> sessions;
  List<AccountToken> tokens;

  /// Tokens belonging to no account. Empty unless [isAdmin].
  List<AccountToken> serviceTokens;

  /// Whether a token is currently required by `dart pub get`, which decides
  /// whether the screen says tokens are needed or merely accepted.
  bool pubApiProtected;

  /// Base url to hand to `dart pub token add`.
  String publicUrl;

  AccountView(
    this.id,
    this.email,
    this.name,
    this.groups,
    this.isAdmin,
    this.csrfToken,
    this.currentSessionId,
    this.sessions,
    this.tokens,
    this.serviceTokens,
    this.pubApiProtected,
    this.publicUrl,
  );

  factory AccountView.fromJson(Map<String, dynamic> map) =>
      _$AccountViewFromJson(map);
  Map<String, dynamic> toJson() => _$AccountViewToJson(this);
}

@JsonSerializable()
class AccountSession {
  String id;
  String ip;

  /// Addresses this session has been used from before the current one.
  List<String> previousIps;
  DateTime createdAt;
  DateTime lastSeenAt;
  DateTime expiresAt;

  AccountSession(this.id, this.ip, this.previousIps, this.createdAt,
      this.lastSeenAt, this.expiresAt);

  factory AccountSession.fromJson(Map<String, dynamic> map) =>
      _$AccountSessionFromJson(map);
  Map<String, dynamic> toJson() => _$AccountSessionToJson(this);
}

@JsonSerializable()
class AccountToken {
  String id;
  String name;

  /// `personal` or `service`.
  String kind;

  /// The address publishes are recorded against.
  String email;

  /// Who issued it. Only interesting for service tokens, which belong to
  /// nobody.
  String createdBy;
  DateTime createdAt;
  DateTime? expiresAt;
  DateTime? lastUsedAt;
  String? lastUsedIp;

  AccountToken(this.id, this.name, this.kind, this.email, this.createdBy,
      this.createdAt, this.expiresAt, this.lastUsedAt, this.lastUsedIp);

  factory AccountToken.fromJson(Map<String, dynamic> map) =>
      _$AccountTokenFromJson(map);
  Map<String, dynamic> toJson() => _$AccountTokenToJson(this);
}

/// A token just created. [value] exists only in this response — the server
/// keeps a hash and cannot show it again.
@JsonSerializable()
class CreatedToken {
  AccountToken token;
  String value;

  CreatedToken(this.token, this.value);

  factory CreatedToken.fromJson(Map<String, dynamic> map) =>
      _$CreatedTokenFromJson(map);
  Map<String, dynamic> toJson() => _$CreatedTokenToJson(this);
}

/// The administration screen: everyone who has ever signed in, and what can
/// be done about them.
@JsonSerializable()
class AdminView {
  /// Must be echoed back in the `X-CSRF-Token` header on every change.
  String csrfToken;

  /// Id of the administrator reading this, so the screen can tell their own
  /// row from everybody else's.
  ///
  /// Without it the table offered a Block button on that row, and the server
  /// always refuses it — blocking yourself would leave nothing short of
  /// editing the database to undo — so the only thing the button could ever
  /// do was put an error in the page-level banner. [AccountView] carries the
  /// same field for the same kind of reason.
  String viewerId;
  List<AdminUser> users;

  /// Whether more accounts exist than [users] holds.
  ///
  /// The list is capped, and a silently short list is worse than a short one
  /// that says so: an administrator searching for somebody to block would
  /// otherwise conclude the account does not exist.
  bool truncated;

  AdminView(this.csrfToken, this.viewerId, this.users,
      {this.truncated = false});

  factory AdminView.fromJson(Map<String, dynamic> map) =>
      _$AdminViewFromJson(map);
  Map<String, dynamic> toJson() => _$AdminViewToJson(this);
}

@JsonSerializable()
class AdminUser {
  String id;
  String email;
  String name;
  List<String> groups;

  /// One of `active`, `blockedLocal`, `blockedUpstream` or `needsSignIn`.
  ///
  /// The last is not a block: the server has run out of ways to re-check the
  /// account, and its owner signing in again is what clears it. A client
  /// should not offer an administrator a way to "unblock" it, since the
  /// forced revalidation that would trigger writes the same state back.
  String status;
  String? blockedReason;

  /// How many sessions are live right now.
  int liveSessions;

  /// When the identity provider last confirmed the account.
  DateTime? lastValidatedAt;

  AdminUser(this.id, this.email, this.name, this.groups, this.status,
      this.blockedReason, this.liveSessions, this.lastValidatedAt);

  factory AdminUser.fromJson(Map<String, dynamic> map) =>
      _$AdminUserFromJson(map);
  Map<String, dynamic> toJson() => _$AdminUserToJson(this);
}

import 'dart:convert';
import 'dart:math';

/// Everything the auth layer needs to run, assembled from command line flags
/// and environment variables in `bin/in_pub.dart`.
///
/// The whole feature is off unless [enabled] is true, so an existing
/// deployment keeps working untouched after upgrading.
class AuthConfig {
  /// Master switch (`--auth`).
  final bool enabled;

  /// OpenID Connect issuer, e.g. `https://id.example.org`. Everything else
  /// about the provider is read from
  /// `<issuer>/.well-known/openid-configuration`.
  final String issuer;

  final String clientId;
  final String clientSecret;

  /// Public base url of *this* server. The OIDC redirect uri is derived from
  /// it, so it must match what is registered on the provider byte for byte.
  final Uri publicUrl;

  /// When non-empty, a user must be a member of at least one of these
  /// provider-side groups. Empty means "any account on the issuer".
  final List<String> allowedGroups;

  /// Members of these groups may view and terminate *other* users' sessions.
  final List<String> adminGroups;

  /// Extra OIDC scopes beyond the ones the auth layer always requests.
  final List<String> extraScopes;

  /// Key for the HMAC that signs the short-lived login-state cookie, and the
  /// seed for the refresh-token encryption key.
  final List<int> secret;

  /// Hard upper bound on a session's life, regardless of activity.
  final Duration sessionTtl;

  /// A session with no requests for this long is finished.
  final Duration sessionIdle;

  /// How often the session secret is re-issued. Also the widest window in
  /// which a stolen cookie can be used before the theft is detected.
  final Duration sessionRotate;

  /// How long a not-yet-confirmed previous secret stays usable.
  ///
  /// A client that missed a `Set-Cookie` comes back holding the old secret;
  /// while nobody has presented the new one this is accepted and the cookie
  /// is re-sent. This duration only caps how long that catch-up window can
  /// stay open — clone detection does not depend on it.
  final Duration rotationGrace;

  /// Whether detecting a cloned session kills every session of that user
  /// rather than just the offending one.
  final bool reuseKillsAllSessions;

  /// Bind sessions to the client IP. Off by default: mobile networks and VPNs
  /// change addresses often enough that this logs people out for no reason.
  final bool bindIp;

  /// Addresses allowed to set `X-Forwarded-For`. Unless a request comes from
  /// one of these, the header is ignored — otherwise the recorded client IP
  /// is attacker-controlled and both the binding and the audit log are
  /// worthless.
  final List<String> trustedProxies;

  /// How often a user is re-checked against the provider. This is also the
  /// delay between disabling an account there and it losing access here.
  final Duration revalidateInterval;

  /// If a user could not be re-checked for this long, their requests are
  /// refused rather than allowed through. Bounds how long a provider outage
  /// can be used to keep a revoked account alive.
  final Duration revalidateHard;

  /// Consecutive transport-level failures tolerated before a user is treated
  /// as unvalidatable. Provider downtime must not look like a revocation.
  final int revalidateMaxFailures;

  /// Send the user through the provider's `end_session_endpoint` on logout,
  /// signing them out there as well as here.
  final bool rpInitiatedLogout;

  /// Drop the `Secure` attribute on cookies so the flow works over plain
  /// http. Local development only.
  final bool insecureCookie;

  /// Leave `/badge/*` and `/logo` reachable without a session, so badges
  /// embedded in READMEs keep rendering.
  final bool publicBadges;

  AuthConfig({
    required this.enabled,
    required this.issuer,
    required this.clientId,
    required this.clientSecret,
    required this.publicUrl,
    required this.secret,
    this.allowedGroups = const [],
    this.adminGroups = const [],
    this.extraScopes = const [],
    this.sessionTtl = const Duration(hours: 24),
    this.sessionIdle = const Duration(hours: 8),
    this.sessionRotate = const Duration(minutes: 5),
    this.rotationGrace = const Duration(minutes: 10),
    this.reuseKillsAllSessions = false,
    this.bindIp = false,
    this.trustedProxies = const [],
    this.revalidateInterval = const Duration(minutes: 5),
    this.revalidateHard = const Duration(minutes: 30),
    this.revalidateMaxFailures = 3,
    this.rpInitiatedLogout = false,
    this.insecureCookie = false,
    this.publicBadges = true,
  });

  /// A config with the feature switched off. Used when `--auth` is absent.
  factory AuthConfig.disabled() => AuthConfig(
        enabled: false,
        issuer: '',
        clientId: '',
        clientSecret: '',
        publicUrl: Uri.parse('http://localhost'),
        secret: const [],
      );

  Uri get redirectUri => resolvePath('auth/callback');

  /// Resolves [path] against [publicUrl], keeping any path prefix.
  ///
  /// `Uri.resolve` would drop it: against `https://example.org/pub` it reads
  /// `pub` as a file name and yields `https://example.org/auth/callback`,
  /// which then fails the provider's redirect uri check on any deployment
  /// mounted under a sub-path.
  Uri resolvePath(String path) {
    var base = publicUrl.path;
    if (!base.endsWith('/')) base = '$base/';
    // Built up rather than derived with `replace`, which keeps any query and
    // fragment the configured url happens to carry: a redirect uri with
    // either would not match what the provider was told.
    return Uri(
      scheme: publicUrl.scheme,
      userInfo: publicUrl.userInfo,
      host: publicUrl.host,
      port: publicUrl.hasPort ? publicUrl.port : null,
      path: '$base$path',
    );
  }

  /// `groups` carries group membership, which [allowedGroups] filters on;
  /// `offline_access` is what makes the provider hand out a refresh token,
  /// which is the only way to later ask whether the account still exists.
  List<String> get scopes => [
        'openid',
        'profile',
        'email',
        'groups',
        'offline_access',
        ...extraScopes,
      ];

  bool isAllowedGroup(List<String> groups) =>
      allowedGroups.isEmpty || groups.any(allowedGroups.contains);

  bool isAdmin(List<String> groups) =>
      adminGroups.isNotEmpty && groups.any(adminGroups.contains);

  /// Validates the parts that only matter once the feature is on, so a
  /// misconfigured server fails at startup rather than at first login.
  List<String> validate() {
    if (!enabled) return const [];
    var errors = <String>[];
    if (issuer.isEmpty) errors.add('--auth-issuer is required');
    if (clientId.isEmpty) errors.add('--auth-client-id is required');
    if (clientSecret.isEmpty) {
      errors.add('client secret is required '
          '(INPUB_AUTH_CLIENT_SECRET or --auth-client-secret)');
    }
    if (!publicUrl.hasScheme || publicUrl.host.isEmpty) {
      errors.add('--auth-public-url must be an absolute url');
    }
    if (secret.length < 32) errors.add('session secret is too short');
    if (revalidateHard < revalidateInterval) {
      errors.add('--auth-revalidate-hard must not be shorter than '
          '--auth-revalidate-interval');
    }
    if (sessionIdle > sessionTtl) {
      errors.add('--auth-session-idle must not exceed --auth-session-ttl');
    }
    return errors;
  }

  /// Reads the signing secret from [value], falling back to a random one.
  ///
  /// A generated secret is fine for a single run but invalidates every
  /// session on restart, so the caller is expected to warn about it.
  static List<int> resolveSecret(String? value) {
    if (value != null && value.trim().isNotEmpty) {
      return utf8.encode(value.trim());
    }
    var rnd = Random.secure();
    return List<int>.generate(48, (_) => rnd.nextInt(256));
  }
}

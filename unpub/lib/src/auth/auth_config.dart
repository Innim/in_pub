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

  /// How long an expired or revoked token is kept before the sweep drops it.
  ///
  /// Long enough that whoever presents one is told which it was, rather than
  /// that it is simply unknown; after that the record is only bulk.
  final Duration tokenRetention;

  /// Send the user through the provider's `end_session_endpoint` on logout,
  /// signing them out there as well as here.
  final bool rpInitiatedLogout;

  /// Drop the `Secure` attribute on cookies so the flow works over plain
  /// http. Local development only.
  ///
  /// A cookie attribute and nothing else. It used to double as the switch
  /// that opened CORS to every localhost origin, which is a policy decision
  /// it has no business making: an operator whose TLS terminates at a
  /// reverse proxy sets this for the reason its name gives, and thereby let
  /// any page on any localhost port, on any scheme, read
  /// `/auth/api/account` with the visitor's cookies attached — credentials
  /// stay allowed and `x-csrf-token` is an allowed request header, so that
  /// page could lift the anti-forgery token out of the answer and drive
  /// `/auth/api/admin/action` with it. [devOrigins] states the policy
  /// instead.
  final bool insecureCookie;

  /// Origins allowed to read this server's JSON endpoints cross-origin, on
  /// top of the one [publicUrl] names (`--auth-dev-origins`).
  ///
  /// Empty in production. It exists for a tool or a page run from another
  /// port against a development server, and it is stated rather than
  /// inferred because every entry is credentialed access to somebody's
  /// account data: the CORS answer carries
  /// `Access-Control-Allow-Credentials: true`, so a page on a listed origin
  /// reads what the visitor's cookies open.
  ///
  /// Listing an origin is still not enough to exercise authentication
  /// through `make dev-web`: the browser client sends no cookies
  /// cross-origin, so those requests arrive unauthenticated whatever the
  /// CORS headers say. README's "Trying it locally" is the accurate account.
  final List<String> devOrigins;

  /// Leave `/badge/*` reachable without a session, so badges
  /// embedded in READMEs keep rendering.
  ///
  /// Unstated, it follows the opposite of [protectPubApi]: a badge answers
  /// differently for a package that exists, so leaving them open hands out
  /// the private names and their latest versions — the very thing closing
  /// the pub API is for.
  final bool publicBadges;

  /// Require a bearer token for the pub client's own endpoints — package
  /// metadata and the tarballs themselves.
  ///
  /// Off by default and separate from [enabled] on purpose: turning it on
  /// breaks every consumer that has not yet run `dart pub token add`, so it
  /// has to be a deliberate step taken once the tokens are handed out.
  final bool protectPubApi;

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
    this.tokenRetention = const Duration(days: 30),
    this.rpInitiatedLogout = false,
    this.insecureCookie = false,
    this.devOrigins = const [],
    bool? publicBadges,
    this.protectPubApi = false,
  }) : publicBadges = publicBadges ?? !protectPubApi;

  /// A config with the feature switched off. Used when `--auth` is absent.
  ///
  /// [protectPubApi], [publicBadges] and [devOrigins] are carried through
  /// even so, because asking for any of them without authentication is a
  /// mistake [validate] has to be able to see. Dropping the badge flag here
  /// made `--no-auth-public-badges` a silent no-op on a server without
  /// `--auth`: badges went on being served to everyone while the operator
  /// believed they were closed, which is the outcome the neighbouring check
  /// refuses to start over.
  factory AuthConfig.disabled({
    bool protectPubApi = false,
    bool? publicBadges,
    List<String> devOrigins = const [],
  }) =>
      AuthConfig(
        enabled: false,
        issuer: '',
        clientId: '',
        clientSecret: '',
        publicUrl: Uri.parse('http://localhost'),
        secret: const [],
        protectPubApi: protectPubApi,
        publicBadges: publicBadges,
        devOrigins: devOrigins,
      );

  /// [value] as a browser spells it in the `Origin` header, or null when it
  /// is not something a browser could send.
  ///
  /// Shared by [validate] and the CORS check, so an entry that would match
  /// nothing is refused at startup rather than quietly ignored. A path,
  /// query, fragment or user-info is refused rather than trimmed off: an
  /// origin has none of them, and accepting one would let an entry read as
  /// though it scoped the permission to part of a site, or to a particular
  /// user, which no browser would honour.
  ///
  /// The port is checked too. `Uri` will carry `-1` or `99999` without
  /// complaint and `origin` hands them back verbatim, which is an origin no
  /// browser can ever send — so the entry would match nothing while looking
  /// exactly like one that does.
  static String? originOf(String value) {
    var uri = Uri.tryParse(value.trim());
    if (uri == null) return null;
    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (uri.host.isEmpty) return null;
    if (uri.path.isNotEmpty && uri.path != '/') return null;
    if (uri.hasQuery || uri.hasFragment) return null;
    if (uri.userInfo.isNotEmpty) return null;
    if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) return null;
    return uri.origin;
  }

  /// Every origin this server answers cross-origin for.
  ///
  /// Built once by the caller that installs the CORS middleware. Unparseable
  /// entries are dropped, which [validate] has already refused startup over.
  Set<String> get allowedOrigins {
    var origins = <String>{publicUrl.origin};
    for (var stated in devOrigins) {
      var origin = originOf(stated);
      if (origin != null) origins.add(origin);
    }
    return origins;
  }

  Uri get redirectUri => resolvePath('auth/callback');

  /// An absolute url for [path] on this server.
  ///
  /// Built up rather than derived with `Uri.resolve` or `replace`, either of
  /// which would carry along a query or fragment the configured url happens
  /// to have — a redirect uri with one would not match what the provider was
  /// told. [validate] refuses a public url with a path prefix, so there is
  /// none to preserve here.
  Uri resolvePath(String path) => Uri(
        scheme: publicUrl.scheme,
        userInfo: publicUrl.userInfo,
        host: publicUrl.host,
        port: publicUrl.hasPort ? publicUrl.port : null,
        path: '/$path',
      );

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
    if (!enabled) {
      // Asking for the pub client to be closed without switching
      // authentication on leaves the server wide open while the operator
      // believes otherwise, which is worse than refusing to start.
      return [
        if (protectPubApi)
          '--auth-protect-pub-api needs --auth: without it there is nothing '
              'to authenticate against and the pub API stays open',
        // Same reasoning, same guard. Only reported when the badge flag is
        // the one that was actually stated: unstated, `publicBadges` follows
        // the opposite of `protectPubApi`, so with that flag already
        // reported above this would merely say it a second time.
        if (!publicBadges && !protectPubApi)
          '--no-auth-public-badges needs --auth: without it there is nothing '
              'to authenticate against and the badges stay open',
        // Not a hole — with `--auth` off the CORS answer is a wildcard with
        // credentials refused, so an origin dropped here cannot make the
        // server more permissive than it already is. What it is, is a flag
        // that does nothing while reading as though it configured something,
        // and the place a typo goes unnoticed: `validate` is the only thing
        // that ever looks at an entry's shape, and it never reaches that
        // loop for a disabled config. An operator who spells an origin wrong
        // while trying `--auth` out finds out at the moment they turn it on,
        // which is the moment they are least able to tell the two changes
        // apart. Refused for the same reason as the two above — the flag
        // should mean what it says or stop the server.
        if (devOrigins.isNotEmpty)
          '--auth-dev-origins needs --auth: without it the answer to every '
              'cross-origin read is a wildcard with credentials refused, and '
              'the origins named here are never consulted',
      ];
    }
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
    if (publicUrl.path.isNotEmpty && publicUrl.path != '/') {
      // The built page carries `<base href="/">`, so every link the
      // application makes resolves against the root regardless of where the
      // server is mounted. Supporting a prefix would mean changing the
      // build, not the redirects — until then, saying so beats half of it
      // working.
      errors.add('--auth-public-url must not include a path prefix: the web '
          'interface is served from the root and cannot be mounted under '
          '"${publicUrl.path}"');
    }
    if (publicUrl.hasScheme &&
        publicUrl.scheme != 'http' &&
        publicUrl.scheme != 'https') {
      // Caught here rather than later: the origin is derived from this to
      // restrict CORS, and `Uri.origin` throws for any other scheme — which
      // would kill the process after the store and provider were wired up,
      // saying nothing about which flag was wrong.
      errors.add('--auth-public-url must be http or https, not '
          '"${publicUrl.scheme}"');
    }
    for (var stated in devOrigins) {
      if (originOf(stated) == null) {
        errors.add('--auth-dev-origins entry "$stated" is not an origin: '
            'expected a scheme, host and optional port, as in '
            '"http://localhost:8080"');
      }
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

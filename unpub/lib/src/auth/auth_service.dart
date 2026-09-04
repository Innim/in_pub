import 'dart:async';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'auth_config.dart';
import 'auth_middleware.dart';
import 'auth_routes.dart';
import 'auth_store.dart';
import 'crypto_box.dart';
import 'google_credential.dart';
import 'identity.dart';
import 'oidc_provider.dart';
import 'session.dart';
import 'token_service.dart';
import 'user_validator.dart';

final _log = Logger('in_pub.auth');

/// Assembles the auth layer and exposes the two things the server needs from
/// it: a gate to put in front of every route, and the handler for `/auth/`.
class AuthService {
  final AuthConfig config;
  final AuthStore store;
  final IdentityProvider provider;
  final CryptoBox crypto;
  final UserValidator validator;
  final SessionManager sessions;
  final TokenService tokens;
  final AuthRoutes routes;

  /// A second scheme to try when a bearer value is not one of ours: the
  /// original Google credential, used for publishing. Null when it is off.
  ///
  /// Built here rather than assigned in from outside. It used to be a
  /// mutable field that `App`'s constructor filled in, which meant a router
  /// mounted directly refused every legacy credential, two servers sharing
  /// one `AuthService` overwrote each other's, and turning Google off on the
  /// second left the first's resolver in place.
  final GoogleCredentialResolver? legacyResolver;

  AuthService._({
    required this.config,
    required this.store,
    required this.provider,
    required this.crypto,
    required this.validator,
    required this.sessions,
    required this.tokens,
    required this.routes,
    required this.legacyResolver,
  });

  /// Wires everything up. [provider] is injectable so tests can drive the
  /// flow without an identity provider on the other end.
  ///
  /// [googleAuth] keeps the original Google credential working for publishing
  /// alongside this server's own tokens; it matches the flag of the same name
  /// on `App`, and deployments that have finished migrating turn it off.
  factory AuthService({
    required AuthConfig config,
    required AuthStore store,
    IdentityProvider? provider,
    Future<bool> Function(String email)? isPackageUploader,
    bool googleAuth = true,
    String? googleapisProxy,
    GoogleCredentialResolver? legacyResolver,
  }) {
    var errors = config.validate();
    if (errors.isNotEmpty) {
      throw ArgumentError('authentication is misconfigured:\n'
          '${errors.map((e) => '  - $e').join('\n')}');
    }

    var crypto = CryptoBox(config.secret);
    var identityProvider = provider ?? OidcProvider(config);
    var validator = UserValidator(
      config: config,
      store: store,
      provider: identityProvider,
      crypto: crypto,
    );
    var sessions = SessionManager(
      config: config,
      store: store,
      crypto: crypto,
      validator: validator,
    );
    var tokens = TokenService(
      config: config,
      store: store,
      validator: validator,
    );

    return AuthService._(
      config: config,
      store: store,
      provider: identityProvider,
      crypto: crypto,
      validator: validator,
      sessions: sessions,
      tokens: tokens,
      routes: AuthRoutes(
        config: config,
        store: store,
        provider: identityProvider,
        sessions: sessions,
        tokens: tokens,
        crypto: crypto,
        isPackageUploader: isPackageUploader,
      ),
      // Gated on the flag, not merely defaulted by it. Taking an injected
      // resolver regardless meant `googleAuth: false` alongside one turned
      // the legacy path fully on, since `resolveBearer` only ever asks
      // whether a resolver exists.
      legacyResolver: googleAuth
          ? (legacyResolver ?? GoogleCredentialResolver(proxy: googleapisProxy))
          : null,
    );
  }

  /// Prepares storage and starts the background revalidation sweep.
  Future<void> start() async {
    await store.ensureIndexes();
    // Deliberately not awaited: this rewrites every stale record, and the
    // socket should not wait on it. Until it finishes those records simply
    // go unmatched, which refuses rather than admits.
    unawaited(store.runMigrations().catchError(
        (Object e) => _log.warning('a startup migration failed: $e')));
    validator.start();
    _log.info('authentication enabled: issuer ${config.issuer}, '
        'redirect ${config.redirectUri}');
    if (config.allowedGroups.isNotEmpty) {
      _log.info('access limited to groups: ${config.allowedGroups.join(', ')}');
    }

    // Printed up front so a misconfiguration is visible before the first
    // person tries to sign in, rather than as a rejection afterwards. None
    // of it is secret — the credentials are described, not shown.
    _log.fine('authentication configuration:\n'
        '  issuer:        ${config.issuer}\n'
        '  redirect uri:  ${config.redirectUri}  (must match the provider '
        'registration exactly)\n'
        '  scopes:        ${config.scopes.join(' ')}\n'
        '  allowed groups:${config.allowedGroups.isEmpty ? ' (any account on the issuer)' : ' ${config.allowedGroups.join(', ')}'}\n'
        '  admin groups:  ${config.adminGroups.isEmpty ? '(none)' : config.adminGroups.join(', ')}\n'
        '  cookies:       ${config.insecureCookie ? 'insecure (http allowed)' : 'Secure'}\n'
        '  trusted proxies:${config.trustedProxies.isEmpty ? ' (none — X-Forwarded-For is ignored)' : ' ${config.trustedProxies.join(', ')}'}\n'
        '  session:       ttl ${config.sessionTtl.inMinutes}m, idle '
        '${config.sessionIdle.inMinutes}m, rotate '
        '${config.sessionRotate.inMinutes}m\n'
        '  revalidation:  every ${config.revalidateInterval.inMinutes}m, hard '
        'limit ${config.revalidateHard.inMinutes}m');
    var p = provider;
    if (p is OidcProvider) {
      _log.fine('  credentials:   ${p.describeCredentials()}');
      // Reaching the provider now turns "the first sign-in fails" into "the
      // server said so at startup".
      unawaited(p.discover().then((_) {}, onError: (Object e) {
        _log.severe('could not reach the identity provider: $e');
      }));
    }
    // A first pass right away, so a server that was down while someone was
    // disabled does not serve them on the strength of a stale record.
    unawaitedSweep();
  }

  void unawaitedSweep() {
    validator.sweep().catchError((Object e) {
      _log.warning('initial revalidation sweep failed: $e');
    });
  }

  void close() {
    validator.stop();
    var p = provider;
    if (p is OidcProvider) p.close();
    legacyResolver?.close();
  }

  /// Whether the legacy Google credential may authorise a request for [path].
  ///
  /// The publish handshake and nothing else: it may publish, but not delete
  /// a version or rewrite an uploader list. One predicate, because the gate
  /// and `App`'s own resolution both need the answer and two copies of it
  /// drifted apart once already — one carrying the `googleAuth` conjunct and
  /// one relying on the resolver being null instead.
  bool legacyAllowedFor(String path) =>
      legacyResolver != null && publishHandshakePaths.contains(path);

  /// Resolves a bearer credential to whoever it speaks for.
  ///
  /// Tries our own tokens first, and only falls back to another scheme when
  /// the value is not shaped like ours — a malformed or revoked token of
  /// ours is a definite refusal, not an invitation to keep guessing.
  /// [allowLegacy] admits the original Google credential, which proves only
  /// that somebody holds a Google account. Off unless asked for: letting it
  /// open a read would mean anyone able to mint one could take every private
  /// package, so the dangerous case has to be written out at the call site.
  Future<TokenResolution> resolveBearer(String value,
      {String? ip, bool allowLegacy = false}) async {
    var result = await tokens.resolve(value, ip: ip);
    if (result.recognised) return result;

    var legacy = legacyResolver;
    if (allowLegacy && legacy != null) {
      AuthenticatedUser? user;
      try {
        user = await legacy.resolveUser(value);
      } on IdentityUnavailableException catch (e) {
        // Distinct from a refusal on purpose: "we could not check" must not
        // read as "your credential is wrong".
        return TokenResolution.refused(e.message);
      }
      if (user != null) {
        // The legacy credential identifies a person by email and proves
        // nothing about whether this server still wants to hear from them.
        // If it maps to anybody we know, every one of those records has to
        // be in good standing — active and in an allowed group, the same two
        // conditions a session and a token are held to. Every one, not
        // merely one of them: the credential carries an address and nothing
        // else, so when two identities share it — a provider migration, an
        // address reissued to a new hire — there is no telling which is
        // presenting it.
        var known = await store.findUsersByEmail(user.email);
        for (var u in known) {
          // Through the validator, not off the stored row. The row alone is
          // only as fresh as the last sweep, and the sweep walks accounts
          // with live *sessions* — so a publisher who works entirely from
          // the command line is never in it, and a revocation upstream
          // would never have reached this credential. A token is held to
          // this; the comment above claimed this was too, and it was not.
          var verdict = await validator.ensureValid(u, interactive: false);
          // The refreshed record's groups, not the stored row's. That check
          // may have just talked to the provider and written new ones, and
          // reading the pre-refresh list refused people the session and
          // token paths — which both read the validated record — admit.
          if (!verdict.isAllowed ||
              !config.isAllowedGroup(verdict.user!.groups)) {
            return TokenResolution.refused(verdict.reason ??
                u.blockedReason ??
                'access has been withdrawn for this address');
          }
        }
        // Mapping to nobody is not a refusal. It is every publisher from
        // before authentication existed, and turning `--auth` on is
        // documented as leaving publishing alone. What such a credential can
        // actually do is bounded elsewhere: a publish to an existing package
        // is checked against its uploader list, and `App.upload` refuses to
        // let one create a *new* package, which is the only thing the
        // uploader list does not already cover.
        return TokenResolution.accepted(user, provisional: known.isEmpty);
      }
    }
    return const TokenResolution.refused(
        'this credential is not recognised by this server');
  }

  /// Built lazily because the gate resolves bearer credentials through
  /// [resolveBearer], which belongs to this object and so does not exist
  /// while the constructor is still running.
  late final AuthMiddleware _gate = AuthMiddleware(
    config: config,
    sessions: sessions,
    resolveBearer: resolveBearer,
    legacyAllowedFor: legacyAllowedFor,
  );

  /// Middleware that refuses requests without a session or a token.
  shelf.Middleware get gate => _gate.middleware;

  /// Handler for everything under `/auth/`.
  shelf.Handler get handler => routes.router.call;
}

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'auth_config.dart';
import 'auth_middleware.dart';
import 'auth_routes.dart';
import 'auth_store.dart';
import 'crypto_box.dart';
import 'identity.dart';
import 'oidc_provider.dart';
import 'session.dart';
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
  final AuthRoutes routes;
  final AuthMiddleware _gate;

  AuthService._({
    required this.config,
    required this.store,
    required this.provider,
    required this.crypto,
    required this.validator,
    required this.sessions,
    required this.routes,
    required AuthMiddleware gate,
  }) : _gate = gate;

  /// Wires everything up. [provider] is injectable so tests can drive the
  /// flow without an identity provider on the other end.
  factory AuthService({
    required AuthConfig config,
    required AuthStore store,
    IdentityProvider? provider,
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

    return AuthService._(
      config: config,
      store: store,
      provider: identityProvider,
      crypto: crypto,
      validator: validator,
      sessions: sessions,
      routes: AuthRoutes(
        config: config,
        store: store,
        provider: identityProvider,
        sessions: sessions,
        crypto: crypto,
      ),
      gate: AuthMiddleware(config: config, sessions: sessions),
    );
  }

  /// Prepares storage and starts the background revalidation sweep.
  Future<void> start() async {
    await store.ensureIndexes();
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
  }

  /// Middleware that refuses requests without a session.
  shelf.Middleware get gate => _gate.middleware;

  /// Handler for everything under `/auth/`.
  shelf.Handler get handler => routes.router.call;
}

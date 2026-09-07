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

    var service = AuthService._(
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
    // Wired after construction because it points back at the object being
    // built. The validator refuses accounts on its own schedule — a
    // background revalidation, the sweep — and both credential caches hold
    // answers it would then be contradicting, so it has to be able to say
    // so. See [UserValidator.onAccessWithdrawn].
    validator.onAccessWithdrawn = service._forgetUser;
    // The other half: an administrator blocking somebody is a withdrawal
    // this process performs rather than discovers, and it does not revoke
    // their tokens — that is deliberate, so unblocking restores them — so
    // the caches are the only thing left holding an answer.
    service.routes.onAccessWithdrawn = service._forgetUser;
    return service;
  }

  /// Answers about the legacy Google credential, by folded address.
  ///
  /// Only the *credential* half of that path was ever memoised:
  /// [GoogleCredentialResolver] holds Google's verdict for a minute, to save
  /// the round trips one `dart pub publish` makes. Everything after it ran
  /// again on every request — an address lookup, and a validation for each
  /// identity the address resolves to, each of which is at least one store
  /// read and, once `--auth-revalidate-interval` has elapsed, a synchronous
  /// refresh and a userinfo round trip sitting in front of the archive being
  /// accepted.
  ///
  /// The verdict is per address and, by construction, stable for
  /// `--auth-revalidate-interval`: nothing consults the provider about an
  /// account inside that window anyway. [AuthConfig.validate] refuses a
  /// cache longer than it, so this changes nothing about how quickly a
  /// revocation upstream lands.
  ///
  /// Acceptances only, exactly as in [TokenService.resolve], and for the
  /// same two reasons: an account blocked between two requests must stop
  /// working on the next one, and a refusal is the answer somebody without a
  /// credential can provoke. A refusal here is also the rare case — the
  /// common one is a publisher in good standing making the three requests of
  /// a publish handshake.
  final _legacyVerdicts = <String, _LegacyVerdict>{};

  /// The same generation counter [TokenService] keeps, for the same race and
  /// the same reason: this verdict is reached across an address lookup and a
  /// validation per identity, and a block can commit in either gap. Dropping
  /// the entry when it does is not enough on its own — the request that was
  /// already resolving has not written its entry yet.
  int _legacyWithdrawals = 0;

  /// At most this many, on the same reasoning as [TokenService] — see the
  /// comment on its limit. Smaller because a key here is an address Google
  /// vouched for, not a token, and there are fewer of those.
  static const _legacyCacheLimit = 512;

  /// Drops whatever either cache holds about [id].
  ///
  /// Both, because the same account can be reached by two credentials: a
  /// token of ours, keyed by its own value, and the legacy Google
  /// credential, keyed by the address it carries.
  void _forgetUser(String id) {
    tokens.forgetUser(id);
    _legacyWithdrawals++;
    _legacyVerdicts.removeWhere((_, v) => v.userIds.contains(id));
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
        'limit ${config.revalidateHard.inMinutes}m\n'
        '  credential cache: ${config.credentialCache <= Duration.zero ? 'off — every request re-reads the account' : '${config.credentialCache.inSeconds}s (accepted credentials only)'}');
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
    // For the same reason the resolver clears its own: reuse after close is
    // a supported path, and an answer reached a moment before the close
    // would otherwise still open a request afterwards.
    tokens.forgetEverything();
    _legacyWithdrawals++;
    _legacyVerdicts.clear();
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
        // Folded, because that is what every comparison of an address here
        // does and what the store keys them by: two spellings of one
        // address are one identity, and giving them two entries would let
        // the one that was not invalidated go on answering.
        var address = normalizeAddress(user.email);
        var now = DateTime.now();
        var asOf = _legacyWithdrawals;
        var remembered = _legacyVerdicts[address];
        if (remembered != null) {
          if (remembered.expiresAt.isAfter(now)) {
            // The identity is rebuilt from this request's own answer rather
            // than stored: it is derived from the address, and the address
            // came from Google just now. What is remembered is only the
            // verdict this server reached about it.
            return TokenResolution.accepted(user,
                provisional: remembered.provisional);
          }
          _legacyVerdicts.remove(address);
        }

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
        _rememberLegacy(address, known, now, asOf);
        return TokenResolution.accepted(user, provisional: known.isEmpty);
      }
    }
    return const TokenResolution.refused(
        'this credential is not recognised by this server');
  }

  void _rememberLegacy(
      String address, List<StoredUser> known, DateTime reachedAt, int asOf) {
    var ttl = config.credentialCache;
    if (ttl <= Duration.zero) return;
    // A block landed while this verdict was being reached. It was true when
    // it was reached, which is exactly why keeping it would be wrong.
    if (_legacyWithdrawals != asOf) return;
    _legacyVerdicts[address] = _LegacyVerdict(
      // Which accounts this verdict was reached about, so that a refusal
      // later reached about any one of them retires it. An address is not
      // unique here — a provider migration leaves two identities behind one
      // — and this verdict says every one of them was in good standing, so
      // any of them ceasing to be has to take it down.
      userIds: known.map((u) => u.id).toSet(),
      provisional: known.isEmpty,
      expiresAt: reachedAt.add(ttl),
    );
    if (_legacyVerdicts.length > _legacyCacheLimit) {
      _legacyVerdicts.removeWhere((_, v) => !v.expiresAt.isAfter(reachedAt));
      if (_legacyVerdicts.length > _legacyCacheLimit) _legacyVerdicts.clear();
    }
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

/// What this server concluded about one address presenting the legacy
/// Google credential.
class _LegacyVerdict {
  /// The accounts the address resolved to, empty when it resolved to none.
  /// Kept so `_forgetUser` can retire the verdict when any of them is
  /// refused.
  final Set<String> userIds;

  /// Whether the credential speaks for nobody this server has an account
  /// for, which is what `App.upload` reads to refuse a brand-new package.
  final bool provisional;

  final DateTime expiresAt;

  const _LegacyVerdict({
    required this.userIds,
    required this.provisional,
    required this.expiresAt,
  });
}

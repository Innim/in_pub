import 'dart:async';

import 'package:logging/logging.dart';

import 'auth_config.dart';
import 'auth_store.dart';
import 'crypto_box.dart';
import 'identity.dart';

final _log = Logger('in_pub.auth');

/// The verdict on whether a user may still be served.
class ValidationResult {
  /// The user as currently known, or null when access is denied.
  final StoredUser? user;

  /// Why access was denied, for the log and the error page.
  final String? reason;

  const ValidationResult._(this.user, this.reason);

  const ValidationResult.ok(StoredUser user) : this._(user, null);
  const ValidationResult.denied(String reason) : this._(null, reason);

  bool get isAllowed => user != null;
}

/// Keeps this server's idea of who may log in in step with the identity
/// provider.
///
/// Access here has to end when an account is disabled, deleted or removed
/// from an allowed group *there*, without an administrator repeating the
/// action on both systems. Since OIDC has no callback for that, the state is
/// polled: every user with a live session is re-checked on an interval, and
/// the check is also run on demand when a request arrives with stale
/// validation.
class UserValidator {
  final AuthConfig config;
  final AuthStore store;
  final IdentityProvider provider;
  final CryptoBox crypto;

  /// One revalidation per user at a time.
  ///
  /// This is not an optimisation. Refresh tokens rotate: two concurrent
  /// refreshes with the same token race, one of them is rejected, and the
  /// stored token ends up pointing at a grant the provider has already
  /// retired — logging out a perfectly valid user.
  final _inFlight = <String, Future<StoredUser?>>{};

  Timer? _timer;

  UserValidator({
    required this.config,
    required this.store,
    required this.provider,
    required this.crypto,
  });

  /// Starts the background sweep. Idempotent.
  void start() {
    _timer ??= Timer.periodic(config.revalidateInterval, (_) {
      unawaited(sweep());
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Checks [user], talking to the provider only when the last confirmation
  /// has gone stale.
  Future<ValidationResult> ensureValid(StoredUser user) async {
    if (!user.isActive) {
      return ValidationResult.denied(
          user.blockedReason ?? 'access has been withdrawn');
    }

    var age = _validationAge(user);
    if (age < config.revalidateInterval) return ValidationResult.ok(user);

    // Still comfortably inside the window: serve this request from what we
    // know and refresh in the background, so revalidation never sits in front
    // of a user's page load.
    if (age < config.revalidateHard &&
        user.validationFailures < config.revalidateMaxFailures) {
      unawaited(_validate(user));
      return ValidationResult.ok(user);
    }

    // Past the window: the answer has to be current before we serve anything.
    var refreshed = await _validate(user);
    if (refreshed == null) {
      var blocked = await store.getUser(user.id);
      return ValidationResult.denied(
          blocked?.blockedReason ?? 'access has been withdrawn');
    }
    if (_validationAge(refreshed) >= config.revalidateHard ||
        refreshed.validationFailures >= config.revalidateMaxFailures) {
      // The provider is unreachable rather than saying no. Refusing is the
      // conservative answer: otherwise an outage becomes an indefinite
      // extension for accounts that may already have been revoked.
      return ValidationResult.denied(
          'could not confirm your account with the identity provider');
    }
    return ValidationResult.ok(refreshed);
  }

  Duration _validationAge(StoredUser user) =>
      DateTime.now().difference(user.lastValidatedAt ?? user.createdAt);

  /// Re-checks every user holding a live session, and clears out sessions
  /// that have aged out.
  Future<void> sweep() async {
    try {
      var purged = await store.purgeExpiredSessions(config.sessionIdle);
      if (purged > 0) _log.fine('purged $purged expired session(s)');
    } catch (e) {
      _log.warning('failed to purge expired sessions: $e');
    }

    List<StoredUser> users;
    try {
      users = await store.usersWithLiveSessions();
    } catch (e) {
      _log.warning('failed to list users with live sessions: $e');
      return;
    }

    for (var user in users) {
      if (!user.isActive) {
        // Blocked but still holding sessions: finish the job the blocking
        // started, in case revoking them failed at the time.
        await store.revokeUserSessions(
            user.id, user.blockedReason ?? 'access withdrawn');
        continue;
      }
      if (_validationAge(user) < config.revalidateInterval) continue;
      await _validate(user);
    }
  }

  Future<StoredUser?> _validate(StoredUser user) {
    var existing = _inFlight[user.id];
    if (existing != null) return existing;
    var future = _doValidate(user);
    _inFlight[user.id] = future;
    return future.whenComplete(() => _inFlight.remove(user.id));
  }

  Future<StoredUser?> _doValidate(StoredUser user) async {
    var encrypted = user.refreshTokenEnc;
    var refreshToken = encrypted == null ? null : crypto.decrypt(encrypted);
    if (refreshToken == null) {
      // Nothing left to ask the provider with, so this account can never be
      // confirmed again. Ending the sessions forces a fresh login, which is
      // both harmless and the only way back to a checkable state.
      await _block(
          user,
          'session can no longer be verified, please sign in '
          'again');
      return null;
    }

    OidcTokens tokens;
    AuthenticatedUser fresh;
    try {
      tokens = await provider.refresh(refreshToken);
      // The refresh grant alone is not proof the account is still usable —
      // whether it notices a disabled account is up to the provider. Reading
      // the profile is: a disabled or deleted user cannot authenticate, so
      // this call fails for them.
      fresh = await provider.userInfo(tokens.accessToken);
    } on IdentityRevokedException catch (e) {
      _log.info('access revoked for ${user.id}: ${e.message}');
      await _block(
          user,
          'your account is no longer authorised on the '
          'identity provider');
      return null;
    } on IdentityUnavailableException catch (e) {
      // An unreachable provider is not a revocation. Count it and keep the
      // user working until the hard deadline says otherwise.
      var failures = user.validationFailures + 1;
      _log.warning('could not revalidate ${user.id} '
          '(attempt $failures): ${e.message}');
      await store.recordValidation(user.id, failures: failures);
      return await store.getUser(user.id);
    }

    if (!config.isAllowedGroup(fresh.groups)) {
      _log.info('access revoked for ${user.id}: no longer in an allowed group');
      await _block(
          user,
          'your account is no longer a member of a group with '
          'access to this server');
      return null;
    }

    var rotated = tokens.refreshToken;
    await store.recordValidation(
      user.id,
      validatedAt: DateTime.now(),
      failures: 0,
      refreshTokenEnc: rotated == null ? null : crypto.encrypt(rotated),
      groups: fresh.groups,
      email: fresh.email,
      displayName: fresh.displayName,
    );
    return await store.getUser(user.id);
  }

  Future<void> _block(StoredUser user, String reason) async {
    await store.setUserStatus(user.id, UserStatus.blockedUpstream,
        reason: reason);
    var ended = await store.revokeUserSessions(user.id, reason);
    _log.info('ended $ended session(s) for ${user.id}');
  }
}

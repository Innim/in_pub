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

  /// Whether signing in again is what fixes this.
  final bool recoverable;

  const ValidationResult._(this.user, this.reason, {this.recoverable = false});

  const ValidationResult.ok(StoredUser user) : this._(user, null);
  const ValidationResult.denied(String reason, {bool recoverable = false})
      : this._(null, reason, recoverable: recoverable);

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
  final _inFlight = <String, _Validation>{};

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
      // Nothing is waiting on this, so an error has nowhere to go but the
      // root zone — where it kills the isolate. A momentary database fault
      // must not take the server down with it.
      unawaited(_guard(sweep(), 'the revalidation sweep failed'));
    });
  }

  /// Swallows and logs a failure from a future nobody is awaiting.
  static Future<void> _guard(Future<void> work, String what) =>
      work.catchError((Object e) => _log.warning('$what: $e'));

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Checks [user], talking to the provider only when the last confirmation
  /// has gone stale.
  /// [interactive] says whether the caller can act on a prompt.
  ///
  /// A browser session can: telling its owner to sign in again is something
  /// they are present to do. A bearer credential cannot — whoever holds it
  /// is a CI job, and the account owner may not be at a keyboard at all. So
  /// a credential check never writes `needsSignIn` and never revokes browser
  /// sessions: one `dart pub publish` from CI used to sign the owner out of
  /// every browser they had open, a write side effect on somebody else's
  /// account triggered by what should be a read-only check.
  Future<ValidationResult> ensureValid(StoredUser user,
      {bool interactive = true}) async {
    if (!user.isActive) {
      return ValidationResult.denied(
          user.blockedReason ?? 'access has been withdrawn',
          // `needsSignIn` is a prompt, not a withdrawal, and the two are
          // answered differently: one offers the sign-in that fixes it.
          recoverable: user.needsSignIn);
    }

    var age = _validationAge(user);
    if (age < config.revalidateInterval) return ValidationResult.ok(user);

    // Still comfortably inside the window: serve this request from what we
    // know and refresh in the background, so revalidation never sits in front
    // of a user's page load.
    if (age < config.revalidateHard &&
        user.validationFailures < config.revalidateMaxFailures) {
      unawaited(_guard(_validate(user, interactive: interactive),
          'background revalidation of ${user.id} failed'));
      return ValidationResult.ok(user);
    }

    // Past the window: the answer has to be current before we serve anything.
    var refreshed = await _validate(user, interactive: interactive);
    if (refreshed == null) {
      var current = await store.getUser(user.id);
      // A real refusal — the provider said no, or the groups no longer allow
      // it — is recorded on the account, and refuses here whoever is asking.
      // A null with the account still active means something else entirely:
      // there was nothing to ask the provider *with*, because the stored
      // refresh token no longer decrypts. That is a lost or rotated
      // `INPUB_AUTH_SESSION_SECRET` — an operator's mistake, and evidence
      // about the deployment rather than about the account. Refusing a
      // credential over it on the first request stopped every CI job at
      // once, so it does not; the next browser sign-in re-encrypts a token
      // and clears the state.
      //
      // Bounded, though, which is what this branch used to get wrong. It
      // wrote nothing at all, so `lastValidatedAt` and `validationFailures`
      // never moved: the same branch was taken on every later request, the
      // provider was never consulted about that account again, and an
      // account disabled upstream went on publishing and reading private
      // packages for as long as the deployment ran. `_doValidate` now counts
      // each unconfirmable credential check against the same
      // `--auth-revalidate-max-failures` budget an unreachable provider
      // spends, so the grace is a handful of requests rather than forever.
      // The two are not the same evidence — one is the operator's mistake,
      // the other the provider's outage, and only the outage arrives here
      // non-null and held to the age deadline below — but they carry the
      // same risk, and the risk is what is worth bounding: in both, this
      // server cannot tell whether the account is still allowed.
      //
      // By count and not by age, deliberately. Reaching this branch at all
      // means the record is already past `--auth-revalidate-hard`, so an age
      // test here would refuse on the very first request — and a lost
      // `INPUB_AUTH_SESSION_SECRET` puts every account in the deployment
      // here at once, which is the cliff that stopped all of CI the last
      // time this was tried.
      //
      // `current != null` is load-bearing, not decoration. Read the other
      // way — no record, so nothing says the account is blocked — this
      // served a credential on the stale pre-deletion copy still held in
      // memory, after admin cleanup, a half-finished migration or a dropped
      // collection. A deleted record is the plainest withdrawal there is.
      if (current != null && current.isActive && !interactive) {
        if (current.validationFailures < config.revalidateMaxFailures) {
          _log.warning('could not confirm ${user.id} while checking a '
              'credential; serving on the stored record '
              '(${current.validationFailures} of '
              '${config.revalidateMaxFailures} attempts spent)');
          return ValidationResult.ok(current);
        }
        _log.warning('refusing a credential for ${user.id}: '
            '${current.validationFailures} checks in a row could not confirm '
            'the account');
        return ValidationResult.denied(
            'this server has not been able to confirm your account with the '
            'identity provider; sign in to it again from a browser to '
            'restore access');
      }
      return ValidationResult.denied(
          current?.blockedReason ?? 'access has been withdrawn',
          // The validation that just ran may have landed on `needsSignIn`,
          // which is the state this very method creates when there is
          // nothing left to re-check the account with.
          recoverable: current?.needsSignIn ?? false);
    }
    if (_validationAge(refreshed) >= config.revalidateHard ||
        refreshed.validationFailures >= config.revalidateMaxFailures) {
      // The provider is unreachable rather than saying no. Refusing is the
      // conservative answer: otherwise an outage becomes an indefinite
      // extension for accounts that may already have been revoked.
      //
      // Bearer credentials included, deliberately. They used to be waved
      // through here on the grounds that a CI job cannot act on a prompt —
      // but this is not a prompt, it is the deadline `--auth-revalidate-hard`
      // exists to impose, and with `--auth-protect-pub-api` a token is the
      // only credential there is. Exempting them meant an account disabled
      // during an outage kept publishing for as long as the outage lasted,
      // while the flag's help text promised the opposite. Nothing is written
      // to the account here, so a credential still never signs its owner out
      // of a browser; it is simply not served until the provider answers.
      //
      // This is the age half of that promise only. An account with nothing
      // left to re-check it with never reaches here — `_validate` answers
      // null for it — and is held to the failure budget in the branch above
      // instead, because on that path the age is past the deadline from the
      // first request onwards.
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
    // Two independent purges, two try blocks. Sharing one meant a failure
    // on the first silently skipped the second for that cycle — and if the
    // condition persisted, dead tokens accumulated forever while the log
    // only ever mentioned sessions.
    try {
      var purged = await store.purgeExpiredSessions(config.sessionIdle);
      if (purged > 0) _log.fine('purged $purged expired session(s)');
    } catch (e) {
      _log.warning('failed to purge expired sessions: $e');
    }
    try {
      var deadTokens = await store.purgeDeadTokens(config.tokenRetention);
      if (deadTokens > 0) _log.fine('purged $deadTokens dead token(s)');
    } catch (e) {
      _log.warning('failed to purge dead tokens: $e');
    }

    List<StoredUser> users;
    try {
      users = await store.usersWithLiveSessions(config.sessionIdle);
    } catch (e) {
      _log.warning('failed to list users with live sessions: $e');
      return;
    }

    for (var user in users) {
      // One user's trouble must not abandon the rest of the sweep, and this
      // whole method runs unawaited: an escape here reaches the root zone.
      try {
        if (!user.isActive) {
          // Blocked but still holding sessions: finish the job the blocking
          // started, in case revoking them failed at the time.
          await store.revokeUserSessions(
              user.id, user.blockedReason ?? 'access withdrawn');
          continue;
        }
        if (_validationAge(user) < config.revalidateInterval) continue;
        await _validate(user);
      } catch (e) {
        _log.warning('could not revalidate ${user.id} during the sweep: $e');
      }
    }
  }

  Future<StoredUser?> _validate(StoredUser user, {bool interactive = true}) {
    var existing = _inFlight[user.id];
    // Joining is only safe towards the stricter answer. A credential check
    // deliberately leaves an account it cannot confirm alone — it will not
    // mark `needsSignIn`, because nobody at a CI job can act on a prompt —
    // so a browser that joined one was told access had been withdrawn, with
    // no sign-in link and nothing recorded to make the next page load say
    // anything else. The reverse direction is fine: an interactive check is
    // the more thorough of the two, and its answer holds for a credential.
    if (existing != null && (existing.interactive || !interactive)) {
      return existing.result;
    }
    // Queued behind the running check rather than started alongside it: the
    // two would refresh the same grant, and the loser of that race retires
    // the token the winner just stored.
    var future = existing == null
        ? _doValidate(user, interactive: interactive)
        : existing.result.then((_) => _afterCredentialCheck(user.id));
    var entry = _Validation(future, interactive);
    _inFlight[user.id] = entry;
    return future.whenComplete(() {
      // By identity: a check queued behind this one has already taken the
      // slot, and removing it would let a third caller start a second
      // concurrent refresh.
      if (identical(_inFlight[user.id], entry)) _inFlight.remove(user.id);
    });
  }

  /// The interactive check a browser was owed, run once the credential check
  /// in front of it has finished.
  ///
  /// The record is read again rather than reused: the run we waited for may
  /// have rotated the refresh token, and asking the provider with the
  /// retired one answers `invalid_grant` — which this class reads as a
  /// revocation and blocks the account over.
  Future<StoredUser?> _afterCredentialCheck(String id) async {
    var current = await store.getUser(id);
    if (current == null) return null;
    // That run may have confirmed the account outright, in which case there
    // is nothing an interactive one would do differently and no reason to
    // spend a second round trip on the provider.
    if (current.isActive &&
        _validationAge(current) < config.revalidateInterval) {
      return current;
    }
    return _doValidate(current);
  }

  Future<StoredUser?> _doValidate(StoredUser user,
      {bool interactive = true}) async {
    var encrypted = user.refreshTokenEnc;
    var refreshToken = encrypted == null ? null : crypto.decrypt(encrypted);
    if (refreshToken == null) {
      // Nothing left to ask the provider with. Ending the sessions forces a
      // fresh sign-in, which is what restores the ability to check — but the
      // account is not blocked over it. Saying the provider revoked them
      // would be untrue, would show that way on the administration screen,
      // and would leave an administrator no way back. An account blocked by
      // an older build, which discarded the token, arrives here too.
      if (!interactive) {
        // A credential check. Nobody here can act on a prompt, and marking
        // the account would sign its owner out of every browser they have
        // open — from a `dart pub publish` they did not run. So the status
        // and the sessions are left exactly as they are; the next browser
        // request reaches the branch below and prompts properly.
        //
        // The *attempt* is recorded, though. Leaving no trace at all is what
        // let this state be served forever: the age never moved, the failure
        // count never moved, and so no bound `ensureValid` has could ever
        // bite. Counting it against the same budget as an unreachable
        // provider is honest — the cause is different, the risk is the same
        // one, that this server cannot confirm the account — and it is the
        // only bound available here, since the age is past the hard deadline
        // from the first such request onwards.
        //
        // Capped rather than left to climb: once the budget is spent every
        // request is refused anyway, so counting further would buy a
        // database write per refused request and nothing else.
        if (user.validationFailures < config.revalidateMaxFailures) {
          await store.recordValidation(user.id,
              failures: user.validationFailures + 1);
        }
        _log.info('${user.id} has nothing left to revalidate with; leaving '
            'the account alone because this is a credential check');
        return null;
      }
      _log.info('${user.id} has nothing left to revalidate with; ending '
          'their sessions and asking them to sign in again');
      await store.setUserStatus(user.id, UserStatus.needsSignIn,
          reason: 'please sign in again to confirm your account');
      await store.revokeUserSessions(user.id, 'please sign in again');
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

    // The provider may have moved this address. A service token minted for
    // it earlier was checked against accounts and uploader lists at the
    // time, and nothing re-runs that check — so two credentials would now
    // publish as one identity, one of which no upstream block can stop.
    // Not silently repaired: which one is wrong is a judgement, and both
    // belong to somebody. Surfaced instead, loudly.
    if (fresh.email.trim().isNotEmpty &&
        normalizeAddress(fresh.email) != normalizeAddress(user.email)) {
      await warnOnServiceTokenClash(store, fresh.email, user.id);
    }

    // Not `fresh.email` unconditionally. A provider that stops sending the
    // `email` claim — a scope dropped on the client, a directory entry with
    // the field cleared — answers with an empty one, and writing that over a
    // good stored address is not a correction: `findUsersByEmail` then finds
    // nothing for that record, so a *blocked* publisher's legacy Google
    // credential reads as "maps to nobody here" and is accepted as
    // provisional, and every such account collapses onto the `uploader: ''`
    // identity the token-issue guard exists to keep empty. Keeping what we
    // last knew is the safe answer either way: the account is still
    // identified by `sub`, and the next userinfo that carries an address
    // updates it.
    var address = fresh.email.trim();
    if (address.isEmpty) {
      _log.warning('the identity provider reported no email address for '
          '${user.id}; keeping the one already on record');
    }

    var rotated = tokens.refreshToken;
    await store.recordValidation(
      user.id,
      validatedAt: DateTime.now(),
      failures: 0,
      refreshTokenEnc: rotated == null ? null : crypto.encrypt(rotated),
      groups: fresh.groups,
      email: address.isEmpty ? null : fresh.email,
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

/// A revalidation currently running, and whether it may prompt.
class _Validation {
  final Future<StoredUser?> result;
  final bool interactive;

  const _Validation(this.result, this.interactive);
}

/// Logs when an account takes on an address a live service token already
/// publishes under.
///
/// Both ends of the collision have to ask, and neither is the check that
/// mints a token: `_checkServiceAddress` refuses a token that would take an
/// address an account already holds, and nothing re-runs it when the account
/// arrives second — either by changing address, which the revalidator sees,
/// or by signing in for the first time, which only the callback sees.
///
/// Not silently repaired: which of the two is wrong is a judgement, and both
/// belong to somebody. Refusing the sign-in would be worse still, since it
/// locks a person out over a token an administrator minted.
///
/// A blank address is not a collision and is not asked about here rather
/// than at each call site. `storedAddressPattern('')` is `^\s*\s*$`, which
/// no index can serve — so a provider that stops sending the `email` claim
/// would have every first sign-in scan the whole token collection — and it
/// matches any legacy row whose address is empty, producing a SEVERE about
/// an account that "now uses " followed by nothing.
Future<void> warnOnServiceTokenClash(
    AuthStore store, String email, String userId) async {
  if (email.trim().isEmpty) return;
  try {
    for (var token in await store.serviceTokensForEmail(email)) {
      _log.severe('account $userId now uses $email, which service token '
          '"${token.name}" (${token.id}) also publishes as. Two credentials '
          'now write to that identity and blocking the account will not '
          'stop the token; revoke it or give it another address.');
    }
  } catch (e) {
    _log.warning('could not check service tokens for an address clash: $e');
  }
}

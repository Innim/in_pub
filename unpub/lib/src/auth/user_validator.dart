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

  /// Whether the check could not be run at all, as opposed to reaching a
  /// verdict about the account.
  ///
  /// A refusal either way — a store this server cannot read is no evidence
  /// that the account is still permitted — but a refusal that says nothing
  /// about the account must not be acted on as though it did. What acts on
  /// it is [SessionManager.resolve], which drops the browser's cookie on
  /// every other refusal because every other refusal means the session is
  /// finished: blocked, ungrouped, past the deadline. Here the session row
  /// is perfectly good and this server merely could not read it, so dropping
  /// the cookie would turn a one-second database fault into a forced
  /// sign-in for every browser that made a request during it — where the
  /// same fault, before there was a handler at all, left the cookie alone
  /// and a reload afterwards simply worked.
  final bool inconclusive;

  const ValidationResult._(this.user, this.reason,
      {this.recoverable = false, this.inconclusive = false});

  const ValidationResult.ok(StoredUser user) : this._(user, null);
  const ValidationResult.denied(String reason, {bool recoverable = false})
      : this._(null, reason, recoverable: recoverable);

  /// Refused because the check itself could not be completed.
  ///
  /// Never [recoverable]: signing in again runs the same check against the
  /// same store and fails in the same place.
  const ValidationResult.unavailable(String reason)
      : this._(null, reason, inconclusive: true);

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

  /// Refusals this process reached but deliberately did not write down.
  ///
  /// A credential check refuses without touching the record, which leaves
  /// the next request nothing to read — and "nothing" inside the soft window
  /// means the stored record is served once more. The refusal would be
  /// rediscovered and thrown away on every request until the hard deadline,
  /// which is no bound at all for a credential. Remembered here instead:
  /// in memory, on this isolate, keyed by user.
  ///
  /// Deliberately not durable, and the bound that follows is worth stating
  /// plainly. The reason for not writing is that this evidence can be wrong
  /// — `invalid_grant` is also what a *spent* refresh token earns, which is
  /// what a credential check racing a rotation produces — so it must not
  /// outlive the process that saw it. After a restart the account gets the
  /// soft window's grace back, until the hard deadline or the next
  /// interactive check, exactly as it would after a provider outage.
  ///
  /// Bounded in size by the accounts that exist, the keys being ids the
  /// store handed out, and each entry is dropped the next time the account
  /// is looked at once something has re-established it — see [_refusalFor]
  /// for what counts as that, and what deliberately does not.
  final _refusals = <String, _Refusal>{};

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
  /// a credential check never writes `needsSignIn`, never records a block
  /// and never revokes browser sessions: one `dart pub publish` from CI used
  /// to sign the owner out of every browser they had open, a write side
  /// effect on somebody else's account triggered by what should be a
  /// read-only check.
  ///
  /// Refusing is a different matter, and a credential check still does it.
  /// An account the provider has stopped vouching for, or one the allowed
  /// groups no longer cover, is refused whoever is asking. Writing nothing
  /// is not the same as forgetting, though: the refusal is remembered in
  /// [_refusals] for as long as this process runs, and consulted below
  /// before either age branch. Without that the soft window answers the next
  /// request from the same untouched record and revalidates in the
  /// background again — discovering the same refusal, discarding it again —
  /// so a revoked credential would go on publishing until
  /// `--auth-revalidate-hard`, which can be hours.
  ///
  /// Only the *record* waits, and only for somebody who can be told: the
  /// next interactive check writes the block and ends the sessions, or the
  /// sweep does, which re-checks precisely the accounts that have sessions
  /// to lose and reaches them within `--auth-revalidate-interval`.
  Future<ValidationResult> ensureValid(StoredUser user,
      {bool interactive = true}) async {
    try {
      return await _ensureValid(user, interactive: interactive);
    } catch (e, stack) {
      // A store fault, not a verdict. Everything below reads or writes the
      // account — `setUserStatus`, `revokeUserSessions`, `recordValidation`,
      // the `getUser` that reads the result back — and none of it used to be
      // caught anywhere: not here, not in `SessionManager.resolve`, not in
      // `TokenService.resolve`, not in the gate. A momentary database fault
      // on any one of them left the request with an unhandled exception, and
      // a bare 500 is the one answer neither caller can do anything with. The
      // web UI reports that the server did not answer with JSON; `dart pub`
      // prints an opaque server error where this server knows perfectly well
      // what to tell the publisher. Both callers already turn a *refusal*
      // into something actionable, so the repair is to give them one.
      //
      // Refused rather than served. "The database is unreachable" is not
      // evidence that the account is still permitted, and this is the same
      // reasoning the hard deadline below rests on: an outage must not become
      // an indefinite extension for an account that may already have been
      // revoked.
      //
      // Not recoverable, deliberately, so no sign-in is offered. Signing in
      // again does not fix a store that is down — it would take the same trip
      // through the identity provider and fail on the same write at the far
      // end — and offering it invites somebody to spend a minute proving they
      // are still themselves to answer a question nobody asked. The wording
      // says the thing that actually helps, which is waiting. It is written
      // to read sensibly both on the access-denied page and after `dart pub`'s
      // 401.
      //
      // `unavailable` rather than `denied` so that the browser keeps its
      // cookie: this refusal is about the deployment, and a caller that
      // treats it as a verdict on the session would make a momentary fault
      // cost everyone a sign-in. See [ValidationResult.inconclusive].
      //
      // Nothing is written down, and in particular no `_refusals` note. That
      // map is retired only by something that re-establishes the account, so
      // a note left by a momentary fault would go on refusing the credential
      // long after the store came back — the account would have to be
      // confirmed against the provider to clear a verdict the provider never
      // gave. `_refuse` is the only thing that writes one: its credential
      // branch touches no store at all, and its interactive branch drops the
      // note before its first write, so an exception from either leaves the
      // map clean.
      //
      // The queued-behind join is covered by sitting here rather than around
      // any single call. A second caller that joined a running check inherits
      // the first one's error through `existing.result.then(...)`, so one
      // fault can reach several concurrent requests; each of them comes back
      // through this handler with its own refusal.
      _log.severe(
          'could not check ${user.id} against the store; refusing the '
          'request rather than serving it unchecked',
          e,
          stack);
      return ValidationResult.unavailable(
          'this server could not confirm your account just now; please try '
          'again in a moment');
    }
  }

  Future<ValidationResult> _ensureValid(StoredUser user,
      {required bool interactive}) async {
    if (!user.isActive) {
      return ValidationResult.denied(
          user.blockedReason ?? 'access has been withdrawn',
          // `needsSignIn` is a prompt, not a withdrawal, and the two are
          // answered differently: one offers the sign-in that fixes it.
          recoverable: user.needsSignIn);
    }

    // A refusal this process has already reached for this account on a
    // check that deliberately wrote nothing down. It has to be answered
    // before the age branches below, because both of them read the stored
    // record — and the stored record is exactly what that refusal declined
    // to touch.
    //
    // Credentials only. A browser request goes on doing the real check: the
    // note is an unverified answer, possibly from a check that raced a token
    // rotation, and refusing a person their own UI on it — with no block
    // recorded, so no sign-in offered and nothing to explain it — is the
    // write-free version of the harm this whole path exists to avoid.
    if (!interactive) {
      var remembered = _refusalFor(user);
      if (remembered != null) return ValidationResult.denied(remembered);
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
    var verdict = await _validate(user, interactive: interactive);
    var refusal = verdict.refusal;
    if (refusal != null) {
      // A definite no: the provider stopped vouching for the account, or the
      // allowed groups no longer cover it. Whether that has been written
      // onto the record depends on who asked — an interactive check blocks,
      // a credential check deliberately leaves the account alone — but this
      // request is refused with the same words either way.
      return ValidationResult.denied(refusal);
    }
    var refreshed = verdict.user;
    if (refreshed == null) {
      var current = await store.getUser(user.id);
      // Not a refusal: those return above, with their reason in hand. A null
      // here is the check failing to reach an answer at all — most often
      // because there was nothing to ask the provider *with*, since the
      // stored refresh token no longer decrypts. That is a lost or rotated
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

  /// The refusal remembered for [user], if it still stands.
  ///
  /// Retired by anything that re-establishes the account, none of which is
  /// visible from here: a successful revalidation, a fresh sign-in, an
  /// administrator unblocking or restoring it. Without that an administrator
  /// putting access back would leave CI refused until somebody happened to
  /// sign in from a browser.
  ///
  /// The version to compare is the pair of fields that carry a verdict —
  /// `status` and `lastValidatedAt` — and *not* `updatedAt`, which was the
  /// first attempt and was wrong. `updatedAt` moves on every write including
  /// the one that says nothing: an unreachable provider records a failure
  /// count, and that alone would have retired a definite refusal, handing the
  /// credential back the soft window's grace on the strength of an outage.
  /// Precisely the event that establishes nothing must not clear a verdict.
  ///
  /// Equality, not "later than". An administrator unblocking an account
  /// deliberately backdates `lastValidatedAt` to the epoch, so that the next
  /// request has to prove it against the provider; a note that only stood
  /// down for newer timestamps would have survived exactly the action meant
  /// to restore access. A changed `--auth-allowed-groups` needs no rule at
  /// all: it is a startup flag, so changing it restarts the process and
  /// every note goes with it.
  String? _refusalFor(StoredUser user) {
    var noted = _refusals[user.id];
    if (noted == null) return null;
    if (!noted.stillStandsFor(user)) {
      _refusals.remove(user.id);
      return null;
    }
    return noted.reason;
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

  Future<_Verdict> _validate(StoredUser user, {bool interactive = true}) {
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
  Future<_Verdict> _afterCredentialCheck(String id) async {
    var current = await store.getUser(id);
    if (current == null) return const _Verdict.checked(null);
    // That run may have confirmed the account outright, in which case there
    // is nothing an interactive one would do differently and no reason to
    // spend a second round trip on the provider.
    if (current.isActive &&
        _validationAge(current) < config.revalidateInterval) {
      return _Verdict.checked(current);
    }
    return _doValidate(current);
  }

  Future<_Verdict> _doValidate(StoredUser user,
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
        return const _Verdict.unconfirmed();
      }
      _log.info('${user.id} has nothing left to revalidate with; ending '
          'their sessions and asking them to sign in again');
      await store.setUserStatus(user.id, UserStatus.needsSignIn,
          reason: 'please sign in again to confirm your account');
      await store.revokeUserSessions(user.id, 'please sign in again');
      return const _Verdict.unconfirmed();
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
      return await _refuse(
          user,
          'your account is no longer authorised on the '
          'identity provider',
          interactive: interactive);
    } on IdentityUnavailableException catch (e) {
      // An unreachable provider is not a revocation. Count it and keep the
      // user working until the hard deadline says otherwise.
      var failures = user.validationFailures + 1;
      _log.warning('could not revalidate ${user.id} '
          '(attempt $failures): ${e.message}');
      await store.recordValidation(user.id, failures: failures);
      return _Verdict.checked(await store.getUser(user.id));
    }

    if (!config.isAllowedGroup(fresh.groups)) {
      _log.info('access revoked for ${user.id}: no longer in an allowed group');
      return await _refuse(
          user,
          'your account is no longer a member of a group with '
          'access to this server',
          interactive: interactive);
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
    // Confirmed, so any refusal remembered for this account is out of date.
    // `_refusalFor` would retire it on the next request anyway — the write
    // above moves `updatedAt` — but dropping it here keeps the map to the
    // accounts actually being refused.
    _refusals.remove(user.id);
    return _Verdict.checked(await store.getUser(user.id));
  }

  /// Turns a definite refusal into a verdict, blocking the account when
  /// there is somebody present to be told.
  ///
  /// [interactive] decides that, and it decides nothing about the refusal
  /// itself: the caller is refused either way. What it governs is the two
  /// writes — the status an administrator reads, and the end of every
  /// browser session the account holds.
  ///
  /// A credential check makes neither. Whoever is holding the credential is
  /// a CI job, and signing the account's owner out of every browser they had
  /// open — from a `dart pub publish` they did not run and cannot answer — is
  /// a write side effect on somebody else's account, produced by what should
  /// be a read-only check. The evidence is also not always as firm as it
  /// looks here: `invalid_grant` is what the provider says about a refresh
  /// token that was merely *spent*, which is exactly what a credential check
  /// racing a rotation produces, and reading that as a revocation would end
  /// the sessions of a perfectly valid user.
  ///
  /// The refusal is not forgotten for being unwritten: it goes into
  /// [_refusals], which `ensureValid` consults ahead of both age branches,
  /// so every later credential check is refused straight away and without a
  /// second round trip. That is the part which cannot be left out — a
  /// refusal reached inside the soft window is reached by the *background*
  /// check, whose answer nobody is waiting for, and with neither a write nor
  /// a note it would be rediscovered and dropped on every request until the
  /// hard deadline.
  ///
  /// The block itself is the next interactive check's to write, or the
  /// sweep's, which re-checks exactly the accounts holding live sessions and
  /// gets to them within `--auth-revalidate-interval`. An account with no
  /// sessions is never swept and so stays `active` on the administration
  /// screen until somebody signs in — but it has nothing to lose either, and
  /// its credential goes on being refused for as long as this process runs.
  Future<_Verdict> _refuse(StoredUser user, String reason,
      {required bool interactive}) async {
    if (!interactive) {
      _refusals[user.id] = _Refusal(reason,
          status: user.status, confirmedAt: user.lastValidatedAt);
      _log.warning('refusing a credential for ${user.id}: $reason. The '
          'account is left as it is: a credential check must not sign its '
          'owner out of the browsers they have open');
      return _Verdict.refused(reason);
    }
    _refusals.remove(user.id);
    await store.setUserStatus(user.id, UserStatus.blockedUpstream,
        reason: reason);
    var ended = await store.revokeUserSessions(user.id, reason);
    _log.info('ended $ended session(s) for ${user.id}');
    return _Verdict.refused(reason);
  }
}

/// A revalidation currently running, and whether it may prompt.
class _Validation {
  final Future<_Verdict> result;
  final bool interactive;

  const _Validation(this.result, this.interactive);
}

/// A refusal reached without writing it onto the account.
class _Refusal {
  /// What to tell the next credential that presents itself.
  final String reason;

  /// The account's state when this was reached, in the only two fields that
  /// say anything about whether it is allowed. A failure count is not among
  /// them on purpose: an unreachable provider moves it, and an outage is not
  /// evidence that a revoked account has been reinstated.
  final UserStatus status;
  final DateTime? confirmedAt;

  const _Refusal(this.reason,
      {required this.status, required this.confirmedAt});

  /// Whether nothing has happened since that would supersede this refusal.
  bool stillStandsFor(StoredUser user) =>
      user.status == status && user.lastValidatedAt == confirmedAt;
}

/// What one revalidation run concluded.
///
/// Three answers, not two. "Still allowed" carries the refreshed record;
/// "not allowed" carries the reason; "could not tell" carries neither. The
/// last two used to share a bare null, and `ensureValid` told them apart by
/// re-reading the account and looking for a block — which worked only for as
/// long as every refusal wrote one. A credential check refuses without
/// writing anything, so the difference has to be carried rather than
/// inferred; inferred, it read as "could not confirm" and handed a revoked
/// account the grace that branch extends to an operator's lost signing key.
class _Verdict {
  /// The account as it now stands, when nothing objected to it. Null when
  /// the check reached no answer — or when the record has since gone.
  final StoredUser? user;

  /// Why access is refused, when the answer was a definite no.
  final String? refusal;

  const _Verdict.checked(this.user) : refusal = null;
  const _Verdict.unconfirmed()
      : user = null,
        refusal = null;
  const _Verdict.refused(String this.refusal) : user = null;
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

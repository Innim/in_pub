import 'package:logging/logging.dart';

import '../address.dart';
import 'auth_config.dart';
import 'auth_store.dart';
import 'crypto_box.dart';
import 'identity.dart';
import 'user_validator.dart';

final _log = Logger('in_pub.auth.token');

/// A freshly issued token. [value] is the only time the secret exists in a
/// readable form; only its hash is kept.
class IssuedToken {
  final StoredToken record;
  final String value;

  const IssuedToken(this.record, this.value);
}

/// The outcome of examining a bearer token.
class TokenResolution {
  /// Who the token speaks for, or null if it does not speak for anyone.
  final AuthenticatedUser? user;

  final StoredToken? token;

  /// Why it was refused, phrased for the person who will read it in their
  /// terminal.
  final String? message;

  /// Whether the value even looked like one of ours. A value that is not
  /// ours is not a failure — it may belong to another accepted scheme.
  final bool recognised;

  /// Accepted, but speaking for an address this server has no account for.
  ///
  /// Only the legacy Google credential can be this: it proves somebody holds
  /// a Google account and nothing more. Publishing to a package that already
  /// exists is still bounded by its uploader list, but creating a new one is
  /// not bounded by anything, so that is refused for a provisional caller.
  final bool provisional;

  const TokenResolution._(
      {this.user,
      this.token,
      this.message,
      this.recognised = true,
      this.provisional = false});

  /// [token] is absent when the credential was accepted by another
  /// scheme — the legacy Google path — which has no record here.
  const TokenResolution.accepted(AuthenticatedUser user,
      {StoredToken? token, bool provisional = false})
      : this._(user: user, token: token, provisional: provisional);

  const TokenResolution.refused(String message) : this._(message: message);

  const TokenResolution.notOurs() : this._(recognised: false);

  bool get isAccepted => user != null;
}

/// Raised when a token may not be issued for the identity it would carry.
///
/// [message] is written for whoever asked, because the account screen shows
/// it back to them.
class TokenIssueRefused implements Exception {
  final String message;

  TokenIssueRefused(this.message);

  @override
  String toString() => 'TokenIssueRefused: $message';
}

/// Issues and checks the bearer tokens the pub client uses.
///
/// `dart pub` cannot perform a browser redirect, so it carries a static
/// credential and nothing else. That credential is minted here after signing
/// in through the identity provider, which is the only part of the flow a
/// browser is involved in.
class TokenService {
  final AuthConfig config;
  final AuthStore store;
  final UserValidator validator;

  /// Prefix on every token we issue. Not a security measure — it makes a
  /// leaked token recognisable to a secret scanner, and lets an unfamiliar
  /// credential be rejected without a database lookup.
  static const prefix = 'inpub_';

  /// How stale `lastUsedAt` is allowed to get. A CI run makes many requests
  /// with the same token and none of them need their own write.
  static const _touchInterval = Duration(minutes: 5);

  /// Acceptances this process may answer again without going to the store.
  /// Keyed by the hash of the whole presented value. See [resolve].
  final _accepted = <String, _Accepted>{};

  /// How many times something has been withdrawn from this cache.
  ///
  /// Not a statistic. Dropping an entry when a revocation commits closes the
  /// obvious half of the race and leaves the other half open: a request that
  /// was already resolving reads a row that is still live, is legitimately
  /// accepted, and writes its acceptance *after* the drop — handing a token
  /// that has just been revoked another full window. So a resolution notes
  /// the count it began in and refuses to write if it has moved. See
  /// [_remember].
  ///
  /// Deliberately one counter rather than per token or per account. Being
  /// coarse costs an uncached resolution for whoever happened to be in
  /// flight during a revoke; being precise costs a second structure that has
  /// to be right about a race, which is the kind of bookkeeping this whole
  /// change exists to avoid. Withdrawals are human-scale events.
  int _withdrawals = 0;

  /// At most this many remembered acceptances.
  ///
  /// The keys are hashes of values a caller supplies, so the size of this
  /// map has to be somebody's decision rather than a consequence of who
  /// turns up. Only an *accepted* credential is ever written here, which
  /// already bounds it by the number of live tokens the store holds — but
  /// that number belongs to the deployment and a fleet minting one token per
  /// job can make it large, so it is bounded here too. Reached only when
  /// that many distinct tokens are in use within one [AuthConfig.credentialCache]
  /// window, and the answer then is to drop what has expired and, failing
  /// that, to start over: entries live seconds, so an empty map costs one
  /// extra pair of reads per token and nothing more.
  static const _cacheLimit = 1024;

  TokenService({
    required this.config,
    required this.store,
    required this.validator,
  });

  /// Whether [value] is shaped like a token of ours, so a caller can decide
  /// whether to try another scheme instead.
  static bool looksLikeOurs(String value) => value.startsWith(prefix);

  /// A token that carries its owner's identity.
  ///
  /// The owner's address is not taken on trust any more than a service
  /// token's is: it comes from the provider, and a provider with no `email`
  /// claim hands over an empty one. See [_issue].
  Future<IssuedToken> issuePersonal({
    required StoredUser owner,
    required String name,
    Duration? lifetime,
  }) =>
      _issue(
        kind: TokenKind.personal,
        userId: owner.id,
        email: owner.email,
        displayName: owner.displayName,
        name: name,
        createdBy: owner.id,
        lifetime: lifetime,
      );

  /// A token belonging to no provider account.
  ///
  /// Meant for automation that must keep working when the person who set it
  /// up leaves. Nothing upstream can revoke it, so [createdBy] records who
  /// to ask about it.
  Future<IssuedToken> issueService({
    required String createdBy,
    required String name,
    required String email,
    required String displayName,
    Duration? lifetime,
  }) =>
      _issue(
        kind: TokenKind.service,
        email: email,
        displayName: displayName,
        name: name,
        createdBy: createdBy,
        lifetime: lifetime,
      );

  Future<IssuedToken> _issue({
    required TokenKind kind,
    required String email,
    required String displayName,
    required String name,
    required String createdBy,
    String? userId,
    Duration? lifetime,
  }) async {
    // The address is not decoration: it is recorded as the uploader of
    // everything published with this token, and it is what a package's
    // uploader list is matched against. A service token's is checked at the
    // point of entry, but a personal one was copied off the account without
    // a word — and an account on a provider that sends no `email` claim
    // carries an empty one, which is not an identity but a bucket every such
    // account shares: the first publish records `uploader: ''`, and the
    // second such person is on that list already.
    //
    // Folded first, and stored folded. The stored address is an identity
    // here and every comparison of one already folds it, so keeping the
    // provider's own spacing would only leave the record disagreeing with
    // the lookups — and would refuse a token outright to somebody whose
    // provider pads the claim, since padding is not part of an address.
    var identity = normalizeAddress(email);
    if (!looksLikeEmailAddress(identity)) {
      throw TokenIssueRefused(
          'This token would publish as ${identity.isEmpty ? 'no address at all' : '"$identity"'}, '
          'which is not an address a package can record an uploader as. It '
          'has to be a full one — an @ and a domain with a dot in it — so a '
          'single-label directory name like "ci@internal" will not do. An '
          'account gets its address from the identity provider, so ask an '
          'administrator to make sure the provider reports a real email '
          'address for it.');
    }

    // UTC because this record is answered to the client directly, without
    // the round trip through the database that would otherwise normalise it
    // — a local time serialises with no zone and is read as the browser's.
    var now = DateTime.now().toUtc();
    var id = CryptoBox.randomToken(12);
    var secret = CryptoBox.randomToken(32);
    var record = StoredToken(
      id: id,
      secretHash: CryptoBox.hash(secret),
      kind: kind,
      userId: userId,
      email: identity,
      displayName: displayName,
      name: name,
      createdBy: createdBy,
      createdAt: now,
      expiresAt: lifetime == null ? null : now.add(lifetime),
    );
    await store.createToken(record);
    _log.info('issued ${kind.name} token "$name" ($id) for '
        '${userId ?? identity} by $createdBy');
    return IssuedToken(record, '$prefix$id.$secret');
  }

  /// Checks a bearer value and returns who it speaks for.
  ///
  /// A personal token is only as good as its owner: the account is looked up
  /// and revalidated on every use, so blocking someone — here or on the
  /// identity provider — takes their tokens with it, without anything having
  /// to hunt them down. That also means unblocking restores them, which is
  /// why they are not revoked outright.
  ///
  /// That check costs two store reads — the token row and the account — and
  /// it used to be paid on every gated request. With
  /// `--auth-protect-pub-api` one `dart pub get` over a workspace makes
  /// hundreds of them, so an accepted answer is held for
  /// [AuthConfig.credentialCache] (seconds, and zero turns it off). What is
  /// and is not remembered is the whole of the design:
  ///
  /// * **Only acceptances.** A refusal is never written down here. Two
  ///   reasons, and either would be enough. An account blocked between two
  ///   requests has to stop working on the next one, which a remembered
  ///   refusal would delay exactly as much as it delays nothing else worth
  ///   having; and a refusal is the one answer an unauthenticated caller can
  ///   provoke at will, so remembering refusals would let anybody fill this
  ///   map with values they invented.
  /// * **Nothing inconclusive.** A store fault does not reach the write
  ///   below: every path that ends in a refusal — including
  ///   [ValidationResult.inconclusive], which says only that this server
  ///   could not ask — returns before it, and an exception from the store
  ///   leaves by the same door. So a momentary database fault is never
  ///   memoised as either an accept or a refuse.
  /// * **Nothing the validator has since taken back.** `UserValidator`
  ///   reaches refusals on its own schedule — a background revalidation
  ///   inside the soft window, or the sweep — and records them in a note map
  ///   rather than on the account. It calls [forgetUser] when it does, so an
  ///   acceptance remembered here can never contradict that note.
  /// * **Revocation is not left to the clock.** Revoking a token or blocking
  ///   an account through the account API drops the entry outright, so the
  ///   very next request fails. It is dropped twice — before the store write
  ///   and again after it — and a resolution that was already in flight is
  ///   refused the write altogether; between them those cover a request
  ///   landing on either side of the write. See [_withdrawals]. The window
  ///   this cache opens is for the paths nothing in this process sees: a row
  ///   edited in the database directly, or a second server sharing it. Those
  ///   are bounded by the TTL and by nothing else, which is why the TTL is
  ///   seconds.
  ///
  /// `lastUsedAt` keeps being recorded across a hit — see [_touch], which is
  /// called on both paths.
  Future<TokenResolution> resolve(String value, {String? ip}) async {
    if (!looksLikeOurs(value)) return const TokenResolution.notOurs();

    var body = value.substring(prefix.length);
    var cut = body.indexOf('.');
    if (cut <= 0 || cut == body.length - 1) {
      return const TokenResolution.refused('the token is malformed');
    }
    var id = body.substring(0, cut);
    var secret = body.substring(cut + 1);

    var now = DateTime.now();
    // The generation this resolution starts in. Everything below awaits —
    // two store reads and a revalidation — and a revoke or a block can land
    // in any of those gaps. See [_withdrawals].
    var asOf = _withdrawals;
    // Keyed on the whole value rather than on the id, so the cache cannot
    // stand in for the secret check below: a value carrying the wrong secret
    // hashes to a different key and misses, whoever else has presented the
    // real one.
    var key = CryptoBox.hash(value);
    var remembered = _accepted[key];
    if (remembered != null) {
      // Expiry is the one property of the record that can change on its own
      // — no request, no administrator, just the clock — so it is re-checked
      // rather than trusted from the read that made this entry.
      if (remembered.expiresAt.isAfter(now) &&
          !remembered.token.isExpired(now)) {
        await _touchRemembered(remembered, now, ip);
        return TokenResolution.accepted(remembered.user,
            token: remembered.token);
      }
      _accepted.remove(key);
    }

    var token = await store.getToken(id);
    if (token == null) {
      _log.info('rejected an unknown token id ($id)');
      return const TokenResolution.refused('this token is not recognised');
    }
    // The secret is checked before anything else is said about the token, so
    // a value that was merely guessed learns nothing beyond "no".
    if (token.secretHash.isEmpty ||
        !CryptoBox.constantTimeEquals(
            CryptoBox.hash(secret), token.secretHash)) {
      _log.warning('rejected token $id: wrong secret');
      return const TokenResolution.refused('this token is not recognised');
    }
    if (token.isRevoked) {
      return TokenResolution.refused(
          'this token has been revoked${token.revokedReason == null ? '' : ' (${token.revokedReason})'}');
    }

    if (token.isExpired(now)) {
      return const TokenResolution.refused(
          'this token has expired; create a new one');
    }

    AuthenticatedUser user;
    if (token.kind == TokenKind.service) {
      user = token.toAuthenticatedUser();
    } else {
      var owner = await store.getUser(token.userId ?? '');
      if (owner == null) {
        return const TokenResolution.refused(
            'the account this token belongs to no longer exists');
      }
      // A credential, not a browser: nobody here can act on a prompt, and
      // this must not sign the owner out of their browsers as a side effect.
      var validation = await validator.ensureValid(owner, interactive: false);
      var validated = validation.user;
      if (validated == null) {
        return TokenResolution.refused(validation.reason ??
            'the account this token belongs to no longer has access');
      }
      if (!config.isAllowedGroup(validated.groups)) {
        return const TokenResolution.refused(
            'the account this token belongs to no longer has access');
      }
      user = validated.toAuthenticatedUser();
    }

    // The rule that governs issuing, applied again on use. [_issue] checks
    // the address once, but `resolve` answers with the account as it stands
    // now: a provider that stopped sending the `email` claim leaves the
    // record carrying something that is not an identity, and this token —
    // perfectly legitimate when it was minted — then publishes as
    // `uploader: ''`, the one bucket every such account shares. A service
    // token minted by a build older than that check arrives here too.
    var identity = normalizeAddress(user.email);
    if (!looksLikeEmailAddress(identity)) {
      _log.warning('refused token ${token.id}: it would publish as '
          '${identity.isEmpty ? 'no address at all' : '"$identity"'}');
      return const TokenResolution.refused(
          'this token has no usable email address to record a publish '
          'against; ask an administrator to check the address on it, and '
          'that the identity provider reports a full one for the account — '
          'an @ and a domain with a dot in it, not a single-label directory '
          'name');
    }

    var lastUsedAt = token.lastUsedAt;
    if (await _touch(token.id, lastUsedAt, now, ip)) lastUsedAt = now;

    _remember(key, user, token, lastUsedAt, now, asOf);
    return TokenResolution.accepted(user, token: token);
  }

  /// Records this use, unless one was recorded recently enough.
  ///
  /// [lastUsedAt] is when this token was last written down: off the record
  /// on the path that read it, and off [_Accepted.lastUsedAt] on a cache
  /// hit. Answers whether it wrote.
  Future<bool> _touch(
      String id, DateTime? lastUsedAt, DateTime now, String? ip) async {
    // Purely by the clock. Letting a changed address force a write looks
    // thorough until a CI fleet shares one token behind a proxy: every
    // request then carries a different address, and resolving two hundred
    // dependencies costs two hundred writes on the request path.
    if (lastUsedAt != null && now.difference(lastUsedAt) < _touchInterval) {
      return false;
    }
    await store.touchToken(id, now, ip: ip);
    return true;
  }

  /// The same, for a request answered from [_accepted].
  ///
  /// A cache hit must not stop the account screen's "last used" column
  /// moving: it is what somebody looks at to decide whether a token is still
  /// in use before revoking it, and a credential that had quietly stopped
  /// being recorded would read as abandoned while a CI fleet used it every
  /// minute.
  ///
  /// The throttle is kept, and kept off the entry rather than off the
  /// snapshot it holds. That record is frozen at the moment it was read, so
  /// its own `lastUsedAt` would go on naming the same instant for as long as
  /// the entry lives — and once the interval had passed, every request would
  /// write. The entry remembers what this process actually wrote instead, so
  /// the write happens exactly as often as it did before there was a cache.
  Future<void> _touchRemembered(
      _Accepted entry, DateTime now, String? ip) async {
    if (await _touch(entry.token.id, entry.lastUsedAt, now, ip)) {
      entry.lastUsedAt = now;
    }
  }

  void _remember(String key, AuthenticatedUser user, StoredToken token,
      DateTime? lastUsedAt, DateTime now, int asOf) {
    var ttl = config.credentialCache;
    if (ttl <= Duration.zero) return;
    // Something was withdrawn while this resolution was in flight, so this
    // answer predates a decision that has since been taken. The answer
    // itself was correct when it was reached — the row was live — which is
    // precisely why it must not be kept: the request is served, and the next
    // one goes back to the store.
    if (_withdrawals != asOf) return;
    _accepted[key] = _Accepted(
      user: user,
      token: token,
      lastUsedAt: lastUsedAt,
      expiresAt: now.add(ttl),
    );
    if (_accepted.length > _cacheLimit) _prune(now);
  }

  void _prune(DateTime now) {
    _accepted.removeWhere((_, e) => !e.expiresAt.isAfter(now));
    // Still over the limit means that many tokens are genuinely in use at
    // once and dropping expired entries freed nothing. Start over rather
    // than grow without bound; entries only live seconds.
    if (_accepted.length > _cacheLimit) _accepted.clear();
  }

  /// Forgets any remembered acceptance of the token [id], so that the next
  /// request presenting it is answered from the store.
  ///
  /// Called when a token is revoked. Revocation is the one thing this cache
  /// must not delay, and this process is where both the revocation and the
  /// remembered answer live, so it does not have to wait for the clock.
  ///
  /// Only for this process, honestly. A second server sharing the database
  /// has its own map and learns of the revocation when its entry expires,
  /// which is what bounds the TTL to seconds.
  void forgetToken(String id) {
    _withdrawals++;
    _accepted.removeWhere((_, e) => e.token.id == id);
  }

  /// The same for every personal token belonging to [userId].
  ///
  /// Blocking an account has to stop its tokens on the very next request,
  /// not at the end of the window: the tokens are not revoked when somebody
  /// is blocked — that is deliberate, so unblocking restores them — so the
  /// only thing that stops them is the owner check this cache skips.
  ///
  /// Service tokens are untouched, and belong to nobody: `userId` is null on
  /// them, which is the whole point of the kind.
  void forgetUser(String userId) {
    _withdrawals++;
    _accepted.removeWhere((_, e) => e.token.userId == userId);
  }

  /// Forgets everything. For shutdown, and for a test that wants the next
  /// resolution to go to the store.
  void forgetEverything() {
    _withdrawals++;
    _accepted.clear();
  }
}

/// An acceptance this process may answer again without reading the store.
///
/// Only acceptances are ever kept; [TokenService.resolve] says why.
class _Accepted {
  /// Who the token speaks for, as the account stood when it was checked.
  final AuthenticatedUser user;

  /// The record as it was read. Its expiry is re-checked on every hit;
  /// nothing else about it can change within the entry's short life without
  /// something in this process dropping the entry outright.
  final StoredToken token;

  /// When this token's use was last written down. Mutable, and deliberately
  /// not read off [token]: see [TokenService._touchRemembered].
  DateTime? lastUsedAt;

  final DateTime expiresAt;

  _Accepted({
    required this.user,
    required this.token,
    required this.lastUsedAt,
    required this.expiresAt,
  });
}

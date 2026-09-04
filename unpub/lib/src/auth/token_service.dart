import 'package:logging/logging.dart';

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
  Future<TokenResolution> resolve(String value, {String? ip}) async {
    if (!looksLikeOurs(value)) return const TokenResolution.notOurs();

    var body = value.substring(prefix.length);
    var cut = body.indexOf('.');
    if (cut <= 0 || cut == body.length - 1) {
      return const TokenResolution.refused('the token is malformed');
    }
    var id = body.substring(0, cut);
    var secret = body.substring(cut + 1);

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

    var now = DateTime.now();
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

    await _touch(token, now, ip);
    return TokenResolution.accepted(user, token: token);
  }

  Future<void> _touch(StoredToken token, DateTime now, String? ip) async {
    // Purely by the clock. Letting a changed address force a write looks
    // thorough until a CI fleet shares one token behind a proxy: every
    // request then carries a different address, and resolving two hundred
    // dependencies costs two hundred writes on the request path.
    var last = token.lastUsedAt;
    if (last != null && now.difference(last) < _touchInterval) return;
    await store.touchToken(token.id, now, ip: ip);
  }
}

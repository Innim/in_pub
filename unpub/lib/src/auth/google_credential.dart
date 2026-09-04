import 'dart:io';

import 'package:googleapis/oauth2/v2.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

import 'crypto_box.dart';
import 'identity.dart';

final _log = Logger('in_pub.auth.google');

/// Checks the original Google credential — the one `unpub_auth` obtains, and
/// the only scheme a server running without `--auth` has.
///
/// A class of its own so that whoever needs it constructs one. It used to be
/// assigned into a field on `AuthService` from `App.serve`, which meant a
/// router mounted without `serve()` silently refused every such credential,
/// and two servers sharing an `AuthService` fought over the field.
class GoogleCredentialResolver {
  /// http(s) proxy to reach googleapis through, if any.
  final String? proxy;

  GoogleCredentialResolver({this.proxy});

  http.Client? _client;
  final _cache = <String, _CachedAnswer>{};

  /// At most this many remembered answers. Reached only when that many
  /// credentials are live at once, which a large fleet minting one per job
  /// can manage.
  static const _cacheLimit = 512;

  /// The address behind [token], or null if Google says it is not good.
  ///
  /// Throws [IdentityUnavailableException] when Google could not be reached:
  /// a network failure is not a refusal, and reporting it as one tells a
  /// publisher to reissue credentials over an outage that has probably
  /// already cleared.
  Future<String?> resolve(String token) async {
    // Remembered briefly. Only the publish handshake reaches this, so the
    // cache saves the two or three round trips one `dart pub publish` makes
    // rather than holding back a flood.
    var key = CryptoBox.hash(token);
    var cached = _cache[key];
    if (cached != null && cached.expiresAt.isAfter(DateTime.now())) {
      return cached.email;
    }

    var client = _client ??= createClient();

    String? email;
    try {
      var info = await Oauth2Api(client).tokeninfo(accessToken: token);
      email = info.email;
    } on DetailedApiRequestError catch (e) {
      // googleapis raises this for every status outside 2xx, 5xx included,
      // so the type alone does not mean "Google considered your credential
      // and said no". A server error or a rate limit is an outage; reporting
      // one as a refusal tells a publisher to reissue a credential that was
      // fine all along.
      // A null status is the same case one step further on: googleapis could
      // not work out what it was told at all, which is what a truncated or
      // non-JSON error body looks like — a captive portal, an intercepting
      // proxy, a gateway that answered in HTML. Reading "no status" as "your
      // credential was refused" is the false refusal this branch exists to
      // avoid, and the one that stops a `dart pub publish` mid-flight and
      // sends its owner off to reissue a credential that was never the
      // problem.
      var status = e.status;
      if (status == null || status >= 500 || status == 429) {
        _log.warning('googleapis answered ${status ?? 'no status'} while '
            'checking a credential: $e');
        throw IdentityUnavailableException(
            'the identity service is not answering just now; please try '
            'again in a moment');
      }
      // A considered answer from Google: this credential is not good.
      _log.info('the Google credential was not accepted: $e');
      email = null;
    } catch (e) {
      _log.warning('could not reach Google to check a credential: $e');
      throw IdentityUnavailableException(
          'the identity service could not be reached to check this '
          'credential; please try again');
    }

    // Only a real answer is kept, and only for a minute: a credential
    // revoked on the far side has to stop working here promptly. A refusal
    // is not kept at all, being indistinguishable here from a hiccup.
    if (email != null) {
      _cache[key] =
          _CachedAnswer(email, DateTime.now().add(const Duration(minutes: 1)));
      if (_cache.length > _cacheLimit) _prune();
    }
    return email;
  }

  /// Builds the client this resolver talks to googleapis through.
  ///
  /// A method rather than an expression inline, so a test can stand in for
  /// it. The property worth checking — that [close] leaves the next
  /// resolution able to work — cannot be shown with a real client without
  /// reaching Google.
  @visibleForTesting
  http.Client createClient() => proxy == null
      ? http.Client()
      : IOClient(HttpClient()
        ..findProxy = (url) => HttpClient.findProxyFromEnvironment(url,
            environment: {'https_proxy': proxy!}));

  /// The same answer, as an identity.
  Future<AuthenticatedUser?> resolveUser(String token) async {
    var email = await resolve(token);
    if (email == null) return null;
    return AuthenticatedUser(
        id: 'google:$email', email: email, displayName: email);
  }

  void _prune() {
    var now = DateTime.now();
    _cache.removeWhere((_, e) => !e.expiresAt.isAfter(now));
    // Still over the limit means that many are genuinely live at once and
    // dropping expired entries freed nothing. Start over rather than grow
    // without bound; entries only live a minute.
    if (_cache.length > _cacheLimit) _cache.clear();
  }

  /// Closes the http client and forgets it, along with everything Google
  /// has told us.
  ///
  /// Forgetting the client matters: `_client ??=` would otherwise hand the
  /// closed one back to the next resolution, which throws `Client is already
  /// closed` forever after — reported to the publisher as "the identity
  /// service could not be reached", against a client that can never be
  /// reached again. Dropping the reference lets the next call build a
  /// working one.
  ///
  /// The cache goes with it for the same reason it exists at all. Reuse
  /// after close is a supported path, and an answer accepted a moment before
  /// the close would otherwise keep opening a publish for up to a minute
  /// without a single call to Google — including one revoked in between,
  /// which is exactly the window the cache's short life is meant to bound.
  void close() {
    _client?.close();
    _client = null;
    _cache.clear();
  }
}

/// A remembered answer. Only ones Google actually gave are kept, so this
/// always names somebody.
class _CachedAnswer {
  final String email;
  final DateTime expiresAt;
  const _CachedAnswer(this.email, this.expiresAt);
}

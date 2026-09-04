import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import 'auth_config.dart';
import 'identity.dart';

final _log = Logger('in_pub.auth.oidc');

/// How the client proves its identity at the token endpoint.
///
/// Providers disagree about this, and the disagreement is invisible from the
/// outside: all three look identical until one of them is answered with
/// `invalid_client`.
enum ClientAuthMethod {
  /// HTTP Basic with the credentials sent as-is. What most providers expect
  /// in practice, because most compare the decoded values verbatim.
  basicRaw('client_secret_basic'),

  /// HTTP Basic with the credentials form-urlencoded first, as RFC 6749
  /// §2.3.1 specifies. Only differs from [basicRaw] when the id or secret
  /// contains a character that encoding changes — which is exactly when a
  /// provider that does not decode will reject us, and vice versa.
  basicEncoded('client_secret_basic'),

  /// Credentials in the request body.
  post('client_secret_post');

  final String advertisedName;
  const ClientAuthMethod(this.advertisedName);
}

/// Raised internally when the provider says `invalid_client`, meaning the
/// request never got as far as being about a user. Not exported: callers see
/// either a revocation or an unavailability.
class _ClientAuthRejected implements Exception {
  final String message;
  _ClientAuthRejected(this.message);
}

/// The subset of an OpenID Connect discovery document we use.
class OidcDiscovery {
  final String issuer;
  final Uri authorizationEndpoint;
  final Uri tokenEndpoint;
  final Uri userInfoEndpoint;
  final Uri? endSessionEndpoint;
  final List<String> tokenAuthMethods;

  OidcDiscovery({
    required this.issuer,
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.userInfoEndpoint,
    this.endSessionEndpoint,
    this.tokenAuthMethods = const [],
  });

  factory OidcDiscovery.fromJson(Map<String, dynamic> json) {
    Uri require(String key) {
      var value = json[key];
      if (value is! String || value.isEmpty) {
        throw IdentityUnavailableException(
            'discovery document has no usable "$key"');
      }
      return Uri.parse(value);
    }

    var endSession = json['end_session_endpoint'];
    return OidcDiscovery(
      issuer: json['issuer'] as String? ?? '',
      authorizationEndpoint: require('authorization_endpoint'),
      tokenEndpoint: require('token_endpoint'),
      userInfoEndpoint: require('userinfo_endpoint'),
      endSessionEndpoint: endSession is String && endSession.isNotEmpty
          ? Uri.parse(endSession)
          : null,
      tokenAuthMethods: (json['token_endpoint_auth_methods_supported'] as List?)
              ?.whereType<String>()
              .toList() ??
          const [],
    );
  }
}

/// OpenID Connect client, written to the specification rather than to any one
/// provider. Everything it needs comes from the discovery document.
class OidcProvider implements IdentityProvider {
  final AuthConfig config;
  final http.Client _client;

  OidcDiscovery? _discovery;
  Future<OidcDiscovery>? _discovering;

  /// The client authentication the provider has accepted before, so the
  /// probing in [_clientAuthCandidates] happens once rather than on every
  /// refresh.
  ClientAuthMethod? _workingAuth;

  OidcProvider(this.config, {http.Client? client})
      : _client = client ?? http.Client();

  /// Fetches and caches the discovery document.
  ///
  /// The in-flight future is shared so a burst of first requests produces one
  /// network call rather than one per request.
  Future<OidcDiscovery> discover() {
    var cached = _discovery;
    if (cached != null) return Future.value(cached);
    return _discovering ??= _fetchDiscovery().then((value) {
      _discovery = value;
      _discovering = null;
      return value;
    }, onError: (Object e) {
      _discovering = null;
      throw e;
    });
  }

  Future<OidcDiscovery> _fetchDiscovery() async {
    // The standard location first. Providers that run behind a PHP front
    // controller often only serve it under `index.php`, so that is tried as
    // a fallback rather than requiring the issuer to be written with it.
    var base = config.issuer.endsWith('/')
        ? config.issuer.substring(0, config.issuer.length - 1)
        : config.issuer;
    var candidates = [
      Uri.parse('$base/.well-known/openid-configuration'),
      Uri.parse('$base/index.php/.well-known/openid-configuration'),
    ];

    Object? lastError;
    for (var uri in candidates) {
      try {
        _log.fine('discovery: GET $uri');
        var res =
            await _client.get(uri, headers: {'Accept': 'application/json'});
        if (res.statusCode != 200) {
          _log.fine('discovery: $uri answered HTTP ${res.statusCode}');
          lastError = 'HTTP ${res.statusCode} from $uri';
          continue;
        }
        var discovery = OidcDiscovery.fromJson(
            json.decode(res.body) as Map<String, dynamic>);
        // A mismatched issuer means the document does not describe the server
        // we think we are talking to, which defeats the point of discovery.
        if (discovery.issuer.isNotEmpty &&
            _normalizeIssuer(discovery.issuer) != _normalizeIssuer(base)) {
          throw IdentityUnavailableException(
              'discovery issuer "${discovery.issuer}" does not match '
              'configured issuer "$base"');
        }
        _log.fine('discovery: issuer "${discovery.issuer}"\n'
            '  authorization_endpoint: ${discovery.authorizationEndpoint}\n'
            '  token_endpoint:         ${discovery.tokenEndpoint}\n'
            '  userinfo_endpoint:      ${discovery.userInfoEndpoint}\n'
            '  end_session_endpoint:   ${discovery.endSessionEndpoint ?? '(none)'}\n'
            '  token auth methods:     ${discovery.tokenAuthMethods.isEmpty ? '(not advertised)' : discovery.tokenAuthMethods.join(', ')}');
        return discovery;
      } on IdentityUnavailableException {
        rethrow;
      } catch (e) {
        _log.fine('discovery: $uri failed: $e');
        lastError = e;
      }
    }
    throw IdentityUnavailableException(
        'OIDC discovery failed for $base: $lastError');
  }

  static String _normalizeIssuer(String value) {
    var v = value.trim();
    // A provider behind a PHP front controller advertises its issuer with
    // `index.php` in it when pretty urls are off; that is the same server as
    // the bare host, and the configured issuer is usually written without it.
    v = v.replaceAll('/index.php', '');
    return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
  }

  @override
  Future<Uri> authorizationUrl({
    required String state,
    required String nonce,
    required String codeChallenge,
    bool forceConsent = false,
  }) async {
    var discovery = await discover();
    var url = discovery.authorizationEndpoint.replace(queryParameters: {
      ...discovery.authorizationEndpoint.queryParameters,
      'response_type': 'code',
      'client_id': config.clientId,
      'redirect_uri': config.redirectUri.toString(),
      'scope': config.scopes.join(' '),
      'state': state,
      'nonce': nonce,
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      if (forceConsent) 'prompt': 'consent',
    });
    // Worth logging whole: it contains no secret, and comparing it against
    // what the provider has registered is how a redirect uri or scope
    // mismatch gets found.
    _log.fine('authorize: $url');
    return url;
  }

  @override
  Future<OidcTokens> exchangeCode({
    required String code,
    required String codeVerifier,
    required String nonce,
  }) async {
    OidcTokens tokens;
    try {
      tokens = await _token({
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': config.redirectUri.toString(),
        'code_verifier': codeVerifier,
      });
    } on IdentityRevokedException {
      // Here `invalid_grant` is about the authorization code, not the
      // account: it was already used, or the sign-in took too long. Saying
      // "you are not authorised" would be both wrong and unhelpful.
      throw IdentityUnavailableException(
          'the sign-in could not be completed: the authorization code was '
          'rejected. It may have expired or already been used — please start '
          'again.');
    }

    var idToken = tokens.idToken;
    if (idToken != null) _verifyIdToken(idToken, nonce);

    // A missing refresh token is *reported*, not thrown. Whether it matters
    // is not knowable here: the account may already hold a usable one from
    // an earlier consent, and providers that issue one only on the first
    // consent return none on every later sign-in. Throwing made the
    // callback's whole recovery path — try the stored token, then ask the
    // provider to prompt for consent again — unreachable, and turned an
    // ordinary second sign-in into a 503. The callback decides.
    if (tokens.refreshToken == null) {
      _log.info('the token response carried no refresh token; the sign-in '
          'will fall back to the stored one or ask for consent again');
    }
    return tokens;
  }

  @override
  Future<OidcTokens> refresh(String refreshToken) => _token({
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      });

  /// Posts to the token endpoint, working out how this provider wants the
  /// client to authenticate.
  ///
  /// There is no reliable way to know in advance: the discovery document at
  /// best names a family (`client_secret_basic`) without saying whether the
  /// credentials inside HTTP Basic are expected form-urlencoded, and a
  /// provider that disagrees answers `invalid_client` with no further hint.
  /// So the candidates are tried in order of likelihood and the one that
  /// works is remembered.
  Future<OidcTokens> _token(Map<String, String> body) async {
    var discovery = await discover();
    var candidates = _clientAuthCandidates(discovery);

    for (var i = 0; i < candidates.length; i++) {
      var method = candidates[i];
      try {
        var tokens = await _tokenWith(discovery, body, method);
        if (_workingAuth != method) {
          _log.info('token endpoint accepted ${method.name} client '
              'authentication');
          _workingAuth = method;
        }
        return tokens;
      } on _ClientAuthRejected catch (e) {
        var isLast = i == candidates.length - 1;
        _log.fine('token endpoint rejected ${method.name}: ${e.message}');
        if (!isLast) {
          _log.info('client authentication as ${method.name} was refused; '
              'retrying as ${candidates[i + 1].name}');
          continue;
        }
        // Every way of presenting the credentials was refused, so the
        // credentials themselves are wrong rather than merely mis-encoded.
        _log.severe('the provider refused this client with every supported '
            'authentication method (${candidates.map((c) => c.name).join(', ')}). '
            '${describeCredentials()}');
        throw IdentityUnavailableException(
            'the token endpoint refused this client (${e.message}). Check '
            '--auth-client-id and the client secret; run with --verbose for '
            'the full exchange.');
      }
    }
    throw StateError('unreachable: no client authentication method tried');
  }

  /// Which ways of authenticating to try, best guess first.
  List<ClientAuthMethod> _clientAuthCandidates(OidcDiscovery discovery) {
    var advertised = discovery.tokenAuthMethods;
    var order = <ClientAuthMethod>[
      // A method known to work here beats any amount of guessing.
      if (_workingAuth != null) _workingAuth!,
      // Basic is the spec's default; only skip ahead when the provider says
      // outright that it does not do Basic.
      if (advertised.isEmpty || advertised.contains('client_secret_basic')) ...[
        ClientAuthMethod.basicRaw,
        ClientAuthMethod.basicEncoded,
      ],
      if (advertised.contains('client_secret_post')) ClientAuthMethod.post,
      // Fall back to trying everything rather than giving up on a provider
      // that advertises something exotic it also happens to accept.
      ...ClientAuthMethod.values,
    ];

    var seen = <ClientAuthMethod>{};
    var candidates = order.where(seen.add).toList();

    // Encoding only makes a difference when it changes something; otherwise
    // it is the same bytes on the wire and a wasted round trip.
    if (_formEncode(config.clientId) == config.clientId &&
        _formEncode(config.clientSecret) == config.clientSecret) {
      candidates.remove(ClientAuthMethod.basicEncoded);
    }
    return candidates;
  }

  Future<OidcTokens> _tokenWith(OidcDiscovery discovery,
      Map<String, String> body, ClientAuthMethod method) async {
    var form = {...body, 'client_id': config.clientId};
    var headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
    };

    switch (method) {
      case ClientAuthMethod.post:
        form['client_secret'] = config.clientSecret;
      case ClientAuthMethod.basicRaw:
        headers['Authorization'] = _basic(config.clientId, config.clientSecret);
      case ClientAuthMethod.basicEncoded:
        headers['Authorization'] = _basic(
            _formEncode(config.clientId), _formEncode(config.clientSecret));
    }

    _log.fine('token: POST ${discovery.tokenEndpoint}\n'
        '  grant_type:  ${body['grant_type']}\n'
        '  client_id:   ${config.clientId}\n'
        '  client auth: ${method.name}\n'
        '  parameters:  ${form.keys.join(', ')}'
        '${body.containsKey('redirect_uri') ? '\n  redirect_uri: ${body['redirect_uri']}' : ''}');

    http.Response res;
    try {
      res = await _client.post(discovery.tokenEndpoint,
          headers: headers, body: form);
    } catch (e) {
      throw IdentityUnavailableException('token endpoint unreachable: $e');
    }

    _log.fine('token: HTTP ${res.statusCode}');

    if (res.statusCode == 200) {
      // Checked rather than cast. A 200 whose body is not a token response —
      // an HTML page from a captive portal or a proxy, a provider with a
      // half-configured client — otherwise threw a raw `TypeError` past both
      // identity exceptions, which is all any caller here handles, and
      // surfaced as an unstyled 500 in the middle of a sign-in.
      var decoded = _asJsonObject(res.body);
      var accessToken = decoded?['access_token'];
      if (accessToken is! String || accessToken.isEmpty) {
        _log.warning('token: HTTP 200 with no usable access_token; body: '
            '${_truncate(res.body)}');
        throw IdentityUnavailableException(
            'the identity provider returned an unusable token response');
      }
      var expiresIn = decoded!['expires_in'];
      _log.fine('token: got ${decoded.keys.join(', ')} '
          '(expires_in: ${expiresIn ?? 'unset'})');
      return OidcTokens(
        accessToken: accessToken,
        refreshToken: _asString(decoded['refresh_token']),
        idToken: _asString(decoded['id_token']),
        accessTokenExpiresAt: expiresIn is num
            ? DateTime.now().add(Duration(seconds: expiresIn.toInt()))
            : null,
      );
    }

    String? error;
    String? description;
    if (res.statusCode >= 400 && res.statusCode < 500) {
      var body = _asJsonObject(res.body);
      error = _asString(body?['error']);
      description = _asString(body?['error_description']);
    }
    // The body carries no secret of ours, only the provider's complaint.
    _log.fine('token: response body: ${_truncate(res.body)}');

    // `invalid_grant` is the only error that says anything about the *user*:
    // their token was revoked, expired or already spent. Every other OAuth
    // error is about this client — a rotated secret, a wrong id, a
    // malformed request — and must not be reported as a revocation, or a
    // configuration mistake would block every account on the server.
    if (error == 'invalid_grant') {
      throw IdentityRevokedException(
          'the provider rejected the grant: ${description ?? error}');
    }
    if (error == 'invalid_client') {
      // Recoverable: this may be the wrong flavour of client authentication
      // rather than the wrong credentials.
      throw _ClientAuthRejected(
          '$error${description == null ? '' : ': $description'}');
    }
    if (error != null) {
      throw IdentityUnavailableException(
          'the token endpoint rejected the request ($error'
          '${description == null ? '' : ': $description'}).');
    }
    throw IdentityUnavailableException(
        'token endpoint returned HTTP ${res.statusCode}: '
        '${_truncate(res.body)}');
  }

  static String _basic(String id, String secret) =>
      'Basic ${base64.encode(utf8.encode('$id:$secret'))}';

  /// `application/x-www-form-urlencoded` escaping, as RFC 6749 §2.3.1 asks
  /// for before base64-encoding Basic credentials.
  static String _formEncode(String value) => Uri.encodeQueryComponent(value);

  /// Decodes a body that should be a JSON object, or null if it is anything
  /// else. Providers do answer with HTML, and a cast throws a kind of error
  /// no caller here is prepared for.
  static Map<String, dynamic>? _asJsonObject(String body) {
    try {
      var decoded = json.decode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// A value when it really is a string. Providers have been known to send
  /// numbers and arrays where the spec says string.
  static String? _asString(Object? value) => value is String ? value : null;

  static String _truncate(String value, [int max = 512]) =>
      value.length <= max ? value : '${value.substring(0, max)}…';

  /// A description of the configured credentials that is safe to log: enough
  /// to spot a truncated, whitespace-padded or wrongly-copied value without
  /// printing the value itself.
  String describeCredentials() {
    var secret = config.clientSecret;
    var problems = <String>[
      if (secret != secret.trim()) 'has leading or trailing whitespace',
      if (_formEncode(secret) != secret)
        'contains characters that url-encoding changes, which is why more '
            'than one form of Basic authentication is attempted',
      if (config.clientId != config.clientId.trim())
        'the client id has leading or trailing whitespace',
    ];
    return 'client id "${config.clientId}", secret is ${secret.length} '
        'characters'
        '${problems.isEmpty ? '' : '; ${problems.join('; ')}'}';
  }

  @override
  Future<AuthenticatedUser> userInfo(String accessToken) async {
    var discovery = await discover();
    _log.fine('userinfo: GET ${discovery.userInfoEndpoint}');
    http.Response res;
    try {
      res = await _client.get(discovery.userInfoEndpoint, headers: {
        'Authorization': 'Bearer $accessToken',
        'Accept': 'application/json',
      });
    } catch (e) {
      throw IdentityUnavailableException('userinfo unreachable: $e');
    }

    _log.fine('userinfo: HTTP ${res.statusCode}');

    if (res.statusCode == 401 || res.statusCode == 403) {
      // This is the check that catches a disabled or deleted account: such a
      // user cannot authenticate at all, so userinfo refuses even when the
      // refresh grant above succeeded.
      throw IdentityRevokedException(
          'userinfo rejected the account (HTTP ${res.statusCode})');
    }
    if (res.statusCode != 200) {
      _log.fine('userinfo: response body: ${_truncate(res.body)}');
      throw IdentityUnavailableException(
          'userinfo returned HTTP ${res.statusCode}');
    }

    Map<String, dynamic> claims;
    try {
      claims = json.decode(res.body) as Map<String, dynamic>;
    } catch (e) {
      throw IdentityUnavailableException('userinfo returned invalid JSON: $e');
    }

    // The claim *names* matter far more than the values when diagnosing a
    // sign-in: a missing `groups` is the usual reason a group filter turns
    // everyone away.
    _log.fine('userinfo: claims present: ${claims.keys.join(', ')}');
    var user = _userFromClaims(claims);
    _log.fine('userinfo: sub=${user.id}, email='
        '${user.email.isEmpty ? '(none)' : user.email}, groups='
        '${user.groups.isEmpty ? '(none)' : user.groups.join(', ')}');
    if (user.groups.isEmpty && config.allowedGroups.isNotEmpty) {
      _log.warning('userinfo returned no groups for ${user.id}, but access is '
          'restricted to ${config.allowedGroups.join(', ')}. Allow the '
          '"groups" scope and claim for this client, or nobody will get in.');
    }
    return user;
  }

  @override
  Future<Uri?> endSessionUrl({String? idToken, Uri? postLogoutRedirect}) async {
    OidcDiscovery discovery;
    try {
      discovery = await discover();
    } on IdentityUnavailableException {
      return null;
    }
    var endpoint = discovery.endSessionEndpoint;
    if (endpoint == null) return null;
    return endpoint.replace(queryParameters: {
      ...endpoint.queryParameters,
      'client_id': config.clientId,
      if (idToken != null) 'id_token_hint': idToken,
      if (postLogoutRedirect != null)
        'post_logout_redirect_uri': postLogoutRedirect.toString(),
    });
  }

  /// Builds a user from userinfo claims.
  ///
  /// Group membership is read here rather than from the id token on purpose.
  /// In the authorization code flow a provider may return `email` and
  /// `groups` from userinfo only, leaving them out of the id token unless
  /// they were asked for through the `claims` parameter. A client that
  /// trusted the id token would then see an empty group list and wave
  /// everyone past a group filter.
  static AuthenticatedUser _userFromClaims(Map<String, dynamic> claims) {
    var sub = claims['sub'];
    if (sub is! String || sub.isEmpty) {
      throw IdentityUnavailableException('userinfo returned no "sub" claim');
    }

    var groups = <String>[];
    for (var key in const ['groups', 'roles']) {
      var value = claims[key];
      if (value == null) continue;
      var parsed = _parseGroups(value);
      groups.addAll(parsed);
      // An empty list is a real answer; anything else that yields nothing is
      // a shape this does not understand. Say so, because the symptom
      // downstream is an unexplained "not a member of a group with access".
      if (parsed.isEmpty && !(value is List && value.isEmpty)) {
        _log.warning('the "$key" claim could not be read as group names: '
            '${json.encode(value)}');
      }
    }

    return AuthenticatedUser(
      id: sub,
      // Read, not cast. `sub` above is checked because nothing works
      // without it; these three are optional, and a provider sending a
      // number or an object where the spec says string should cost a field,
      // not throw a `TypeError` past every handler on the sign-in path.
      email: _asString(claims['email']) ?? '',
      displayName: _asString(claims['name']) ??
          _asString(claims['preferred_username']) ??
          sub,
      groups: groups.toSet().toList(),
    );
  }

  /// Reads group names out of a claim.
  ///
  /// The spec does not pin down a shape, and providers use all of them: an
  /// array of names, a delimited string, or an array of objects with the
  /// name under one of several keys.
  static List<String> _parseGroups(Object value) {
    if (value is String) {
      return value.split(RegExp(r'[,\s]+')).where((s) => s.isNotEmpty).toList();
    }
    if (value is! List) return const [];

    var names = <String>[];
    for (var entry in value) {
      if (entry is String) {
        if (entry.isNotEmpty) names.add(entry);
      } else if (entry is Map) {
        // Every identifier the entry offers, not just the first: a group can
        // carry both an id and a display name, and they drift apart as soon
        // as somebody renames it. Which of the two an administrator wrote in
        // --auth-allowed-groups is not knowable here, so both must match.
        for (var key in const [
          'name',
          'displayName',
          'display_name',
          'gid',
          'id'
        ]) {
          var name = entry[key];
          if (name is String && name.isNotEmpty) names.add(name);
        }
      }
    }
    return names;
  }

  /// Checks the claims of an id token received straight from the token
  /// endpoint.
  ///
  /// The signature is deliberately not verified: the token arrived over a
  /// TLS-authenticated channel directly from the provider, which OIDC Core
  /// 3.1.3.7 accepts in place of signature validation. That keeps a JWKS
  /// fetch, key rotation handling and a JWT dependency out of the picture.
  /// If this ever starts accepting id tokens from the front channel, that
  /// reasoning stops holding and signatures must be checked.
  void _verifyIdToken(String idToken, String expectedNonce) {
    var claims = decodeJwtPayload(idToken);
    if (claims == null) {
      throw IdentityUnavailableException('id token is not a readable JWT');
    }

    var nonce = claims['nonce'];
    if (nonce != expectedNonce) {
      throw IdentityUnavailableException(
          'id token nonce does not match the login request');
    }

    var issuer = claims['iss'];
    if (issuer is String &&
        _normalizeIssuer(issuer) != _normalizeIssuer(config.issuer)) {
      throw IdentityUnavailableException(
          'id token was issued by "$issuer", not by the configured issuer');
    }

    var audience = claims['aud'];
    var audiences = audience is List
        ? audience.whereType<String>().toList()
        : [if (audience is String) audience];
    if (audiences.isNotEmpty && !audiences.contains(config.clientId)) {
      throw IdentityUnavailableException(
          'id token was not issued for this client');
    }

    var exp = claims['exp'];
    if (exp is num) {
      var expiry = DateTime.fromMillisecondsSinceEpoch(exp.toInt() * 1000);
      // A minute of slack for clock skew between the two servers.
      if (expiry.isBefore(DateTime.now().subtract(Duration(minutes: 1)))) {
        throw IdentityUnavailableException('id token has expired');
      }
    }
  }

  /// Decodes the claim set of a JWT without verifying it. Returns null when
  /// the value is not a well-formed JWT.
  static Map<String, dynamic>? decodeJwtPayload(String jwt) {
    var parts = jwt.split('.');
    if (parts.length < 2) return null;
    try {
      var payload = parts[1];
      // base64url in JWTs is unpadded.
      var padded = payload.padRight((payload.length + 3) & ~3, '=');
      var decoded = utf8.decode(base64Url.decode(padded));
      var claims = json.decode(decoded);
      return claims is Map<String, dynamic> ? claims : null;
    } catch (_) {
      return null;
    }
  }

  void close() => _client.close();
}

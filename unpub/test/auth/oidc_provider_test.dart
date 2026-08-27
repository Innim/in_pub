import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:in_pub/src/auth/auth_config.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:in_pub/src/auth/oidc_provider.dart';
import 'package:test/test.dart';

/// How the provider reads an OpenID Connect server's answers.
///
/// The distinction that matters most here is between "this user is no longer
/// authorised" and "we could not find out". Only the first may end a session:
/// `UserValidator` blocks the account and revokes every session on a
/// [IdentityRevokedException], so mapping an ordinary configuration mistake
/// onto it would lock out everyone at once.
void main() {
  const issuer = 'https://id.example.org';

  final discoveryDocument = json.encode({
    'issuer': issuer,
    'authorization_endpoint': '$issuer/oidc/authorize',
    'token_endpoint': '$issuer/oidc/token',
    'userinfo_endpoint': '$issuer/oidc/userinfo',
    'end_session_endpoint': '$issuer/oidc/logout',
    'token_endpoint_auth_methods_supported': ['client_secret_basic'],
  });

  AuthConfig config = AuthConfig(
    enabled: true,
    issuer: issuer,
    clientId: 'in-pub',
    clientSecret: 'client-secret',
    publicUrl: Uri.parse('https://pub.example.org'),
    secret: List<int>.generate(48, (i) => i),
  );

  /// A provider whose token and userinfo endpoints answer with whatever the
  /// callers supply. Discovery always succeeds.
  OidcProvider provider({
    http.Response Function(http.Request)? token,
    http.Response Function(http.Request)? userInfo,
    String? discovery,
  }) =>
      OidcProvider(config, client: MockClient((request) async {
        var path = request.url.path;
        if (path.endsWith('openid-configuration')) {
          return http.Response(discovery ?? discoveryDocument, 200,
              headers: {'content-type': 'application/json'});
        }
        if (path.endsWith('/token') && token != null) return token(request);
        if (path.endsWith('/userinfo') && userInfo != null) {
          return userInfo(request);
        }
        return http.Response('unexpected request to $path', 404);
      }));

  http.Response oauthError(String error, {int status = 400}) => http.Response(
      json.encode({'error': error, 'error_description': 'because $error'}),
      status,
      headers: {'content-type': 'application/json'});

  http.Response tokens({String? refreshToken = 'refresh-2'}) => http.Response(
      json.encode({
        'access_token': 'access-1',
        if (refreshToken != null) 'refresh_token': refreshToken,
        'expires_in': 3600,
      }),
      200,
      headers: {'content-type': 'application/json'});

  group('refreshing a grant', () {
    test('returns the rotated refresh token', () async {
      var result = await provider(token: (_) => tokens()).refresh('refresh-1');
      expect(result.accessToken, 'access-1');
      expect(result.refreshToken, 'refresh-2');
    });

    test('treats invalid_grant as a revocation', () async {
      // The one error that is about the user rather than about us.
      expect(
          provider(token: (_) => oauthError('invalid_grant'))
              .refresh('refresh-1'),
          throwsA(isA<IdentityRevokedException>()));
    });

    test('does not treat a client error as a revocation', () async {
      // A rotated client secret, a mistyped client id or a provider-side
      // misconfiguration answers 4xx too. Reporting that as a revocation
      // would block every account on the server at once.
      for (var error in const [
        'invalid_client',
        'invalid_request',
        'unauthorized_client',
        'unsupported_grant_type',
        'invalid_scope',
      ]) {
        expect(provider(token: (_) => oauthError(error)).refresh('refresh-1'),
            throwsA(isA<IdentityUnavailableException>()),
            reason: '$error is about this client, not the account');
      }
    });

    test('names the misconfiguration so it can be fixed', () async {
      try {
        await provider(token: (_) => oauthError('invalid_client'))
            .refresh('refresh-1');
        fail('expected a failure');
      } on IdentityUnavailableException catch (e) {
        expect(e.message, contains('invalid_client'));
        expect(e.message, contains('--auth-client-id'));
      }
    });

    test('a server error is an outage', () async {
      expect(
          provider(token: (_) => http.Response('boom', 500))
              .refresh('refresh-1'),
          throwsA(isA<IdentityUnavailableException>()));
    });

    test('an unreachable endpoint is an outage', () async {
      var unreachable =
          OidcProvider(config, client: MockClient((request) async {
        if (request.url.path.endsWith('openid-configuration')) {
          return http.Response(discoveryDocument, 200);
        }
        throw const SocketExceptionStub();
      }));
      expect(unreachable.refresh('refresh-1'),
          throwsA(isA<IdentityUnavailableException>()));
    });
  });

  group('authenticating this client', () {
    /// Decodes the credentials out of an HTTP Basic header.
    List<String> basicCredentials(http.Request request) {
      var header = request.headers['authorization']!;
      var decoded =
          utf8.decode(base64.decode(header.substring('Basic '.length)));
      var cut = decoded.indexOf(':');
      return [decoded.substring(0, cut), decoded.substring(cut + 1)];
    }

    /// A provider that only accepts one way of presenting the credentials and
    /// answers `invalid_client` to every other, the way a real one does.
    OidcProvider acceptingOnly(
      bool Function(http.Request request) accepts, {
      List<String> advertise = const ['client_secret_basic'],
      List<http.Request>? attempts,
    }) {
      attempts ??= [];
      var document = json.encode({
        'issuer': issuer,
        'authorization_endpoint': '$issuer/oidc/authorize',
        'token_endpoint': '$issuer/oidc/token',
        'userinfo_endpoint': '$issuer/oidc/userinfo',
        'token_endpoint_auth_methods_supported': advertise,
      });
      return OidcProvider(config, client: MockClient((request) async {
        if (request.url.path.endsWith('openid-configuration')) {
          return http.Response(document, 200);
        }
        attempts!.add(request);
        return accepts(request)
            ? tokens()
            : oauthError('invalid_client', status: 401);
      }));
    }

    test('uses HTTP Basic by default', () async {
      var attempts = <http.Request>[];
      await acceptingOnly((r) => r.headers.containsKey('authorization'),
              attempts: attempts)
          .refresh('refresh-1');
      expect(attempts, hasLength(1));
      expect(basicCredentials(attempts.single), ['in-pub', 'client-secret']);
    });

    test('falls back to credentials in the body', () async {
      // A provider that advertises Basic but only implements the body form is
      // not hypothetical, and the only symptom is `invalid_client`.
      var attempts = <http.Request>[];
      await acceptingOnly((r) => r.body.contains('client_secret='),
              attempts: attempts)
          .refresh('refresh-1');
      expect(attempts.length, greaterThan(1),
          reason: 'the first attempt should have been Basic');
      expect(attempts.last.body, contains('client_secret=client-secret'));
    });

    test('goes straight to the body form when Basic is not advertised',
        () async {
      var attempts = <http.Request>[];
      await acceptingOnly((r) => r.body.contains('client_secret='),
              advertise: ['client_secret_post'], attempts: attempts)
          .refresh('refresh-1');
      expect(attempts, hasLength(1));
    });

    test('remembers what worked instead of probing every time', () async {
      var attempts = <http.Request>[];
      var provider = acceptingOnly((r) => r.body.contains('client_secret='),
          attempts: attempts);

      await provider.refresh('refresh-1');
      var afterFirst = attempts.length;
      await provider.refresh('refresh-2');

      expect(attempts.length - afterFirst, 1,
          reason: 'the working method should be reused, not rediscovered on '
              'every refresh');
    });

    test('reports credentials as wrong only when nothing works', () async {
      // Once every encoding has been refused, the problem really is the id or
      // the secret, and the message should say so rather than blaming the
      // account.
      try {
        await acceptingOnly((_) => false).refresh('refresh-1');
        fail('expected a failure');
      } on IdentityUnavailableException catch (e) {
        expect(e.message, contains('invalid_client'));
        expect(e.message, contains('--auth-client-id'));
      }
    });

    test('never reports a refused client as a revoked account', () async {
      // This is the difference between "one deployment is misconfigured" and
      // "every session on the server is destroyed".
      expect(acceptingOnly((_) => false).refresh('refresh-1'),
          throwsA(isA<IdentityUnavailableException>()));
    });

    group('when the secret contains characters url-encoding changes', () {
      var awkward = AuthConfig(
        enabled: true,
        issuer: issuer,
        clientId: 'in-pub',
        clientSecret: 'se+cret/with=awkward&chars',
        publicUrl: Uri.parse('https://pub.example.org'),
        secret: List<int>.generate(48, (i) => i),
      );

      OidcProvider probing(bool Function(http.Request) accepts,
              List<http.Request> attempts) =>
          OidcProvider(awkward, client: MockClient((request) async {
            if (request.url.path.endsWith('openid-configuration')) {
              return http.Response(discoveryDocument, 200);
            }
            attempts.add(request);
            return accepts(request)
                ? tokens()
                : oauthError('invalid_client', status: 401);
          }));

      test('sends it verbatim first', () async {
        // Most providers compare the decoded Basic credentials as-is.
        var attempts = <http.Request>[];
        await probing(
                (r) => basicCredentials(r)[1] == awkward.clientSecret, attempts)
            .refresh('refresh-1');
        expect(attempts, hasLength(1));
      });

      test('then tries the form-encoded spelling the spec asks for', () async {
        var attempts = <http.Request>[];
        await probing(
                (r) =>
                    basicCredentials(r)[1] ==
                    Uri.encodeQueryComponent(awkward.clientSecret),
                attempts)
            .refresh('refresh-1');
        expect(attempts.length, greaterThan(1));
      });
    });

    test('a plain secret is not probed twice for nothing', () async {
      // Encoding an already-safe secret produces identical bytes, so trying
      // both would be a wasted round trip against the provider.
      var attempts = <http.Request>[];
      try {
        await acceptingOnly((r) => r.body.contains('client_secret='),
                advertise: const [], attempts: attempts)
            .refresh('refresh-1');
      } catch (_) {}
      var basicAttempts =
          attempts.where((r) => r.headers.containsKey('authorization')).length;
      expect(basicAttempts, 1);
    });
  });

  group('describing the configured credentials', () {
    test('says how long the secret is without printing it', () {
      var description = provider().describeCredentials();
      expect(description, contains('in-pub'));
      expect(description, contains('13 characters'));
      expect(description, isNot(contains('client-secret')));
    });

    test('points out whitespace that was pasted in by accident', () {
      var padded = OidcProvider(AuthConfig(
        enabled: true,
        issuer: issuer,
        clientId: 'in-pub',
        clientSecret: 'secret\n',
        publicUrl: Uri.parse('https://pub.example.org'),
        secret: List<int>.generate(48, (i) => i),
      ));
      expect(padded.describeCredentials(), contains('whitespace'));
    });
  });

  group('exchanging an authorization code', () {
    test('does not report a stale code as an unauthorised account', () async {
      // `invalid_grant` here is about the code, not the person: it was
      // already used, or the sign-in sat open too long.
      try {
        await provider(token: (_) => oauthError('invalid_grant')).exchangeCode(
            code: 'abc', codeVerifier: 'verifier', nonce: 'nonce');
        fail('expected a failure');
      } catch (e) {
        expect(e, isA<IdentityUnavailableException>());
        expect((e as IdentityUnavailableException).message,
            contains('start again'));
      }
    });

    test('refuses to continue without a refresh token', () async {
      // Without one the account could never be re-checked, so the session
      // would outlive a revocation.
      try {
        await provider(token: (_) => tokens(refreshToken: null)).exchangeCode(
            code: 'abc', codeVerifier: 'verifier', nonce: 'nonce');
        fail('expected a failure');
      } on IdentityUnavailableException catch (e) {
        expect(e.message, contains('offline_access'));
      }
    });
  });

  group('reading the profile', () {
    http.Response profile(Map<String, dynamic> claims) =>
        http.Response(json.encode(claims), 200,
            headers: {'content-type': 'application/json'});

    test('takes identity and groups from the claims', () async {
      var user = await provider(
          userInfo: (_) => profile({
                'sub': 'user-1',
                'email': 'someone@example.org',
                'name': 'Someone',
                'groups': ['developers', 'everyone'],
              })).userInfo('access-1');

      expect(user.id, 'user-1');
      expect(user.email, 'someone@example.org');
      expect(user.displayName, 'Someone');
      expect(user.groups, ['developers', 'everyone']);
    });

    test('accepts groups given as objects', () async {
      // Providers are not consistent about this, and an unread group list is
      // indistinguishable from having no groups until someone is turned away.
      var user = await provider(
          userInfo: (_) => profile({
                'sub': 'user-1',
                'groups': [
                  {'gid': 'developers', 'displayName': 'Developers'},
                  {'name': 'everyone'},
                ],
              })).userInfo('access-1');
      // Both the id and the display name count. They drift apart the moment
      // a group is renamed, and which one an administrator configured cannot
      // be known from here — so matching either has to work.
      expect(
          user.groups, containsAll(['developers', 'Developers', 'everyone']));
    });

    test('an empty group list is not an error', () async {
      var user = await provider(
              userInfo: (_) => profile({'sub': 'user-1', 'groups': []}))
          .userInfo('access-1');
      expect(user.groups, isEmpty);
    });

    test('accepts groups given as a string', () async {
      var user = await provider(
              userInfo: (_) =>
                  profile({'sub': 'user-1', 'groups': 'developers everyone'}))
          .userInfo('access-1');
      expect(user.groups, ['developers', 'everyone']);
    });

    test('falls back to the username when there is no display name', () async {
      var user = await provider(
              userInfo: (_) =>
                  profile({'sub': 'user-1', 'preferred_username': 'someone'}))
          .userInfo('access-1');
      expect(user.displayName, 'someone');
    });

    test('a refusal is a revocation', () async {
      // This is what catches an account that has been disabled or deleted:
      // it can no longer authenticate, whatever the refresh grant did.
      for (var status in const [401, 403]) {
        expect(
            provider(userInfo: (_) => http.Response('no', status))
                .userInfo('access-1'),
            throwsA(isA<IdentityRevokedException>()));
      }
    });

    test('a server error is an outage', () async {
      expect(
          provider(userInfo: (_) => http.Response('boom', 503))
              .userInfo('access-1'),
          throwsA(isA<IdentityUnavailableException>()));
    });

    test('a response with no subject is unusable', () async {
      expect(
          provider(userInfo: (_) => profile({'email': 'someone@example.org'}))
              .userInfo('access-1'),
          throwsA(isA<IdentityUnavailableException>()));
    });
  });

  group('starting a sign-in', () {
    test('asks for a code, with PKCE and the scopes we need', () async {
      var url = await provider().authorizationUrl(
          state: 'the-state',
          nonce: 'the-nonce',
          codeChallenge: 'the-challenge');
      var params = url.queryParameters;

      expect(url.path, '/oidc/authorize');
      expect(params['response_type'], 'code');
      expect(params['client_id'], 'in-pub');
      expect(params['redirect_uri'], 'https://pub.example.org/auth/callback');
      expect(params['state'], 'the-state');
      expect(params['nonce'], 'the-nonce');
      expect(params['code_challenge'], 'the-challenge');
      expect(params['code_challenge_method'], 'S256');
      expect(params['scope']!.split(' '),
          containsAll(['openid', 'email', 'groups', 'offline_access']));
    });
  });

  group('discovery', () {
    test('refuses a document describing a different issuer', () async {
      // Otherwise a redirect or a copy-pasted url could point the whole flow
      // at a server we did not mean to trust.
      var mismatched = json.encode({
        'issuer': 'https://somewhere-else.example.org',
        'authorization_endpoint': '$issuer/oidc/authorize',
        'token_endpoint': '$issuer/oidc/token',
        'userinfo_endpoint': '$issuer/oidc/userinfo',
      });
      expect(provider(discovery: mismatched).discover(),
          throwsA(isA<IdentityUnavailableException>()));
    });

    test('accepts an issuer that differs only by a front controller path',
        () async {
      var withIndexPhp = json.encode({
        'issuer': '$issuer/index.php',
        'authorization_endpoint': '$issuer/index.php/oidc/authorize',
        'token_endpoint': '$issuer/index.php/oidc/token',
        'userinfo_endpoint': '$issuer/index.php/oidc/userinfo',
      });
      var discovery = await provider(discovery: withIndexPhp).discover();
      expect(discovery.tokenEndpoint.path, '/index.php/oidc/token');
    });

    test('is fetched once and reused', () async {
      var fetches = 0;
      var counted = OidcProvider(config, client: MockClient((request) async {
        if (request.url.path.endsWith('openid-configuration')) {
          fetches++;
          return http.Response(discoveryDocument, 200);
        }
        return http.Response('{}', 200);
      }));

      await Future.wait([for (var i = 0; i < 5; i++) counted.discover()]);
      await counted.discover();
      expect(fetches, 1);
    });
  });
}

/// Stands in for a transport failure without depending on `dart:io` details.
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'connection refused';
}

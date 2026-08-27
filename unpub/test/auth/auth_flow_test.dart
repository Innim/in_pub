import 'dart:convert';
import 'dart:io';

import 'package:in_pub/src/auth/auth_config.dart';
import 'package:in_pub/src/auth/auth_service.dart';
import 'package:in_pub/src/auth/auth_store.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'fake_provider.dart';
import 'memory_auth_store.dart';

/// End to end through the request pipeline, with the identity provider
/// stubbed out: sign in, browse, sign out, and the ways in should be refused.
void main() {
  const userAgent = 'Mozilla/5.0 (test)';

  late MemoryAuthStore store;
  late FakeIdentityProvider provider;
  late AuthService auth;
  late shelf.Handler handler;

  void build({List<String> allowedGroups = const []}) {
    store = MemoryAuthStore();
    provider = FakeIdentityProvider();
    auth = AuthService(
      config: AuthConfig(
        enabled: true,
        issuer: 'https://idp.example.org',
        clientId: 'in-pub',
        clientSecret: 'client-secret',
        publicUrl: Uri.parse('https://pub.example.org'),
        secret: utf8.encode('a-test-signing-secret-of-sufficient-length!!'),
        allowedGroups: allowedGroups,
        adminGroups: const ['pubadmins'],
      ),
      store: store,
      provider: provider,
    );

    // The same shape as App.serve: the gate in front, the auth routes tried
    // before the application's own.
    handler = const shelf.Pipeline().addMiddleware(auth.gate).addHandler(
      (req) async {
        if (req.requestedUri.path.startsWith('/auth/')) {
          var response = await auth.handler(req);
          if (response.statusCode != HttpStatus.notFound) return response;
        }
        return shelf.Response.ok('package listing');
      },
    );
  }

  setUp(build);
  tearDown(() => auth.close());

  /// A browser navigation, carrying [cookies].
  Future<shelf.Response> browse(String path,
      {Map<String, String> cookies = const {}, String method = 'GET'}) async {
    return await handler(shelf.Request(
      method,
      Uri.parse('https://pub.example.org$path'),
      headers: {
        'user-agent': userAgent,
        'sec-fetch-mode': 'navigate',
        'accept': 'text/html',
        if (cookies.isNotEmpty)
          'cookie':
              cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      },
    ));
  }

  /// A fetch made by the running web UI.
  Future<shelf.Response> fetch(String path,
      {Map<String, String> cookies = const {}}) async {
    return await handler(shelf.Request(
      'GET',
      Uri.parse('https://pub.example.org$path'),
      headers: {
        'user-agent': userAgent,
        'sec-fetch-mode': 'cors',
        'accept': 'application/json',
        if (cookies.isNotEmpty)
          'cookie':
              cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      },
    ));
  }

  Map<String, String> cookiesOf(shelf.Response response) {
    var out = <String, String>{};
    for (var header in response.headersAll[HttpHeaders.setCookieHeader] ??
        const <String>[]) {
      var pair = header.split(';').first;
      var cut = pair.indexOf('=');
      if (cut <= 0) continue;
      var value = pair.substring(cut + 1);
      // A deletion clears the jar rather than storing an empty value.
      if (value.isEmpty) {
        out.remove(pair.substring(0, cut));
      } else {
        out[pair.substring(0, cut)] = value;
      }
    }
    return out;
  }

  /// Walks the whole sign-in flow and returns the resulting cookie jar.
  Future<Map<String, String>> signIn({String returnTo = '/'}) async {
    var login =
        await browse('/auth/login?return=${Uri.encodeComponent(returnTo)}');
    expect(login.statusCode, HttpStatus.found);

    var jar = cookiesOf(login);
    var state = Uri.parse(login.headers['location']!).queryParameters['state']!;

    var callback =
        await browse('/auth/callback?code=abc&state=$state', cookies: jar);
    expect(callback.statusCode, HttpStatus.found,
        reason: 'body: ${await callback.readAsString()}');
    expect(callback.headers['location'], returnTo);

    return {...jar, ...cookiesOf(callback)};
  }

  group('an anonymous visitor', () {
    test('is sent to the sign-in flow', () async {
      var response = await browse('/packages/foo');
      expect(response.statusCode, HttpStatus.found);
      expect(response.headers['location'],
          '/auth/login?return=${Uri.encodeComponent('/packages/foo')}');
    });

    test('keeps the query string they were on', () async {
      var response = await browse('/packages?q=widgets&sort=download');
      expect(
          Uri.decodeComponent(Uri.parse(response.headers['location']!)
              .queryParameters['return']!),
          '/packages?q=widgets&sort=download');
    });

    test('gets a machine-readable refusal on the data endpoints', () async {
      // Redirecting an XHR would hand the front end an HTML login page and
      // call it JSON.
      var response = await fetch('/webapi/packages');
      expect(response.statusCode, HttpStatus.unauthorized);
      var body = json.decode(await response.readAsString());
      expect(body['login'], '/auth/login');
    });

    test('can still resolve dependencies, for now', () async {
      // Closing the pub client's surface is a separate, deliberate step: it
      // breaks every consumer that has not yet run `dart pub token add`.
      expect((await fetch('/api/packages/foo')).statusCode, HttpStatus.ok);
      expect((await fetch('/packages/foo/versions/1.0.0.tar.gz')).statusCode,
          HttpStatus.ok);
    });

    test('can still fetch badges', () async {
      expect((await browse('/badge/v/foo')).statusCode, HttpStatus.ok);
    });
  });

  group('signing in', () {
    test('leads back to where the visitor was headed', () async {
      var login = await browse(
          '/auth/login?return=${Uri.encodeComponent('/packages/foo')}');
      var state =
          Uri.parse(login.headers['location']!).queryParameters['state']!;
      var callback = await browse('/auth/callback?code=abc&state=$state',
          cookies: cookiesOf(login));
      expect(callback.headers['location'], '/packages/foo');
    });

    test('opens the repository', () async {
      var jar = await signIn();
      var response = await browse('/packages/foo', cookies: jar);
      expect(response.statusCode, HttpStatus.ok);
      expect(await response.readAsString(), 'package listing');
    });

    test('records the user and a live session', () async {
      await signIn();
      expect(store.users['user-1']!.email, 'someone@example.org');
      expect(store.sessions.values.single.userId, 'user-1');
    });

    test('keeps the refresh token, encrypted', () async {
      await signIn();
      var stored = store.users['user-1']!.refreshTokenEnc;
      expect(stored, isNotNull);
      expect(stored, isNot(contains('refresh-1')));
      expect(auth.crypto.decrypt(stored!), 'refresh-1');
    });

    test('reports the signed-in user to the web UI', () async {
      var jar = await signIn();
      var response = await fetch('/auth/me', cookies: jar);
      var body = json.decode(await response.readAsString());
      expect(body['authenticated'], isTrue);
      expect(body['email'], 'someone@example.org');
      expect(body['admin'], isFalse);
    });
  });

  group('refusing a sign-in', () {
    test('a callback whose state does not match is rejected', () async {
      // Without this check a crafted callback could plant a session.
      var login = await browse('/auth/login');
      var response = await browse('/auth/callback?code=abc&state=forged',
          cookies: cookiesOf(login));
      expect(response.statusCode, HttpStatus.badRequest);
      expect(store.sessions, isEmpty);
    });

    test('a callback with no login cookie is rejected', () async {
      var response = await browse('/auth/callback?code=abc&state=whatever');
      expect(response.statusCode, HttpStatus.badRequest);
      expect(store.sessions, isEmpty);
    });

    test('an error from the provider is shown, not swallowed', () async {
      var login = await browse('/auth/login');
      var response = await browse(
          '/auth/callback?error=access_denied&error_description=Nope',
          cookies: cookiesOf(login));
      expect(response.statusCode, HttpStatus.forbidden);
      expect(await response.readAsString(), contains('Nope'));
    });

    test('someone outside the allowed groups is turned away', () async {
      build(allowedGroups: ['pubusers']);
      var login = await browse('/auth/login');
      var state =
          Uri.parse(login.headers['location']!).queryParameters['state']!;
      var response = await browse('/auth/callback?code=abc&state=$state',
          cookies: cookiesOf(login));

      expect(response.statusCode, HttpStatus.forbidden);
      expect(store.sessions, isEmpty);
    });

    test('a locally blocked user cannot sign back in', () async {
      // Otherwise blocking someone would last only until they clicked
      // "sign in" again.
      await signIn();
      await store.setUserStatus('user-1', UserStatus.blockedLocal,
          reason: 'blocked by an administrator');

      var login = await browse('/auth/login');
      var state =
          Uri.parse(login.headers['location']!).queryParameters['state']!;
      var response = await browse('/auth/callback?code=abc&state=$state',
          cookies: cookiesOf(login));

      expect(response.statusCode, HttpStatus.forbidden);
      expect(await response.readAsString(),
          contains('blocked by an administrator'));
    });

    test('a user the provider has since re-authorised is let back in',
        () async {
      await signIn();
      await store.setUserStatus('user-1', UserStatus.blockedUpstream,
          reason: 'was disabled');

      var jar = await signIn();
      expect(store.users['user-1']!.status, UserStatus.active);
      expect((await browse('/', cookies: jar)).statusCode, HttpStatus.ok);
    });
  });

  group('signing out', () {
    test('ends the session and the cookie', () async {
      var jar = await signIn();
      var response = await browse('/auth/logout', cookies: jar);
      expect(response.statusCode, HttpStatus.ok);
      expect(store.sessions.values.single.isRevoked, isTrue);

      var afterwards = await browse('/packages/foo', cookies: jar);
      expect(afterwards.statusCode, HttpStatus.unauthorized,
          reason: 'the visitor is told the session ended rather than being '
              'bounced silently through the provider');
    });
  });

  group('an administrator', () {
    setUp(() {
      build();
      provider.profile = const AuthenticatedUser(
          id: 'admin-1',
          email: 'boss@example.org',
          displayName: 'Boss',
          groups: ['developers', 'pubadmins']);
    });

    test('can reach the administration page', () async {
      var jar = await signIn();
      var response = await browse('/auth/admin', cookies: jar);
      expect(response.statusCode, HttpStatus.ok);
      expect(await response.readAsString(), contains('boss@example.org'));
    });

    test('can end someone else\'s sessions', () async {
      var adminJar = await signIn();

      // A second person signs in.
      provider.profile = const AuthenticatedUser(
          id: 'user-2', email: 'other@example.org', displayName: 'Other');
      var victimJar = await signIn();
      expect((await browse('/', cookies: victimJar)).statusCode, HttpStatus.ok);

      var page = await browse('/auth/admin', cookies: adminJar);
      var csrf = RegExp(r'name="csrf" value="([^"]+)"')
          .firstMatch(await page.readAsString())!
          .group(1)!;

      var action = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/auth/admin/action'),
        headers: {
          'user-agent': userAgent,
          'content-type': 'application/x-www-form-urlencoded',
          'cookie':
              adminJar.entries.map((e) => '${e.key}=${e.value}').join('; '),
        },
        body: 'csrf=${Uri.encodeQueryComponent(csrf)}&user=user-2&do=block',
      ));
      expect(action.statusCode, HttpStatus.found);

      var afterwards = await browse('/', cookies: victimJar);
      expect(afterwards.statusCode, HttpStatus.forbidden);
      expect(store.users['user-2']!.status, UserStatus.blockedLocal);
    });

    test('cannot act without a matching form token', () async {
      var jar = await signIn();
      var response = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/auth/admin/action'),
        headers: {
          'user-agent': userAgent,
          'content-type': 'application/x-www-form-urlencoded',
          'cookie': jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
        },
        body: 'csrf=forged&user=admin-1&do=block',
      ));
      expect(response.statusCode, HttpStatus.forbidden);
      expect(store.users['admin-1']!.status, UserStatus.active);
    });
  });

  group('a non-administrator', () {
    test('cannot reach the administration page', () async {
      var jar = await signIn();
      var response = await browse('/auth/admin', cookies: jar);
      expect(response.statusCode, HttpStatus.forbidden);
    });

    test('can manage their own sessions', () async {
      var jar = await signIn();
      var page = await browse('/auth/sessions', cookies: jar);
      expect(page.statusCode, HttpStatus.ok);

      var body = await page.readAsString();
      var csrf =
          RegExp(r'name="csrf" value="([^"]+)"').firstMatch(body)!.group(1)!;
      var sessionId = store.sessions.keys.single;

      var response = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/auth/sessions/revoke'),
        headers: {
          'user-agent': userAgent,
          'content-type': 'application/x-www-form-urlencoded',
          'cookie': jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
        },
        body: 'csrf=${Uri.encodeQueryComponent(csrf)}&session=$sessionId',
      ));
      expect(response.statusCode, HttpStatus.ok);
      expect(store.sessions[sessionId]!.isRevoked, isTrue);
    });
  });
}

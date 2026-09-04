import 'dart:convert';
import 'dart:io';

import 'package:in_pub/src/auth/auth_config.dart';
import 'package:in_pub/src/auth/auth_service.dart';
import 'package:in_pub/src/auth/auth_store.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:logging/logging.dart';
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

  AuthService? _built;

  /// Addresses that already publish packages here, as `bin/in_pub.dart`
  /// would report them from the package metadata.
  var packageUploaders = <String>{};

  /// Set to make the uploader lookup fail the way a momentary database fault
  /// does — the closure runs a Mongo `count`.
  Object? uploaderLookupError;

  void build(
      {List<String> allowedGroups = const [],
      bool canCheckUploaders = true,
      MemoryAuthStore? withStore}) {
    packageUploaders = <String>{};
    uploaderLookupError = null;
    _built?.close();
    store = withStore ?? MemoryAuthStore();
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
      googleAuth: false,
      isPackageUploader: canCheckUploaders
          ? (email) async {
              if (uploaderLookupError != null) throw uploaderLookupError!;
              return packageUploaders.contains(email);
            }
          : null,
    );

    _built = auth;
    // The same shape as App.serve: the gate in front, the auth routes tried
    // before the application's own.
    handler = const shelf.Pipeline().addMiddleware(auth.gate).addHandler(
      (req) async {
        // Mirrors App.serve: `/auth/` is the auth router's namespace, so
        // its answer is final — including a 404 it meant.
        if (req.requestedUri.path.startsWith('/auth/')) {
          return auth.handler(req);
        }
        return shelf.Response.ok('package listing');
      },
    );
  }

  setUp(build);
  tearDown(() => _built?.close());

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

  group('a redirect from the auth routes', () {
    /// The three that carry a `Set-Cookie`, which is what makes a stored
    /// redirect worse here than elsewhere: a cache configured to hold them
    /// would replay somebody else's session cookie to the next caller of the
    /// same url. Only the answers of the auth routes themselves — the gate's
    /// bounce to the sign-in page is checked in `pub_api_gate_test.dart`.
    test('is never stored, and every one of them sets a cookie', () async {
      var bounce =
          await browse('/auth/login?return=${Uri.encodeComponent('/')}');
      expect(bounce.statusCode, HttpStatus.found);
      expect(bounce.headers[HttpHeaders.cacheControlHeader], 'no-store',
          reason: 'the bounce to the provider carries the login-state cookie');
      expect(bounce.headersAll[HttpHeaders.setCookieHeader], isNotEmpty);

      var jar = cookiesOf(bounce);
      var state =
          Uri.parse(bounce.headers['location']!).queryParameters['state']!;
      var callback =
          await browse('/auth/callback?code=abc&state=$state', cookies: jar);
      expect(callback.statusCode, HttpStatus.found);
      expect(callback.headers[HttpHeaders.cacheControlHeader], 'no-store',
          reason: 'the callback hands out the new session cookie');
      expect(callback.headersAll[HttpHeaders.setCookieHeader], isNotEmpty);

      // `/auth/login?return=/` is a stable url a visitor lands on more than
      // once, and this branch of it rotates the session secret — so the
      // reply is one browser's live credential against an address anybody
      // can ask for.
      var signedIn = {...jar, ...cookiesOf(callback)};
      var again = await browse('/auth/login?return=${Uri.encodeComponent('/')}',
          cookies: signedIn);
      expect(again.statusCode, HttpStatus.found);
      expect(again.headers['location'], '/');
      expect(again.headers[HttpHeaders.cacheControlHeader], 'no-store');
    });
  });

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

    test('warns when a service token already publishes as that address',
        () async {
      // The address check runs one way only: it refuses a token that would
      // take an address an account already holds. Nobody was looking for the
      // collision arriving the other way round — an account signing in for
      // the first time under an address a live service token already
      // publishes as. `UserValidator` sees an account *change* address,
      // which a first sign-in is not, so this went unreported and two
      // credentials wrote to one identity, one of which no block can stop.
      await store.createToken(StoredToken(
        id: 'tok-1',
        secretHash: 'hash',
        kind: TokenKind.service,
        email: 'someone@example.org',
        displayName: 'Release pipeline',
        name: 'release pipeline',
        createdBy: 'admin-1',
        createdAt: DateTime.now().toUtc(),
      ));

      var warnings = <String>[];
      var listening = Logger.root.onRecord
          .where((record) => record.level >= Level.SEVERE)
          .listen((record) => warnings.add(record.message));
      try {
        await signIn();
      } finally {
        await listening.cancel();
      }

      expect(warnings.join('\n'), contains('release pipeline'));
      expect(store.users['user-1'], isNotNull,
          reason: 'reported, not repaired: which of the two is wrong is a '
              'judgement, and refusing the sign-in would lock a person out '
              'over a token an administrator minted');
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

  group('collecting a fresh consent', () {
    /// The cookie the callback hands out when it has decided a fresh consent
    /// is needed, which is the only thing that makes `/auth/login` end a
    /// session.
    Future<Map<String, String>> consentRequest() async {
      // The callback only asks for a consent when there is nothing left to
      // revalidate with, so whatever an earlier sign-in stored has to go
      // first — a decipherable refresh token on the record counts.
      for (var user in store.users.values.toList()) {
        store.users[user.id] = StoredUser(
          id: user.id,
          email: user.email,
          displayName: user.displayName,
          groups: user.groups,
          status: user.status,
          lastValidatedAt: user.lastValidatedAt,
          createdAt: user.createdAt,
          updatedAt: user.updatedAt,
        );
      }
      provider.initialRefreshToken = null;
      var login = await browse('/auth/login');
      var callback = await browse(
          '/auth/callback?code=abc&state='
          '${Uri.parse(login.headers['location']!).queryParameters['state']!}',
          cookies: cookiesOf(login));
      expect(callback.statusCode, HttpStatus.found);
      var jar = cookiesOf(callback);
      expect(jar.keys, contains('inpub_consent'));
      provider.initialRefreshToken = 'refresh-1';
      return jar;
    }

    test('ends the session it is leaving behind', () async {
      // This path deliberately ignores the "already signed in" check and
      // deletes the cookie, because an existing session is exactly what it
      // is trying to make revalidatable again. Deleting the cookie only
      // stops *this browser* presenting the session: the row stayed live for
      // the whole idle window — counted on the administration screen, listed
      // with a working End button, and re-checked by every sweep — for a
      // browser that could no longer make a single request with it.
      var jar = await signIn();
      var sessionId = store.sessions.keys.single;
      expect(store.sessions[sessionId]!.isRevoked, isFalse);

      var response = await browse('/auth/login',
          cookies: {...jar, ...await consentRequest()});

      expect(response.statusCode, HttpStatus.found,
          reason: 'the browser leaves for the provider');
      expect(store.sessions[sessionId]!.isRevoked, isTrue);
    });

    test('but not when there is nowhere to send the browser', () async {
      // The provider being momentarily unreachable answers with an error
      // page and leaves the person exactly as they were. Ending the session
      // first would turn a few seconds of provider downtime into a sign-out.
      var jar = await signIn();
      var sessionId = store.sessions.keys.single;
      var consent = await consentRequest();
      provider.authorizationError =
          IdentityUnavailableException('discovery failed');

      var response = await browse('/auth/login', cookies: {...jar, ...consent});

      expect(response.statusCode, HttpStatus.serviceUnavailable);
      expect(store.sessions[sessionId]!.isRevoked, isFalse);
    });

    test('and a link anybody can post does not', () async {
      // `/auth/login` is a public unauthenticated GET and `SameSite=Lax`
      // sends the session cookie on a top-level navigation, so reading the
      // instruction off the query string meant any page linking to
      // `/auth/login?consent=1` signed the visitor out. The instruction has
      // to be one this server issued.
      var jar = await signIn();
      var sessionId = store.sessions.keys.single;

      var response = await browse('/auth/login?consent=1', cookies: jar);

      expect(store.sessions[sessionId]!.isRevoked, isFalse);
      expect(response.headers['location'], '/',
          reason: 'an already signed-in visitor just goes where they asked');
    });

    test('nor one whose deadline has passed', () async {
      // A signature over a fixed word would be one value, good forever and
      // the same for every user, so anyone able to write a cookie for this
      // domain could replay it to sign a visitor out on every visit. The
      // cookie's own `Max-Age` is the client's to honour; the deadline that
      // counts is inside what was signed.
      var jar = await signIn();
      var sessionId = store.sessions.keys.single;
      var expired = auth.crypto.sign('consent:'
          '${DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch}');

      await browse('/auth/login', cookies: {...jar, 'inpub_consent': expired});

      expect(store.sessions[sessionId]!.isRevoked, isFalse);
    });

    test('nor does a forged one', () async {
      // The cookie is signed. A value the browser was handed by somebody
      // else — a sibling subdomain can set a cookie for the parent — must
      // not count as this server having asked for a consent.
      var jar = await signIn();
      var sessionId = store.sessions.keys.single;

      await browse('/auth/login',
          cookies: {...jar, 'inpub_consent': 'consent.not-a-real-signature'});

      expect(store.sessions[sessionId]!.isRevoked, isFalse);
    });

    test('and it is spent once, so Back does not sign you out again', () async {
      // The callback reaches `/auth/login` by 302, so that url sits in the
      // browser's history. Leaving the instruction standing meant pressing
      // Back after signing in silently ended the session and burned another
      // provider consent prompt.
      var consent = await consentRequest();
      var first = await browse('/auth/login', cookies: consent);
      expect(first.headersAll[HttpHeaders.setCookieHeader],
          contains(startsWith('inpub_consent=;')),
          reason: 'reading the instruction spends it, so the browser drops '
              'it');

      var jar = await signIn();
      var sessionId = store.sessions.keys.single;

      // Back onto the same url. The consent cookie is no longer in the jar,
      // which is the whole reason this stops ending the session.
      await browse('/auth/login', cookies: jar);

      expect(store.sessions[sessionId]!.isRevoked, isFalse);
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

    /// Walks a sign-in that produces no usable refresh token: the callback
    /// bounces once through `prompt=consent`, and only the second failure
    /// refuses. Returns the final response.
    Future<shelf.Response> signInWithoutRefreshToken() async {
      var login = await browse('/auth/login');
      var first = await browse(
          '/auth/callback?code=abc&state='
          '${Uri.parse(login.headers['location']!).queryParameters['state']!}',
          cookies: cookiesOf(login));

      expect(first.statusCode, HttpStatus.found,
          reason: 'the first failure asks the provider to prompt again');
      // Carried in a signed cookie, not in the url: `/auth/login` ends the
      // caller's session when it sees this, and a public GET must not take
      // that instruction from anyone who can post a link.
      expect(cookiesOf(first).keys, contains('inpub_consent'));

      var retry =
          await browse(first.headers['location']!, cookies: cookiesOf(first));
      expect(provider.consentForced, isTrue,
          reason: 'the retry has to actually ask for a fresh consent');

      return browse(
          '/auth/callback?code=abc&state='
          '${Uri.parse(retry.headers['location']!).queryParameters['state']!}',
          cookies: cookiesOf(retry));
    }

    test(
        'a provider that issues no refresh token is asked again, then '
        'refused', () async {
      // Signing them in would work for one revalidation interval and then
      // throw them out, because the background check has nothing to ask the
      // provider with — forever. But refusing outright locked every account
      // on a provider that issues a refresh token only on first consent out
      // of the server permanently, so the first failure asks for consent
      // again and only the second refuses.
      provider.initialRefreshToken = null;

      var response = await signInWithoutRefreshToken();

      expect(response.statusCode, HttpStatus.forbidden);
      expect(await response.readAsString(), contains('offline_access'));
      expect(store.sessions, isEmpty);
    });

    test('and a consent that does produce one signs them in', () async {
      // The recovery this exists for: the stored credential no longer opens,
      // the plain sign-in returns nothing, and the forced consent does.
      provider.initialRefreshToken = null;

      var login = await browse('/auth/login');
      var first = await browse(
          '/auth/callback?code=abc&state='
          '${Uri.parse(login.headers['location']!).queryParameters['state']!}',
          cookies: cookiesOf(login));
      expect(first.statusCode, HttpStatus.found);

      provider.initialRefreshToken = 'refresh-after-consent';
      var retry =
          await browse(first.headers['location']!, cookies: cookiesOf(first));
      var done = await browse(
          '/auth/callback?code=abc&state='
          '${Uri.parse(retry.headers['location']!).queryParameters['state']!}',
          cookies: cookiesOf(retry));

      expect(done.statusCode, HttpStatus.found);
      expect(store.sessions, hasLength(1));
    });

    test('a stored token that no longer decrypts does not count', () async {
      // `setUserStatus` deliberately keeps the ciphertext when marking an
      // account `needsSignIn`, so after the signing secret is rotated every
      // record still has one — it just no longer opens. Reading presence as
      // "can revalidate" produced the very loop this check exists to stop.
      await signIn();
      var user = store.users.values.single;
      store.users[user.id] = StoredUser(
        id: user.id,
        email: user.email,
        displayName: user.displayName,
        groups: user.groups,
        status: user.status,
        refreshTokenEnc: 'not-decipherable-under-this-key',
        lastValidatedAt: user.lastValidatedAt,
        validationFailures: 0,
        createdAt: user.createdAt,
        updatedAt: user.updatedAt,
      );
      provider.initialRefreshToken = null;

      var response = await signInWithoutRefreshToken();

      expect(response.statusCode, HttpStatus.forbidden);
      expect(await response.readAsString(), contains('offline_access'));
    });

    test('but a stored refresh token from an earlier sign-in is enough',
        () async {
      // Providers that issue one on first consent only return null on every
      // later exchange; the account already has what it needs.
      await signIn();
      provider.initialRefreshToken = null;

      var jar = await signIn();
      expect((await browse('/', cookies: jar)).statusCode, HttpStatus.ok);
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

    Future<Map<String, dynamic>> adminView(Map<String, String> jar) async {
      var res = await fetch('/auth/api/admin', cookies: jar);
      expect(res.statusCode, HttpStatus.ok);
      return (json.decode(await res.readAsString())
          as Map<String, dynamic>)['data'] as Map<String, dynamic>;
    }

    Future<shelf.Response> act(Map<String, String> jar, String csrf,
        String userId, String action) async {
      return await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/auth/api/admin/action'),
        headers: {
          'user-agent': userAgent,
          'content-type': 'application/json',
          'x-csrf-token': csrf,
          'cookie': jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
        },
        body: json.encode({'user': userId, 'do': action}),
      ));
    }

    test('sees everyone who has signed in', () async {
      var jar = await signIn();
      var view = await adminView(jar);

      expect(view['csrfToken'], isNotEmpty);
      var users = view['users'] as List;
      expect(users, hasLength(1));
      expect(users.first['email'], 'boss@example.org');
      expect(users.first['status'], 'active');
      expect(users.first['liveSessions'], 1);
    });

    test('can end someone else\'s sessions', () async {
      var adminJar = await signIn();

      provider.profile = const AuthenticatedUser(
          id: 'user-2', email: 'other@example.org', displayName: 'Other');
      var victimJar = await signIn();
      expect((await browse('/', cookies: victimJar)).statusCode, HttpStatus.ok);

      var view = await adminView(adminJar);
      var res = await act(
          adminJar, view['csrfToken'] as String, 'user-2', 'end-sessions');
      expect(res.statusCode, HttpStatus.ok);

      var after = await browse('/', cookies: victimJar);
      expect(after.statusCode, HttpStatus.unauthorized);
    });

    test('can block and unblock', () async {
      var adminJar = await signIn();
      provider.profile = const AuthenticatedUser(
          id: 'user-2', email: 'other@example.org', displayName: 'Other');
      var victimJar = await signIn();

      var view = await adminView(adminJar);
      var csrf = view['csrfToken'] as String;

      await act(adminJar, csrf, 'user-2', 'block');
      expect(store.users['user-2']!.status, UserStatus.blockedLocal);
      expect((await browse('/', cookies: victimJar)).statusCode,
          HttpStatus.forbidden);

      await act(adminJar, csrf, 'user-2', 'unblock');
      expect(store.users['user-2']!.status, UserStatus.active);
    });

    test('an action answers with the refreshed view', () async {
      // So the screen never has to guess what the change did.
      var adminJar = await signIn();
      provider.profile = const AuthenticatedUser(
          id: 'user-2', email: 'other@example.org', displayName: 'Other');
      await signIn();

      var view = await adminView(adminJar);
      var res =
          await act(adminJar, view['csrfToken'] as String, 'user-2', 'block');

      var data = (json.decode(await res.readAsString())
          as Map<String, dynamic>)['data'] as Map<String, dynamic>;
      var blocked = (data['users'] as List)
          .firstWhere((u) => u['id'] == 'user-2') as Map<String, dynamic>;
      expect(blocked['status'], 'blockedLocal');
      expect(blocked['liveSessions'], 0);
    });

    test('ending your own sessions signs you out', () async {
      // The refreshed view cannot be produced for a session that no longer
      // exists, and saying so is more honest than pretending otherwise.
      var jar = await signIn();
      var view = await adminView(jar);
      var res = await act(
          jar, view['csrfToken'] as String, 'admin-1', 'end-sessions');
      expect(res.statusCode, HttpStatus.unauthorized);
      expect(store.sessions.values.single.isRevoked, isTrue);
    });

    test('cannot act without a matching anti-forgery token', () async {
      var jar = await signIn();
      var res = await act(jar, 'forged', 'admin-1', 'block');
      expect(res.statusCode, HttpStatus.forbidden);
      expect(store.users['admin-1']!.status, UserStatus.active);
    });

    test('an unknown user is refused', () async {
      var jar = await signIn();
      var view = await adminView(jar);
      var res = await act(jar, view['csrfToken'] as String, 'nobody', 'block');
      expect(res.statusCode, HttpStatus.notFound);
    });

    test('an action keeps the session cookie it was given', () async {
      // The action used to build its answer by resolving the session a second
      // time, throwing away the rotated cookie the first resolve produced and
      // rotating again — leaving the browser holding a secret good only for
      // the grace period.
      var adminJar = await signIn();
      provider.profile = const AuthenticatedUser(
          id: 'user-2', email: 'other@example.org', displayName: 'Other');
      await signIn();

      var view = await adminView(adminJar);
      var res =
          await act(adminJar, view['csrfToken'] as String, 'user-2', 'block');

      var reissued = res.headersAll[HttpHeaders.setCookieHeader] ?? const [];
      for (var cookie in reissued) {
        if (!cookie.startsWith('inpub_session=')) continue;
        var value = cookie.split(';').first.split('=').sublist(1).join('=');
        // Whatever it hands back has to work on the next request.
        var next = await browse('/', cookies: {'inpub_session': value});
        expect(next.statusCode, HttpStatus.ok);
      }
    });

    test('a wrongly typed field is a bad request, not a crash', () async {
      var jar = await signIn();
      var view = await adminView(jar);
      var res = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/auth/api/admin/action'),
        headers: {
          'user-agent': userAgent,
          'content-type': 'application/json',
          'x-csrf-token': view['csrfToken'] as String,
          'cookie': jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
        },
        body: json.encode({
          'user': 42,
          'do': ['block']
        }),
      ));
      expect(res.statusCode, HttpStatus.badRequest);
      expect(json.decode(await res.readAsString())['error'], isNotEmpty);
    });

    test('cannot block themselves', () async {
      // There is no way back: the sign-in callback refuses a blocked account
      // outright, and undoing it would mean editing the database by hand.
      var jar = await signIn();
      var view = await adminView(jar);
      var res = await act(jar, view['csrfToken'] as String, 'admin-1', 'block');

      expect(res.statusCode, HttpStatus.badRequest);
      expect(store.users['admin-1']!.status, UserStatus.active);
    });

    test('ending their own sessions clears the cookie', () async {
      var jar = await signIn();
      var view = await adminView(jar);
      var res = await act(
          jar, view['csrfToken'] as String, 'admin-1', 'end-sessions');

      expect(res.statusCode, HttpStatus.unauthorized);
      expect(res.headersAll[HttpHeaders.setCookieHeader]?.join(' ') ?? '',
          contains('Max-Age=0'),
          reason: 'otherwise the browser keeps presenting a dead session');
    });

    test('the old page url leads into the application', () async {
      var jar = await signIn();
      expect((await browse('/auth/admin', cookies: jar)).headers['location'],
          '/admin');
    });
  });

  group('a non-administrator', () {
    test('is refused the administration data', () async {
      var jar = await signIn();
      var res = await fetch('/auth/api/admin', cookies: jar);
      expect(res.statusCode, HttpStatus.forbidden);
      expect(await res.readAsString(), contains('administrators'));
    });

    test('cannot act on anyone', () async {
      var jar = await signIn();
      var res = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/auth/api/admin/action'),
        headers: {
          'user-agent': userAgent,
          'content-type': 'application/json',
          'cookie': jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
        },
        body: json.encode({'user': 'user-1', 'do': 'block'}),
      ));
      expect(res.statusCode, HttpStatus.forbidden);
      expect(store.users['user-1']!.status, UserStatus.active);
    });
  });

  group('the account API', () {
    Future<shelf.Response> post(String path, Map<String, String> jar,
        {String? csrf, Map<String, dynamic> body = const {}}) async {
      return await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org$path'),
        headers: {
          'user-agent': userAgent,
          'content-type': 'application/json',
          if (csrf != null) 'x-csrf-token': csrf,
          'cookie': jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
        },
        body: json.encode(body),
      ));
    }

    Future<Map<String, dynamic>> account(Map<String, String> jar) async {
      var res = await fetch('/auth/api/account', cookies: jar);
      expect(res.statusCode, HttpStatus.ok);
      return (json.decode(await res.readAsString())
          as Map<String, dynamic>)['data'] as Map<String, dynamic>;
    }

    test('describes the account, its sessions and its tokens', () async {
      var jar = await signIn();
      var view = await account(jar);

      expect(view['email'], 'someone@example.org');
      expect(view['sessions'], hasLength(1));
      expect(view['tokens'], isEmpty);
      expect(view['csrfToken'], isNotEmpty);
      expect(view['currentSessionId'], store.sessions.keys.single);
    });

    test('an anonymous request is refused with JSON, not a redirect', () async {
      // An XHR follows a redirect silently and hands the caller the sign-in
      // page parsed as JSON.
      var res = await fetch('/auth/api/account');
      expect(res.statusCode, HttpStatus.unauthorized);
      expect(json.decode(await res.readAsString())['login'], '/auth/login');
    });

    test('a token can be created and then used', () async {
      var jar = await signIn();
      var view = await account(jar);

      var res = await post('/auth/api/account/tokens/create', jar,
          csrf: view['csrfToken'] as String,
          body: {'name': 'laptop', 'lifetimeDays': 90});
      expect(res.statusCode, HttpStatus.ok);

      var created = (json.decode(await res.readAsString())
          as Map<String, dynamic>)['data'] as Map<String, dynamic>;
      expect(created['value'], startsWith('inpub_'));

      var resolved = await auth.tokens.resolve(created['value'] as String);
      expect(resolved.isAccepted, isTrue);
      expect(resolved.user!.email, 'someone@example.org');
    });

    test('the value never appears again', () async {
      var jar = await signIn();
      var view = await account(jar);
      await post('/auth/api/account/tokens/create', jar,
          csrf: view['csrfToken'] as String,
          body: {'name': 'laptop', 'lifetimeDays': 0});

      var again = await account(jar);
      expect(json.encode(again), contains('laptop'));
      expect(json.encode(again), isNot(contains('inpub_')),
          reason: 'only a hash is kept, so it could not be sent again even if '
              'the endpoint wanted to');
    });

    test('a change without the anti-forgery token is refused', () async {
      var jar = await signIn();
      var res = await post('/auth/api/account/tokens/create', jar,
          body: {'name': 'laptop'});
      expect(res.statusCode, HttpStatus.forbidden);
      expect(store.tokens, isEmpty);
    });

    test('a forged anti-forgery token is refused', () async {
      var jar = await signIn();
      var res = await post('/auth/api/account/tokens/create', jar,
          csrf: 'forged', body: {'name': 'laptop'});
      expect(res.statusCode, HttpStatus.forbidden);
      expect(store.tokens, isEmpty);
    });

    test('a non-administrator cannot mint a service token', () async {
      // A service token answers to nobody upstream, so issuing one is an
      // administrator's decision.
      var jar = await signIn();
      var view = await account(jar);
      var res = await post('/auth/api/account/tokens/create', jar,
          csrf: view['csrfToken'] as String,
          body: {'kind': 'service', 'name': 'ci', 'email': 'ci@example.org'});

      expect(res.statusCode, HttpStatus.forbidden);
      expect(store.tokens, isEmpty);
    });

    test('a token can be revoked', () async {
      var jar = await signIn();
      var view = await account(jar);
      var created = json.decode(await (await post(
              '/auth/api/account/tokens/create', jar,
              csrf: view['csrfToken'] as String,
              body: {'name': 'laptop', 'lifetimeDays': 0}))
          .readAsString()) as Map<String, dynamic>;
      var id = (created['data'] as Map<String, dynamic>)['token']['id'];

      var res = await post('/auth/api/account/tokens/revoke', jar,
          csrf: view['csrfToken'] as String, body: {'token': id});
      expect(res.statusCode, HttpStatus.ok);
      expect(store.tokens.values.single.isRevoked, isTrue);
    });

    test('revoking the same token twice does not report success twice',
        () async {
      // The store's update is conditional on the row still being live, so the
      // second call changes nothing. Answering "revoked" regardless reported
      // a success that had not happened and wrote a revocation into the log
      // that nobody performed — the same shape as `addUploader` answering
      // "uploader added" over an update matching no document.
      var jar = await signIn();
      var view = await account(jar);
      var created = json.decode(await (await post(
              '/auth/api/account/tokens/create', jar,
              csrf: view['csrfToken'] as String,
              body: {'name': 'laptop', 'lifetimeDays': 0}))
          .readAsString()) as Map<String, dynamic>;
      var id = (created['data'] as Map<String, dynamic>)['token']['id'];
      Future<shelf.Response> revoke() =>
          post('/auth/api/account/tokens/revoke', jar,
              csrf: view['csrfToken'] as String, body: {'token': id});

      expect((await revoke()).statusCode, HttpStatus.ok);

      var again = await revoke();
      expect(again.statusCode, HttpStatus.conflict);
      expect(json.decode(await again.readAsString())['error'],
          contains('already been revoked'));
    });

    test('somebody else\'s token cannot be revoked', () async {
      var jar = await signIn();
      var view = await account(jar);

      // A token belonging to another account.
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-2', email: 'other@example.org', displayName: 'Other'),
          validatedAt: DateTime.now());
      var theirs = await auth.tokens.issuePersonal(
          owner: (await store.getUser('user-2'))!, name: 'theirs');

      var res = await post('/auth/api/account/tokens/revoke', jar,
          csrf: view['csrfToken'] as String, body: {'token': theirs.record.id});
      expect(res.statusCode, HttpStatus.notFound);
      expect(store.tokens[theirs.record.id]!.isRevoked, isFalse);
    });

    test('ending the current session signs you out', () async {
      var jar = await signIn();
      var view = await account(jar);

      var res = await post('/auth/api/account/sessions/revoke', jar,
          csrf: view['csrfToken'] as String,
          body: {'session': view['currentSessionId']});

      expect(res.statusCode, HttpStatus.ok);
      var data = (json.decode(await res.readAsString())
          as Map<String, dynamic>)['data'] as Map<String, dynamic>;
      expect(data['signedOut'], isTrue);
      expect(store.sessions.values.single.isRevoked, isTrue);
    });

    test('ending the same session twice does not report success twice',
        () async {
      // Exactly the defect the token route twenty lines below was changed
      // for: the store's write is conditional on the row still being live,
      // so the second call changes nothing, and answering "ended" regardless
      // wrote an end into the log that nobody performed.
      var jar = await signIn();
      var view = await account(jar);
      // A second session of the same user, so ending it does not sign this
      // browser out and the second attempt can be made with the same jar.
      var other = await auth.sessions.create(
          shelf.Request('GET', Uri.parse('https://pub.example.org/'),
              headers: {'user-agent': 'Mozilla/5.0 (other)'}),
          store.users['user-1']!.toAuthenticatedUser());
      var otherId = other.split('=')[1].split('.').first;

      Future<shelf.Response> end() =>
          post('/auth/api/account/sessions/revoke', jar,
              csrf: view['csrfToken'] as String, body: {'session': otherId});

      expect((await end()).statusCode, HttpStatus.ok);

      var again = await end();
      expect(again.statusCode, HttpStatus.conflict);
      expect(json.decode(await again.readAsString())['error'],
          contains('already ended'));
    });

    test('the listings are whatever the store calls live', () async {
      // The store drops revoked and expired rows in the query and says so in
      // a comment warning that a caller filtering afterwards "would pass here
      // and read history in production". Re-applying the rule on the way out
      // put it in a third place; this checks the two that decide it still
      // agree.
      var jar = await signIn();
      var view = await account(jar);
      var created = json.decode(await (await post(
              '/auth/api/account/tokens/create', jar,
              csrf: view['csrfToken'] as String,
              body: {'name': 'laptop', 'lifetimeDays': 0}))
          .readAsString()) as Map<String, dynamic>;
      var id =
          (created['data'] as Map<String, dynamic>)['token']['id'] as String;

      await store.revokeToken(id, 'no longer needed');

      expect((await account(jar))['tokens'], isEmpty);
      expect(await store.listTokensOfUser('user-1'), isEmpty,
          reason: 'and it is the store that decided that');
    });

    /// A POST whose body is exactly [raw], bypassing the JSON encoding the
    /// helper above does — which is the whole point.
    Future<shelf.Response> postRaw(String path, Map<String, String> jar,
            String csrf, String raw) async =>
        handler(shelf.Request(
          'POST',
          Uri.parse('https://pub.example.org$path'),
          headers: {
            'user-agent': userAgent,
            'content-type': 'application/json',
            'x-csrf-token': csrf,
            'cookie': jar.entries.map((e) => '${e.key}=${e.value}').join('; '),
          },
          body: raw,
        ));

    test('a body the server cannot read does not mint a token', () async {
      // Read as "no fields given", a truncated or non-object body issued a
      // real credential — named `unnamed`, good for ninety days — and
      // returned its one-time value against a request the client believes
      // failed. Nobody records the value, and the account is left holding a
      // live credential it does not know about.
      var jar = await signIn();
      var view = await account(jar);

      for (var raw in const ['{"name": "lap', '[1,2,3]', '"laptop"', '7']) {
        var res = await postRaw('/auth/api/account/tokens/create', jar,
            view['csrfToken'] as String, raw);
        expect(res.statusCode, HttpStatus.badRequest, reason: raw);
        expect(await res.readAsString(), isNot(contains('inpub_')),
            reason: raw);
        expect(store.tokens, isEmpty, reason: raw);
      }
    });

    test('an empty body is still a request with no fields', () async {
      // Sending nothing is readable, and the defaults are exactly what it
      // means. Only a body that arrived and could not be parsed is an error.
      var jar = await signIn();
      var view = await account(jar);

      var res = await postRaw('/auth/api/account/tokens/create', jar,
          view['csrfToken'] as String, '');

      expect(res.statusCode, HttpStatus.ok);
      expect(store.tokens.values.single.name, 'unnamed');
    });

    group('a service token cannot be given somebody else\'s address', () {
      // The address a service token carries is what a publish is recorded as
      // and what the package's uploader list is checked against. Handing out
      // one that already belongs to somebody turns "may manage sessions"
      // into "may publish as them, and delete their versions".
      setUp(() {
        provider.profile = const AuthenticatedUser(
            id: 'admin-1',
            email: 'boss@example.org',
            displayName: 'Boss',
            groups: ['developers', 'pubadmins']);
      });

      Future<shelf.Response> mint(String email) async {
        var jar = await signIn();
        var view = await account(jar);
        return post('/auth/api/account/tokens/create', jar,
            csrf: view['csrfToken'] as String,
            body: {'kind': 'service', 'name': 'ci', 'email': email});
      }

      test('when the address belongs to an account', () async {
        await store.upsertUser(
            const AuthenticatedUser(
                id: 'user-2', email: 'other@example.org', displayName: 'O'),
            validatedAt: DateTime.now());

        expect(
            (await mint('other@example.org')).statusCode, HttpStatus.forbidden);
        expect(store.tokens, isEmpty);
      });

      test('when the address only publishes packages', () async {
        // Nobody by this name has ever signed in, so there is no account to
        // find — this is every publisher from before authentication existed,
        // and checking `auth_users` alone missed all of them.
        packageUploaders.add('legacy@example.org');

        expect((await mint('legacy@example.org')).statusCode,
            HttpStatus.forbidden);
        expect(store.tokens, isEmpty);
      });

      test('but a fresh address is fine', () async {
        // It owns nothing, so it can only reach a package once somebody who
        // already publishes there adds it to the uploader list.
        expect((await mint('ci@example.org')).statusCode, HttpStatus.ok);
        expect(store.tokens.values.single.email, 'ci@example.org');
      });

      test('not even your own', () async {
        // A service token answers to no account — `TokenService.resolve`
        // never consults one — so blocking the administrator who made it
        // does not stop it. One carrying their own address is a credential
        // that outlives their access, under their own name.
        expect(
            (await mint('boss@example.org')).statusCode, HttpStatus.forbidden);
        expect(store.tokens, isEmpty);
      });

      test('a lookup that fails refuses with words, not a 500', () async {
        // The closure counts documents in Mongo, so a momentary database
        // fault lands in it. Left to escape, it came back as an unhandled 500
        // and an opaque error page — while the check's own documentation says
        // that when the question cannot be asked, the honest answer is a
        // refusal somebody can read and retry.
        uploaderLookupError = StateError('connection closed');

        var res = await mint('ci@example.org');

        expect(res.statusCode, HttpStatus.forbidden);
        expect(json.decode(await res.readAsString())['error'],
            contains('could not check'));
        expect(store.tokens, isEmpty);
      });

      test('a server that cannot check ownership refuses outright', () async {
        // An embedder that wires the auth layer without the package
        // metadata cannot tell whether an address already publishes here.
        // Guessing wrong hands out exactly the escalation the check exists
        // to stop, so the answer is no.
        build(canCheckUploaders: false);
        provider.profile = const AuthenticatedUser(
            id: 'admin-1',
            email: 'boss@example.org',
            displayName: 'Boss',
            groups: ['developers', 'pubadmins']);

        expect((await mint('ci@example.org')).statusCode, HttpStatus.forbidden);
      });

      test('an address another service token already uses is refused',
          () async {
        // A service address is in no account and on no uploader list until
        // its token has published, so neither check above sees the clash.
        // Two credentials publishing as one identity is exactly what "give
        // the token an address of its own" exists to prevent, and revoking
        // one would leave the other working.
        expect((await mint('ci@example.org')).statusCode, HttpStatus.ok);
        expect((await mint('ci@example.org')).statusCode, HttpStatus.forbidden);
        expect(store.tokens, hasLength(1));
      });

      test('something that is not an address is refused', () async {
        // It would be matched against uploader lists as written, so a name
        // typed here is a mistake worth catching at the point of entry.
        expect((await mint('ci')).statusCode, HttpStatus.forbidden);
        expect(store.tokens, isEmpty);
      });

      test('two creations racing for one address produce one token', () async {
        // The check reads and the issue writes, and a request that arrived
        // between the two passed the same check: both administrators walked
        // away with a credential publishing as one identity, and revoking
        // either left the other working.
        var jar = await signIn();
        var csrf = (await account(jar))['csrfToken'] as String;
        Future<shelf.Response> create(String name) => post(
            '/auth/api/account/tokens/create', jar,
            csrf: csrf,
            body: {'kind': 'service', 'name': name, 'email': 'ci@example.org'});

        var both = await Future.wait([create('ci-a'), create('ci-b')]);

        expect(both.map((r) => r.statusCode),
            unorderedEquals(<int>[HttpStatus.ok, HttpStatus.forbidden]));
        expect(
            await store.serviceTokensForEmail('ci@example.org'), hasLength(1));
      });
    });

    test('a token is refused when the account has no address to publish as',
        () async {
      // A provider with no `email` claim leaves the account's address empty,
      // and a personal token copied it without a word. Publishing then
      // records `uploader: ''`, which the next such account is already on.
      provider.profile = const AuthenticatedUser(
          id: 'user-1', email: '', displayName: 'No Address');
      var jar = await signIn();
      var view = await account(jar);

      var res = await post('/auth/api/account/tokens/create', jar,
          csrf: view['csrfToken'] as String, body: {'name': 'laptop'});

      expect(res.statusCode, HttpStatus.forbidden,
          reason: 'refused with an explanation, not thrown into a 500');
      expect(store.tokens, isEmpty);
    });

    test('a wrongly typed lifetime is refused, not crashed on', () async {
      var jar = await signIn();
      var view = await account(jar);
      var res = await post('/auth/api/account/tokens/create', jar,
          csrf: view['csrfToken'] as String,
          body: {'name': 'ci', 'lifetimeDays': 'ninety'});
      // Unreadable means fall back to the default rather than fail, but it
      // must not throw its way to a 500.
      expect(res.statusCode, HttpStatus.ok);
    });

    test('an absurd lifetime cannot overflow into an expired token', () async {
      var jar = await signIn();
      var view = await account(jar);
      var res = await post('/auth/api/account/tokens/create', jar,
          csrf: view['csrfToken'] as String,
          body: {'name': 'ci', 'lifetimeDays': 1000000000000000});
      expect(res.statusCode, HttpStatus.ok);

      var created = (json.decode(await res.readAsString())
          as Map<String, dynamic>)['data'] as Map<String, dynamic>;
      expect((await auth.tokens.resolve(created['value'] as String)).isAccepted,
          isTrue);
    });

    test('an expired token is not listed as live', () async {
      var jar = await signIn();
      var view = await account(jar);
      await post('/auth/api/account/tokens/create', jar,
          csrf: view['csrfToken'] as String,
          body: {'name': 'laptop', 'lifetimeDays': 1});

      // Expiry is swept in the background, so a listing can hold rows that
      // are already past it; showing one as live is worse than hiding it.
      var record = store.tokens.values.single;
      store.tokens[record.id] = StoredToken(
        id: record.id,
        secretHash: record.secretHash,
        kind: record.kind,
        userId: record.userId,
        email: record.email,
        displayName: record.displayName,
        name: record.name,
        createdBy: record.createdBy,
        createdAt: record.createdAt,
        expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
      );

      expect((await account(jar))['tokens'], isEmpty);
    });

    test('a refusal still carries the rotated session cookie', () async {
      // `sessions.resolve` may have re-issued the secret before the refusal
      // was decided. Dropping the Set-Cookie leaves the browser on a secret
      // that dies with the grace window, and signs the person out silently.
      var jar = await signIn();
      // Warm the session so the next request is due a rotation.
      await account(jar);
      var res = await post('/auth/api/account/tokens/create', jar,
          csrf: 'forged', body: {'name': 'ci'});

      expect(res.statusCode, HttpStatus.forbidden);
      var reissued = res.headersAll[HttpHeaders.setCookieHeader] ?? const [];
      for (var cookie
          in reissued.where((c) => c.startsWith('inpub_session='))) {
        var value = cookie.split(';').first.split('=').sublist(1).join('=');
        expect(
            (await browse('/', cookies: {'inpub_session': value})).statusCode,
            HttpStatus.ok);
      }
    });

    test('the old page urls lead into the application', () async {
      // Links to them are already out there.
      var jar = await signIn();
      expect((await browse('/auth/sessions', cookies: jar)).headers['location'],
          '/account?tab=sessions');
      expect((await browse('/auth/tokens', cookies: jar)).headers['location'],
          '/account',
          reason: 'tokens is the tab the screen opens on');
    });

    test('a fault listing service tokens does not empty the screen', () async {
      // Service tokens are administrators-only and purely informational:
      // nothing on the screen acts on them. Collected through a record's
      // `wait`, a failure on that one leg became a `ParallelWaitError` and
      // took the sessions and personal tokens — what the screen is for —
      // down with it, as an opaque 500.
      build(withStore: _StoreThatCannotListServiceTokens());
      provider.profile = const AuthenticatedUser(
          id: 'user-1',
          email: 'someone@example.org',
          displayName: 'Someone',
          groups: ['pubadmins']);
      var jar = await signIn();

      var view = await account(jar);
      expect(view['sessions'], hasLength(1));
      expect(view['isAdmin'], isTrue);
      expect(view['serviceTokens'], isEmpty);
    });

    test('a fault listing the sessions says so rather than 500', () async {
      build(withStore: _StoreThatCannotListSessions());
      var jar = await signIn();

      var res = await fetch('/auth/api/account', cookies: jar);
      expect(res.statusCode, HttpStatus.serviceUnavailable);
      expect(
          (json.decode(await res.readAsString())
              as Map<String, dynamic>)['error'],
          contains('could not be read'));
    });
  });

  group('the access-denied page', () {
    test('says why the request was actually refused', () async {
      // A session ended by a change to this server's own configuration is
      // not a withdrawal by an administrator, and telling somebody it was
      // sends them hunting for a block nobody applied.
      build(allowedGroups: ['developers']);
      var jar = await signIn();
      await store.recordValidation('user-1', groups: ['everyone']);

      var refused = await fetch('/auth/api/account', cookies: jar);
      expect(refused.statusCode, HttpStatus.forbidden);
      var body =
          json.decode(await refused.readAsString()) as Map<String, dynamic>;
      expect(body['denied'], '/auth/denied');

      var page = await browse('/auth/denied'
          '?d=${Uri.encodeQueryComponent(body['deniedDetail'] as String)}');
      expect(await page.readAsString(), contains('not a member of a group'));
    });

    test('but not a reason this server did not write', () async {
      // The page is reached by a navigation, so the reason travels in the
      // query string — where anybody can put one. Unsigned, this server's
      // own denial page would repeat any sentence at all in its own name to
      // somebody who has just been told something is wrong with their
      // access.
      var page = await browse('/auth/denied'
          '?d=${Uri.encodeQueryComponent('Ring 0800 000 000 to be restored')}');

      var body = await page.readAsString();
      expect(body, isNot(contains('0800')));
      expect(body, contains('has been withdrawn'));
    });
  });
}

/// A store whose service-token listing is having a bad day.
class _StoreThatCannotListServiceTokens extends MemoryAuthStore {
  @override
  Future<List<StoredToken>> listServiceTokens({int limit = 200}) async =>
      throw StateError('the database is unreachable');
}

class _StoreThatCannotListSessions extends MemoryAuthStore {
  @override
  Future<List<StoredSession>> listUserSessions(String userId) async =>
      throw StateError('the database is unreachable');
}

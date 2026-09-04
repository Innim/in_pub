import 'dart:convert';
import 'dart:io';

import 'package:in_pub/src/auth/auth_config.dart';
import 'package:in_pub/src/auth/auth_service.dart';
import 'package:in_pub/src/auth/auth_store.dart';
import 'package:in_pub/src/auth/google_credential.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'fake_provider.dart';
import 'memory_auth_store.dart';

/// The pub client's half of the gate. It speaks bearer tokens and nothing
/// else, so these check both that a token opens the door and that a browser
/// session does not.
void main() {
  late MemoryAuthStore store;
  late AuthService auth;
  late FakeIdentityProvider provider;
  late shelf.Handler handler;
  late shelf.Response Function(shelf.Request) inner;

  AuthService? _built;

  void build({
    bool protectPubApi = true,
    bool withLegacy = false,
    bool publicBadges = true,
    List<String> allowedGroups = const [],
  }) {
    // Tests that rebuild mid-body would otherwise leave the instance from
    // setUp unclosed, which only bites once close() has real work to do.
    _built?.close();
    store = MemoryAuthStore();
    auth = AuthService(
      config: AuthConfig(
        enabled: true,
        issuer: 'https://id.example.org',
        clientId: 'in-pub',
        clientSecret: 'client-secret',
        publicUrl: Uri.parse('https://pub.example.org'),
        secret: utf8.encode('a-test-signing-secret-of-sufficient-length!!'),
        protectPubApi: protectPubApi,
        allowedGroups: allowedGroups,
        publicBadges: publicBadges,
        revalidateInterval: const Duration(days: 365),
        revalidateHard: const Duration(days: 365),
      ),
      store: store,
      provider: provider = FakeIdentityProvider(),
      // Off unless a case asks for it, so nothing here can reach out to
      // Google: the real resolver would be built by default. The flag gates
      // the injected resolver too, so it has to follow it rather than being
      // pinned false.
      googleAuth: withLegacy,
      legacyResolver: withLegacy ? _FakeGoogle() : null,
    );
    _built = auth;
    // Replaceable, so a case can serve something other than a plain 200 —
    // the answer to a conditional request, in particular.
    inner = (req) => shelf.Response.ok('package data');
    handler = const shelf.Pipeline()
        .addMiddleware(auth.gate)
        .addHandler((req) async => inner(req));
  }

  setUp(build);
  tearDown(() => _built?.close());

  Future<shelf.Response> pubGet(String path,
      {String? token, String? cookie}) async {
    return await handler(shelf.Request(
        'GET', Uri.parse('https://pub.example.org$path'),
        headers: {
          'user-agent': 'Dart pub 3.11.1',
          if (token != null) HttpHeaders.authorizationHeader: 'Bearer $token',
          if (cookie != null) 'cookie': cookie,
        }));
  }

  Future<String> tokenFor({List<String> groups = const ['developers']}) async {
    await store.upsertUser(
      AuthenticatedUser(
          id: 'user-1',
          email: 'someone@example.org',
          displayName: 'Someone',
          groups: groups),
      validatedAt: DateTime.now(),
    );
    var issued = await auth.tokens
        .issuePersonal(owner: (await store.getUser('user-1'))!, name: 'ci');
    return issued.value;
  }

  const pubRoutes = [
    '/api/packages/my_package',
    '/api/packages/my_package/versions/1.0.0',
    '/packages/my_package/versions/1.0.0.tar.gz',
    '/packages/my_package.json',
  ];

  group('with the pub API left open', () {
    setUp(() => build(protectPubApi: false));

    test('dependency resolution keeps working untouched', () async {
      // Turning the web UI private must not break every consumer at once.
      for (var path in pubRoutes) {
        expect((await pubGet(path)).statusCode, HttpStatus.ok, reason: path);
      }
    });
  });

  group('with the pub API closed', () {
    test('an anonymous client is refused everywhere', () async {
      for (var path in pubRoutes) {
        expect((await pubGet(path)).statusCode, HttpStatus.unauthorized,
            reason: path);
      }
    });

    test('a token opens all of it', () async {
      var token = await tokenFor();
      for (var path in pubRoutes) {
        expect((await pubGet(path, token: token)).statusCode, HttpStatus.ok,
            reason: path);
      }
    });

    test('the refusal tells the user what to run', () async {
      // `dart pub` prints this back, so it is the only instruction that
      // reaches somebody stuck at the prompt.
      var res = await pubGet('/api/packages/my_package');
      var header = res.headers[HttpHeaders.wwwAuthenticateHeader]!;

      expect(header, startsWith('Bearer realm="pub"'));
      expect(header, contains('dart pub token add https://pub.example.org'));
      expect(header, contains('/auth/tokens'));
    });

    test('a bad token is refused with a reason', () async {
      var res = await pubGet('/api/packages/my_package', token: 'inpub_x.y');
      expect(res.statusCode, HttpStatus.unauthorized);
      var body = json.decode(await res.readAsString());
      expect(body['error']['message'], isNotEmpty);
    });

    test('a revoked token stops working', () async {
      var token = await tokenFor();
      await store.revokeToken(store.tokens.keys.single, 'no longer needed');

      var res = await pubGet('/api/packages/my_package', token: token);
      expect(res.statusCode, HttpStatus.unauthorized);
      expect(
          res.headers[HttpHeaders.wwwAuthenticateHeader], contains('revoked'));
    });

    test('a blocked owner takes the token down with them', () async {
      var token = await tokenFor();
      expect((await pubGet(pubRoutes.first, token: token)).statusCode,
          HttpStatus.ok);

      await store.setUserStatus('user-1', UserStatus.blockedLocal,
          reason: 'blocked by an administrator');

      expect((await pubGet(pubRoutes.first, token: token)).statusCode,
          HttpStatus.unauthorized);
    });

    test('a refused read still tells the browser to drop its cookie', () async {
      // The session check may have decided the cookie is a clone or expired,
      // and revoked it server-side. If that instruction does not reach the
      // browser it keeps presenting a dead cookie on every request.
      var user = const AuthenticatedUser(
          id: 'user-1', email: 'someone@example.org', displayName: 'Someone');
      await store.upsertUser(user, validatedAt: DateTime.now());
      var cookie = (await auth.sessions.create(
              shelf.Request('GET', Uri.parse('https://pub.example.org/'),
                  headers: {'user-agent': 'Mozilla/5.0'}),
              user))
          .split(';')
          .first;

      // A different client presenting it trips the clone check.
      var res = await pubGet('/api/packages/my_package', cookie: cookie);
      expect(res.statusCode, HttpStatus.unauthorized);
      expect(res.headersAll[HttpHeaders.setCookieHeader]?.join(' ') ?? '',
          contains('Max-Age=0'));
    });

    test('a signed-in browser can still download an archive', () async {
      // The package page links straight to the tarball. Refusing the session
      // cookie there would hand a signed-in person a JSON error where they
      // asked for a file, with no way to authenticate from a browser.
      var user = const AuthenticatedUser(
          id: 'user-1', email: 'someone@example.org', displayName: 'Someone');
      await store.upsertUser(user, validatedAt: DateTime.now());
      var cookie = (await auth.sessions.create(
              shelf.Request('GET', Uri.parse('https://pub.example.org/'),
                  headers: {'user-agent': 'Mozilla/5.0'}),
              user))
          .split(';')
          .first;

      var res = await handler(shelf.Request(
        'GET',
        Uri.parse(
            'https://pub.example.org/packages/my_package/versions/1.0.0.tar.gz'),
        headers: {'user-agent': 'Mozilla/5.0', 'cookie': cookie},
      ));
      expect(res.statusCode, HttpStatus.ok);
    });

    test('a session still cannot publish or delete', () async {
      // Reads are one thing; a browser attaches cookies to cross-site
      // requests it was tricked into making, so a state change must not be
      // possible without a bearer token.
      var user = const AuthenticatedUser(
          id: 'user-1', email: 'someone@example.org', displayName: 'Someone');
      await store.upsertUser(user, validatedAt: DateTime.now());
      var cookie = (await auth.sessions.create(
              shelf.Request('GET', Uri.parse('https://pub.example.org/'),
                  headers: {'user-agent': 'Mozilla/5.0'}),
              user))
          .split(';')
          .first;

      for (var request in [
        shelf.Request(
            'POST',
            Uri.parse(
                'https://pub.example.org/api/packages/versions/newUpload'),
            headers: {'user-agent': 'Mozilla/5.0', 'cookie': cookie}),
        shelf.Request(
            'DELETE',
            Uri.parse(
                'https://pub.example.org/api/packages/my_package/versions/1.0.0'),
            headers: {'user-agent': 'Mozilla/5.0', 'cookie': cookie}),
      ]) {
        expect((await handler(request)).statusCode, HttpStatus.unauthorized,
            reason: request.method);
      }
    });

    test('the web UI is unaffected by this flag', () async {
      // Still a browser redirect, not a pub-style refusal.
      var res = await handler(shelf.Request(
          'GET', Uri.parse('https://pub.example.org/packages/my_package'),
          headers: {
            'user-agent': 'Mozilla/5.0',
            'sec-fetch-mode': 'navigate',
            'accept': 'text/html',
          }));
      expect(res.statusCode, HttpStatus.found);
      expect(res.headers['location'], startsWith('/auth/login'));
    });

    test('badges do not leak the private names either', () async {
      // A badge answers 404 for a package that does not exist and redirects
      // with the latest version for one that does — the same oracle the
      // route gate closes, reached by a different door.
      build(protectPubApi: true, publicBadges: false);
      expect((await pubGet('/badge/v/my_package')).statusCode,
          HttpStatus.unauthorized);
      // The logo stays open: it says nothing about what is hosted.
      expect((await pubGet('/logo')).statusCode, HttpStatus.ok);
    });

    test('a browser is sent to sign in, not handed JSON', () async {
      // Somebody clicking the archive link on a package page after their
      // session lapsed is owed the sign-in flow, not the pub client's error
      // shape rendered as a page.
      var res = await handler(shelf.Request(
        'GET',
        Uri.parse(
            'https://pub.example.org/packages/my_package/versions/1.0.0.tar.gz'),
        headers: {
          'user-agent': 'Mozilla/5.0',
          'sec-fetch-mode': 'navigate',
          'accept': 'text/html',
        },
      ));
      expect(res.statusCode, HttpStatus.found);
      expect(res.headers['location'], startsWith('/auth/login'));
    });

    test('answers are marked private so no cache may share them', () async {
      // This mode requires TLS in front, so a proxy or CDN is on the path by
      // construction; without these it may key a private package's archive
      // on the url alone and hand it to the next anonymous caller.
      var token = await tokenFor();
      for (var path in pubRoutes) {
        var res = await pubGet(path, token: token);
        expect(res.headers[HttpHeaders.cacheControlHeader], 'private, no-store',
            reason: path);
        expect(res.headers['vary'], contains('Authorization'), reason: path);
      }
    });

    test('the web data endpoints are marked private too', () async {
      // Same intermediary, same exposure: a private package's readme is no
      // less private than its archive.
      var user = const AuthenticatedUser(
          id: 'user-1', email: 'someone@example.org', displayName: 'Someone');
      await store.upsertUser(user, validatedAt: DateTime.now());
      var cookie = (await auth.sessions.create(
              shelf.Request('GET', Uri.parse('https://pub.example.org/'),
                  headers: {'user-agent': 'Mozilla/5.0'}),
              user))
          .split(';')
          .first;

      Future<shelf.Response> get(String path) async => handler(shelf.Request(
            'GET',
            Uri.parse('https://pub.example.org$path'),
            headers: {'user-agent': 'Mozilla/5.0', 'cookie': cookie},
          ));

      expect(
          (await get('/webapi/packages'))
              .headers[HttpHeaders.cacheControlHeader],
          'private, no-store');

      // Generated documentation is hundreds of static files per package, and
      // `no-store` there makes the browser re-fetch the stylesheet, the
      // scripts and the search index on every click. `no-cache` lets it keep
      // the bytes and skip the download while still asking first — and that
      // question comes back through this gate, which a lifetime did not: a
      // private package's docs stayed readable from the browser's own cache
      // for five minutes after signing out.
      //
      // With an entity tag, because that is what `App._serveDocFile` sends
      // and what makes the marking mean anything. This case used to stand a
      // bare 200 in for a doc file, which is not what one looks like — and
      // in doing so asserted the very hole below as behaviour.
      inner = (_) => shelf.Response.ok('doc page', headers: {
            HttpHeaders.etagHeader: '"abc-1"',
          });
      expect(
          (await get('/documentation/foo/1.0.0/'))
              .headers[HttpHeaders.cacheControlHeader],
          'private, no-cache');

      // And the answer to the revalidation that marking asks for. Stamped
      // `no-store` instead, it would tell the browser to throw away the copy
      // it has just confirmed, and every conditional request would become a
      // full download of the same bytes — which is what `no-cache` without a
      // validator amounted to.
      inner = (_) => shelf.Response.notModified(
          headers: {HttpHeaders.etagHeader: '"abc-1"'});
      expect(
          (await get('/documentation/foo/1.0.0/'))
              .headers[HttpHeaders.cacheControlHeader],
          'private, no-cache');
    });

    test('but the "generating…" page under that path is not held at all',
        () async {
      // `/documentation/` also answers with the progress page, a redirect to
      // the upstream server, and 404s for assets that do not exist yet. All
      // three stop being true within seconds, and the comment on the filter
      // has always said so — while the filter itself asked only for a 200,
      // which the progress page is. Keeping one showed a finished doc set as
      // still generating.
      //
      // Decided by the validator rather than the status: `no-cache` is a
      // promise to revalidate, and an answer the server cannot say
      // "unchanged" about has nothing to revalidate against.
      var user = const AuthenticatedUser(
          id: 'user-1', email: 'someone@example.org', displayName: 'Someone');
      await store.upsertUser(user, validatedAt: DateTime.now());
      var cookie = (await auth.sessions.create(
              shelf.Request('GET', Uri.parse('https://pub.example.org/'),
                  headers: {'user-agent': 'Mozilla/5.0'}),
              user))
          .split(';')
          .first;

      inner = (_) => shelf.Response.ok('<html>generating…</html>',
          headers: {HttpHeaders.contentTypeHeader: 'text/html'});
      var res = await handler(shelf.Request(
        'GET',
        Uri.parse('https://pub.example.org/documentation/foo/1.0.0/'),
        headers: {'user-agent': 'Mozilla/5.0', 'cookie': cookie},
      ));

      expect(res.headers[HttpHeaders.cacheControlHeader], 'private, no-store');
    });

    test('a closed badge is refused without a credential', () async {
      build(protectPubApi: true, publicBadges: false);
      var res = await pubGet('/badge/v/foo');
      expect(res.statusCode, HttpStatus.unauthorized);
    });

    test('and stays closed with the pub API left open', () async {
      // `--no-auth-public-badges` on its own. Classifying a closed badge as
      // part of the pub surface made it inherit that surface's "open unless
      // --auth-protect-pub-api" rule, so the flag became a silent no-op that
      // served exactly what the operator had asked to hide.
      build(protectPubApi: false, publicBadges: false);

      var res = await pubGet('/badge/v/foo');
      expect(res.statusCode, isNot(HttpStatus.ok),
          reason: 'the operator asked for badges to require signing in');
    });

    test('a closed badge opens to a token', () async {
      build(protectPubApi: true, publicBadges: false);
      // The README frames a token as what opens the closed surface, and a
      // badge is part of it: an internal README renderer or a CI job that
      // has run `dart pub token add` would otherwise show a broken image
      // with no way to authenticate for it.
      var token = await tokenFor();
      var res = await pubGet('/badge/v/foo', token: token);
      expect(res.statusCode, isNot(HttpStatus.unauthorized));
    });

    test('a browser sent to sign in from a pub url may not be cached',
        () async {
      // Reachable for `/packages/**.tar.gz` and `/api/**`, where an
      // intermediary keying on the url alone would otherwise store a
      // redirect-to-login against a tarball address and hand it to the next
      // pub client, token and all.
      var res = await handler(shelf.Request(
        'GET',
        Uri.parse('https://pub.example.org/packages/foo/versions/1.0.0.tar.gz'),
        headers: {'user-agent': 'Mozilla/5.0', 'accept': 'text/html'},
      ));
      expect(res.statusCode, HttpStatus.found);
      expect(res.headers[HttpHeaders.cacheControlHeader], 'no-store');
    });

    test('a package named `versions` is metadata, not a publish step',
        () async {
      // `versions` is a legal package name, and matching the shared path
      // prefix made reads of it look like publishing — which would open them
      // to the credential that must never open a read.
      build(protectPubApi: true, withLegacy: true);
      expect(
          (await pubGet('/api/packages/versions/1.0.0', token: 'legacy-ok'))
              .statusCode,
          HttpStatus.unauthorized);
    });

    test('private package names cannot be probed without a token', () async {
      // A package hosted here answers differently from one that is not, so
      // an open endpoint would let anyone enumerate the private names by
      // comparing responses. The gate runs before the router, so there is
      // nothing to compare.
      var missing = await pubGet('/api/packages/definitely_not_here');
      var present = await pubGet('/api/packages/my_package');
      expect(missing.statusCode, present.statusCode);
      expect(await missing.readAsString(), await present.readAsString());
    });
  });

  group('the original Google credential', () {
    setUp(() => build(withLegacy: true));

    test('cannot read private packages', () async {
      // It proves only that somebody holds a Google account: no group, and
      // until they sign in here it maps to nobody this server knows. Letting
      // it open reads would mean anyone could mint one and take every
      // private package, which is what this mode exists to prevent.
      for (var path in pubRoutes) {
        expect((await pubGet(path, token: 'legacy-ok')).statusCode,
            HttpStatus.unauthorized,
            reason: path);
      }
    });

    /// Someone who has signed in here at least once, which the credential
    /// now has to answer to.
    /// [withRefreshToken] decides whether the provider can be consulted about
    /// this account at all. Without one, a revalidation has nothing to ask
    /// with and never reaches the provider — which is how an earlier version
    /// of the revocation test below passed without exercising a revocation.
    Future<void> seedLegacyUser(
            {List<String> groups = const [], bool withRefreshToken = false}) =>
        store.upsertUser(
            AuthenticatedUser(
                id: 'user-legacy',
                email: 'old@example.org',
                displayName: 'Old',
                groups: groups),
            refreshTokenEnc:
                withRefreshToken ? auth.crypto.encrypt('refresh-1') : null,
            validatedAt: DateTime.now());

    test('is admitted by the gate when it answers to no account here',
        () async {
      // Every publisher from before authentication existed is in exactly
      // this position, and turning `--auth` on is documented as leaving
      // publishing alone. What such a credential may do is bounded further
      // in — an existing package by its uploader list, a new one by
      // `App.upload`, which refuses to let a provisional caller create it.
      // Refusing at the gate stranded all of them on upgrade.
      var res = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/api/packages/versions/newUpload'),
        headers: {
          'user-agent': 'Dart pub 3.11.1',
          HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
        },
      ));
      expect(res.statusCode, HttpStatus.ok);
    });

    test('is marked provisional when it answers to no account here', () async {
      // The flag is what `App.upload` reads to refuse a brand-new package.
      var result = await auth.resolveBearer('legacy-ok', allowLegacy: true);
      expect(result.isAccepted, isTrue);
      expect(result.provisional, isTrue);
    });

    test('is not provisional once its owner has an account', () async {
      await seedLegacyUser();
      var result = await auth.resolveBearer('legacy-ok', allowLegacy: true);
      expect(result.isAccepted, isTrue);
      expect(result.provisional, isFalse);
    });

    test('still authorises the whole publish handshake', () async {
      await seedLegacyUser();
      // `dart pub publish` asks for an upload url with a GET, POSTs the
      // archive, then finishes with another GET. Judging by method alone
      // refused the two GETs and broke the flow at its first step, while
      // every test passed because only the POST was covered.
      for (var request in [
        shelf.Request('GET',
            Uri.parse('https://pub.example.org/api/packages/versions/new'),
            headers: {
              'user-agent': 'Dart pub 3.11.1',
              HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
            }),
        shelf.Request(
            'POST',
            Uri.parse(
                'https://pub.example.org/api/packages/versions/newUpload'),
            headers: {
              'user-agent': 'Dart pub 3.11.1',
              HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
            }),
        shelf.Request(
            'GET',
            Uri.parse(
                'https://pub.example.org/api/packages/versions/newUploadFinish'),
            headers: {
              'user-agent': 'Dart pub 3.11.1',
              HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
            }),
      ]) {
        expect((await handler(request)).statusCode, HttpStatus.ok,
            reason: '${request.method} ${request.requestedUri.path}');
      }
    });

    test('does not authorise deleting a version or adding an uploader',
        () async {
      // Both change published state and neither is part of the handshake.
      // Treating "any method that is not GET" as publishing handed this
      // credential `DELETE .../versions/1.0.0` and `POST .../uploaders`,
      // which destroy more than the read this mode is careful to refuse.
      await seedLegacyUser();

      for (var req in [
        shelf.Request(
            'DELETE',
            Uri.parse(
                'https://pub.example.org/api/packages/foo/versions/1.0.0'),
            headers: {
              'user-agent': 'Dart pub 3.11.1',
              HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
            }),
        shelf.Request('POST',
            Uri.parse('https://pub.example.org/api/packages/foo/uploaders'),
            headers: {
              'user-agent': 'Dart pub 3.11.1',
              HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
            }),
      ]) {
        expect((await handler(req)).statusCode, HttpStatus.unauthorized,
            reason: '${req.method} ${req.requestedUri.path}');
      }
    });

    test('is refused once the provider stops vouching for its owner', () async {
      // The sweep only walks accounts with live browser sessions, so a
      // publisher who works entirely from the command line was never
      // re-checked and their Google credential went on publishing after
      // being disabled upstream. A token in the same position is refused on
      // its next use, and the comment claimed this was held to the same bar.
      await seedLegacyUser(withRefreshToken: true);
      await store.recordValidation('user-legacy',
          validatedAt: DateTime.fromMillisecondsSinceEpoch(0));
      provider.refreshError =
          IdentityRevokedException('the account is disabled');

      var res = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/api/packages/versions/newUpload'),
        headers: {
          'user-agent': 'Dart pub 3.11.1',
          HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
        },
      ));

      expect(res.statusCode, HttpStatus.unauthorized);
    });

    test('is not refused merely because the account cannot be re-checked',
        () async {
      // No refresh token to ask with — which is every account after the
      // signing secret is lost or rotated, an operator's mistake the startup
      // warning covers. Refusing on it stopped every CI job in the
      // deployment; a real revocation still refuses, as the test above shows.
      await seedLegacyUser();
      await store.recordValidation('user-legacy',
          validatedAt: DateTime.fromMillisecondsSinceEpoch(0));

      var res = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/api/packages/versions/newUpload'),
        headers: {
          'user-agent': 'Dart pub 3.11.1',
          HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
        },
      ));

      expect(res.statusCode, HttpStatus.ok);
      expect(store.users['user-legacy']!.status, UserStatus.active,
          reason: 'a credential check must not mark somebody else\'s account');
    });

    test('is refused for someone outside an allowed group', () async {
      // The same condition a session and a token are held to: being active
      // upstream is not the same as being entitled here.
      build(withLegacy: true, allowedGroups: ['developers']);
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-8',
              email: 'old@example.org',
              displayName: 'Old',
              groups: ['everyone']),
          validatedAt: DateTime.now());

      var res = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/api/packages/versions/newUpload'),
        headers: {
          'user-agent': 'Dart pub 3.11.1',
          HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
        },
      ));
      expect(res.statusCode, HttpStatus.unauthorized);
    });

    test('a difference of case does not slip past the block', () async {
      // The provider may report `Alice@Example.org` where Google reports it
      // in lower case; comparing them literally would let the blocked
      // account publish.
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-7', email: 'Old@Example.org', displayName: 'Old'),
          validatedAt: DateTime.now());
      await store.setUserStatus('user-7', UserStatus.blockedLocal,
          reason: 'blocked by an administrator');

      var res = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/api/packages/versions/newUpload'),
        headers: {
          'user-agent': 'Dart pub 3.11.1',
          HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
        },
      ));
      expect(res.statusCode, HttpStatus.unauthorized);
    });

    test('a blocked duplicate of the address is enough to refuse', () async {
      // An address is not unique here — a provider migration leaves two
      // identities behind one. Picking whichever the index reached first
      // would let the blocked one keep publishing under the other.
      for (var user in [
        const AuthenticatedUser(
            id: 'user-old', email: 'old@example.org', displayName: 'Old'),
        const AuthenticatedUser(
            id: 'user-new', email: 'old@example.org', displayName: 'Old again'),
      ]) {
        await store.upsertUser(user, validatedAt: DateTime.now());
      }
      await store.setUserStatus('user-old', UserStatus.blockedLocal,
          reason: 'blocked by an administrator');

      var res = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/api/packages/versions/newUpload'),
        headers: {
          'user-agent': 'Dart pub 3.11.1',
          HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
        },
      ));
      expect(res.statusCode, HttpStatus.unauthorized);
    });

    test('is refused for someone blocked here', () async {
      // It carries an address and nothing about their standing, so the
      // address is looked up: blocking somebody has to stop them publishing
      // as well as browsing.
      await store.upsertUser(
          const AuthenticatedUser(
              id: 'user-9', email: 'old@example.org', displayName: 'Old'),
          validatedAt: DateTime.now());
      await store.setUserStatus('user-9', UserStatus.blockedLocal,
          reason: 'blocked by an administrator');

      var res = await handler(shelf.Request(
        'POST',
        Uri.parse('https://pub.example.org/api/packages/versions/newUpload'),
        headers: {
          'user-agent': 'Dart pub 3.11.1',
          HttpHeaders.authorizationHeader: 'Bearer legacy-ok',
        },
      ));
      expect(res.statusCode, HttpStatus.unauthorized);
    });

    test('is not consulted for a token of ours that was refused', () async {
      // Our own malformed token is a final answer; falling through could
      // only produce a more confusing error.
      var res = await pubGet(pubRoutes.first, token: 'inpub_x.y');
      expect(res.statusCode, HttpStatus.unauthorized);
    });

    test('an unrecognised credential is refused', () async {
      expect((await pubGet(pubRoutes.first, token: 'nonsense')).statusCode,
          HttpStatus.unauthorized);
    });
  });
}

/// Stands in for the original Google credential.
class _FakeGoogle extends GoogleCredentialResolver {
  @override
  Future<String?> resolve(String token) async =>
      token == 'legacy-ok' ? 'old@example.org' : null;
}

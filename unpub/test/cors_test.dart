import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:in_pub/in_pub.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'auth/fake_provider.dart';
import 'auth/memory_auth_store.dart';

/// Who may read this server's JSON from another origin, checked on the header
/// that actually leaves the socket.
///
/// It has to be the emitted header rather than the arguments handed to
/// `corsHeaders`: the whole policy lives in a dependency, and the version
/// that shipped with this package for most of its life ignored the
/// `Access-Control-Allow-Origin` it was given and reflected the caller's own
/// back instead — with credentials allowed. Nothing in this repository said
/// so, and no test would have noticed.
void main() {
  late HttpServer server;
  HttpServer? _started;
  MemoryAuthStore? store;
  AuthService? authService;

  /// Serves an app on a loopback port. [config] null means `--auth` off.
  Future<void> serve({AuthConfig? config}) async {
    await _started?.close(force: true);
    authService = config == null
        ? null
        : AuthService(
            config: config,
            store: store = MemoryAuthStore(),
            provider: FakeIdentityProvider(),
            googleAuth: false,
          );
    server = _started = await App(
      metaStore: _UnusedMetaStore(),
      packageStore: _UnusedPackageStore(),
      auth: authService,
    ).serve('127.0.0.1', 0);
  }

  tearDown(() => _started?.close(force: true));

  AuthConfig authConfig({
    List<String> devOrigins = const [],
    bool insecureCookie = false,
  }) =>
      AuthConfig(
        enabled: true,
        issuer: 'https://id.example.org',
        clientId: 'in-pub',
        clientSecret: 'secret',
        publicUrl: Uri.parse('http://127.0.0.1:4000'),
        secret: utf8.encode('a-test-signing-secret-of-sufficient-length!!'),
        devOrigins: devOrigins,
        insecureCookie: insecureCookie,
      );

  Future<http.Response> from(String origin, {String method = 'GET'}) async {
    var uri = Uri.parse('http://127.0.0.1:${server.port}/webapi/packages');
    var request = http.Request(method, uri)..headers['origin'] = origin;
    return http.Response.fromStream(await request.send());
  }

  group('with authentication off', () {
    setUp(() => serve());

    test('answers with a wildcard and refuses credentials', () async {
      // Not the caller's origin reflected back with
      // `Access-Control-Allow-Credentials: true`, which is what the
      // dependency does when left to itself: that lets any page read package
      // data from a visitor's browser with their cookies attached, which is
      // a real exposure where the repository sits behind an SSO proxy. `*`
      // is the one value a browser refuses to combine with credentials.
      var res = await from('https://evil.example');

      expect(res.headers['access-control-allow-origin'], '*');
      expect(res.headers['access-control-allow-credentials'], 'false');
    });

    test('and says the same on the preflight', () async {
      var res = await from('https://evil.example', method: 'OPTIONS');

      expect(res.headers['access-control-allow-origin'], '*');
      expect(res.headers['access-control-allow-credentials'], 'false');
    });
  });

  group('with authentication on', () {
    test('the public url may read, and nobody else', () async {
      await serve(config: authConfig());

      expect(
          (await from('http://127.0.0.1:4000'))
              .headers['access-control-allow-origin'],
          'http://127.0.0.1:4000');
      // No header at all, which is how the middleware refuses: the browser
      // then blocks the read on the caller's side.
      expect(
          (await from('https://evil.example'))
              .headers['access-control-allow-origin'],
          isNull);
    });

    test('a stated development origin may read', () async {
      await serve(config: authConfig(devOrigins: ['http://localhost:8080']));

      expect(
          (await from('http://localhost:8080'))
              .headers['access-control-allow-origin'],
          'http://localhost:8080');
      expect(
          (await from('http://localhost:9999'))
              .headers['access-control-allow-origin'],
          isNull,
          reason: 'an allow-list that admits a neighbouring port is not one');
    });

    test('and a cookie flag does not state one', () async {
      // `--auth-insecure-cookie` is documented as dropping `Secure` so the
      // flow works over plain http, and an operator whose TLS terminates at
      // a reverse proxy sets it for exactly that. Reading a CORS policy off
      // it let any page on any localhost port read `/auth/api/account` with
      // the visitor's cookies — credentials stay allowed and `x-csrf-token`
      // is an allowed request header — lift the anti-forgery token out of
      // the answer and drive `/auth/api/admin/action` with it.
      await serve(config: authConfig(insecureCookie: true));

      expect(
          (await from('http://localhost:8080'))
              .headers['access-control-allow-origin'],
          isNull);
      expect(
          (await from('http://127.0.0.1:31337'))
              .headers['access-control-allow-origin'],
          isNull);
    });

    group('every answer says it depends on the origin', () {
      // The header that leaves is the caller's own origin, so an
      // intermediary keyed on the url alone would store one caller's
      // `Access-Control-Allow-Origin` and hand it to the next. The
      // dependency writes `Vary` only when it is handed a fixed value to
      // send, which this branch does not hand it — it supplies the allowed
      // request headers and nothing else.
      setUp(() => serve(config: authConfig()));

      /// A signed-in browser, since most of what is worth checking here is
      /// only reachable with one.
      Future<String> signIn() async {
        var user = const AuthenticatedUser(
            id: 'user-1', email: 'someone@example.org', displayName: 'Someone');
        await store!.upsertUser(user, validatedAt: DateTime.now());
        return (await authService!.sessions.create(
                shelf.Request('GET', Uri.parse('http://127.0.0.1:4000/'),
                    headers: {'user-agent': 'Mozilla/5.0'}),
                user))
            .split(';')
            .first;
      }

      /// [path] as a browser on the public origin would ask for it.
      ///
      /// Redirects are deliberately not followed: `/api/packages/<name>`
      /// answers one for a package hosted upstream, and letting the client
      /// chase it would have this asserting on headers pub.dev sent.
      Future<http.Response> get(String path,
          {String method = 'GET', String? cookie}) async {
        var request = http.Request(
            method, Uri.parse('http://127.0.0.1:${server.port}$path'))
          ..followRedirects = false
          ..headers['origin'] = 'http://127.0.0.1:4000'
          ..headers['user-agent'] = 'Mozilla/5.0';
        if (cookie != null) request.headers['cookie'] = cookie;
        return http.Response.fromStream(await request.send());
      }

      Set<String> varyOf(http.Response res) => (res.headers['vary'] ?? '')
          .split(',')
          .map((f) => f.trim().toLowerCase())
          .where((f) => f.isNotEmpty)
          .toSet();

      test('including the ones the gate never stamps', () async {
        var cookie = await signIn();
        // `--auth-protect-pub-api` is off here, as it is by default, so the
        // gate hands the metadata route straight to the router: it left with
        // a reflected origin, `Access-Control-Allow-Credentials: true`, no
        // `Cache-Control` and nothing saying the answer was for one caller.
        // The shell and its bundle go out `no-cache` with an entity tag,
        // which is an invitation to a CDN to hold them.
        for (var path in const [
          '/api/packages/some_package',
          '/',
          '/main.dart.js'
        ]) {
          expect(varyOf(await get(path, cookie: cookie)), contains('origin'),
              reason: path);
        }
      });

      test('and so does the preflight', () async {
        // Answered by the CORS middleware itself, which never reaches the
        // handler, so it is the one answer nothing else could have stamped.
        expect(varyOf(await get('/webapi/packages', method: 'OPTIONS')),
            contains('origin'));
      });

      test('without displacing what the gate already listed', () async {
        // The gate names `Authorization` and `Cookie` besides, and losing
        // those would tell a shared cache it may serve one caller's private
        // metadata to the next — a worse outcome than the one this header
        // was added for.
        var res = await get('/webapi/packages', cookie: await signIn());

        expect(res.statusCode, HttpStatus.ok);
        expect(varyOf(res), containsAll(['origin', 'authorization', 'cookie']));
      });
    });
  });

  group('a stated development origin', () {
    test('is refused at startup when it is not an origin', () {
      // An entry the CORS check would silently ignore is worse than one that
      // stops the server: the operator believes a tool has been let in and
      // spends the afternoon on the browser's console instead.
      for (var bad in const [
        'localhost:8080',
        'ftp://localhost',
        'http://',
        'http://localhost:8080/app',
        'http://localhost:8080?x=1',
        // `Uri` carries these without complaint and hands them back from
        // `origin` verbatim, so the entry looks like an allow-list entry and
        // matches nothing a browser can send.
        'http://localhost:99999',
        'http://localhost:-1',
        'http://someone@localhost:8080',
      ]) {
        expect(
            authConfig(devOrigins: [bad]).validate(),
            contains(predicate<String>((e) => e.contains('is not an origin'),
                'complains about "$bad"')),
            reason: bad);
      }
    });

    test('and accepted when it is', () {
      expect(
          authConfig(devOrigins: ['http://localhost:8080', 'https://ui.test'])
              .validate(),
          isEmpty);
    });
  });
}

class _UnusedMetaStore extends MetaStore {
  Never _unused() => throw UnimplementedError('not used by these tests');

  @override
  Future<UnpubPackage?> queryPackage(String name) async => null;
  @override
  Future<void> addVersion(String name, UnpubVersion version) => _unused();
  @override
  Future<void> addUploader(String name, String email) => _unused();
  @override
  Future<void> removeUploader(String name, String email) => _unused();
  @override
  Future<void> removeVersion(String name, String version) => _unused();
  @override
  void increaseDownloads(String name, String version) => _unused();
  @override
  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
  }) async =>
      UnpubQueryResult(0, const []);
}

class _UnusedPackageStore extends PackageStore {
  Never _unused() => throw UnimplementedError('not used by these tests');

  @override
  Stream<List<int>> download(String name, String version) => _unused();
  @override
  Future<void> upload(String name, String version, List<int> content) =>
      _unused();
  @override
  Future<void> delete(String name, String version) => _unused();
}

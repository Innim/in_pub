import 'dart:convert';
import 'dart:io';

import 'package:in_pub/in_pub.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'auth/fake_provider.dart';
import 'auth/memory_auth_store.dart';

/// The web UI is served from urls that carry no version — `/main.dart.js` is
/// the same address for every release. Without revalidation a browser keeps
/// the bundle it downloaded before an upgrade, which is indistinguishable
/// from the new build simply not working.
void main() {
  late App app;

  setUp(() {
    app = App(
      metaStore: _UnusedMetaStore(),
      packageStore: _UnusedPackageStore(),
      version: '1.2.3',
    );
  });

  Future<shelf.Response> get(String path, {String? ifNoneMatch}) =>
      app.router.call(shelf.Request(
        'GET',
        Uri.parse('http://localhost:4000$path'),
        headers: {
          if (ifNoneMatch != null) HttpHeaders.ifNoneMatchHeader: ifNoneMatch,
        },
      ));

  for (var path in const ['/', '/main.dart.js']) {
    group(path, () {
      test('must be revalidated rather than cached blindly', () async {
        var res = await get(path);
        expect(res.statusCode, HttpStatus.ok);
        expect(res.headers[HttpHeaders.cacheControlHeader], 'no-cache');
        expect(res.headers[HttpHeaders.etagHeader], isNotNull);
      });

      test('answers 304 when the browser already has it', () async {
        var first = await get(path);
        var etag = first.headers[HttpHeaders.etagHeader]!;

        var second = await get(path, ifNoneMatch: etag);
        expect(second.statusCode, HttpStatus.notModified);
        expect(second.headers[HttpHeaders.etagHeader], etag);
      });

      test('sends the body when the browser has a stale copy', () async {
        var res = await get(path, ifNoneMatch: '"something-else"');
        expect(res.statusCode, HttpStatus.ok);
        expect(await res.readAsString(), isNotEmpty);
      });

      test('answers 304 for the header forms a real client actually sends',
          () async {
        // `If-None-Match` is not one opaque string: RFC 9110 lets it carry
        // `*`, a comma-separated list, and weak tags — and clients use all
        // three. A proxy in front of this server may weaken a tag on the way
        // through, and a browser holding an earlier and a current copy sends
        // both. Compared with `==`, none of those ever matched, so every
        // revalidation of the whole bundle was answered with the whole
        // bundle. The documentation route beside this one already got it
        // right; they now share the comparison.
        var etag = (await get(path)).headers[HttpHeaders.etagHeader]!;

        for (var header in [
          etag,
          'W/$etag',
          '*',
          '"something-else", $etag',
          '$etag , "something-else"',
        ]) {
          expect((await get(path, ifNoneMatch: header)).statusCode,
              HttpStatus.notModified,
              reason: 'If-None-Match: $header names the tag we hold');
        }

        expect((await get(path, ifNoneMatch: '"a", "b"')).statusCode,
            HttpStatus.ok);
      });

      test('the tag is stable across requests', () async {
        // A tag that changed per request would defeat the point: every load
        // would download the whole bundle again.
        var first = await get(path);
        var second = await get(path);
        expect(second.headers[HttpHeaders.etagHeader],
            first.headers[HttpHeaders.etagHeader]);
      });
    });
  }

  test('the two assets do not share a tag', () async {
    var index = await get('/');
    var bundle = await get('/main.dart.js');
    expect(index.headers[HttpHeaders.etagHeader],
        isNot(bundle.headers[HttpHeaders.etagHeader]));
  });

  group('the web UI shell', () {
    // Every client-side route has to be served the shell, or opening one
    // directly — a pasted link, a reload, a redirect from elsewhere on the
    // server — reaches the router instead of the application and comes back
    // "not found". Kept in step with unpub_web/lib/src/routes.dart by hand,
    // which is what this test is for.
    const clientRoutes = [
      '/',
      '/packages',
      '/packages/my_package',
      '/packages/my_package/versions/1.0.0',
    ];

    /// A server with authentication on, which is what makes these routes
    /// mean anything.
    App withAuth() => App(
          metaStore: _UnusedMetaStore(),
          packageStore: _UnusedPackageStore(),
          auth: AuthService(
            config: AuthConfig(
              enabled: true,
              issuer: 'https://id.example.org',
              clientId: 'in-pub',
              clientSecret: 'secret',
              publicUrl: Uri.parse('https://pub.example.org'),
              secret: utf8.encode('a-test-signing-secret-long-enough-here!!'),
            ),
            store: MemoryAuthStore(),
            provider: FakeIdentityProvider(),
            googleAuth: false,
          ),
        );

    // `authOnlyRoutes` comes from the server, so this cannot drift from the
    // set it actually applies.

    for (var path in clientRoutes) {
      test('is served at $path', () async {
        var res = await get(path);
        expect(res.statusCode, HttpStatus.ok,
            reason: 'opening $path directly must load the application');
        expect(await res.readAsString(), contains('<my-app>'));
      });
    }

    for (var path in authOnlyRoutes) {
      test('is served at $path once authentication is on', () async {
        var res = await withAuth().router.call(
            shelf.Request('GET', Uri.parse('http://localhost:4000$path')));
        expect(res.statusCode, HttpStatus.ok);
        expect(await res.readAsString(), contains('<my-app>'));
      });

      test('is not served at $path without it', () async {
        // The screen's very first request would go to an endpoint that is
        // not routed, and a page reporting that is worse than a plain 404.
        expect((await get(path)).statusCode, HttpStatus.notFound);
      });
    }

    test('an unknown path is still not found', () async {
      // The list is explicit rather than a catch-all so that a genuinely
      // wrong url says so instead of silently loading the app.
      expect((await get('/no-such-page')).statusCode, HttpStatus.notFound);
    });

    test('the account tab survives in the query string', () async {
      var res = await withAuth().router.call(shelf.Request(
          'GET', Uri.parse('http://localhost:4000/account?tab=sessions')));
      expect(res.statusCode, HttpStatus.ok);
    });
  });

  group('generated documentation', () {
    // The gate marks these `private, no-cache`, which is a promise to
    // revalidate rather than a refusal to store — but a revalidation the
    // server cannot answer with "unchanged" can only be answered with the
    // whole file again, which made the marking identical to `no-store`: a
    // doc set is hundreds of files, and every click through it re-downloaded
    // the stylesheet, the scripts and the search index.
    late Directory cache;
    late App withDocs;

    setUp(() async {
      cache = await Directory.systemTemp.createTemp('in_pub_doc_test');
      var dir = Directory(p.join(cache.path, 'foo', '1.0.0'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'index.html'))
          .writeAsStringSync('<html>the docs</html>');
      withDocs = App(
        metaStore: _UnusedMetaStore(),
        packageStore: _UnusedPackageStore(),
        docStore: DocStore(cache.path),
      );
    });

    tearDown(() => cache.delete(recursive: true));

    Future<shelf.Response> doc(
            {String? ifNoneMatch, String? ifModifiedSince}) =>
        withDocs.router.call(shelf.Request(
          'GET',
          Uri.parse('http://localhost:4000/documentation/foo/1.0.0/'),
          headers: {
            if (ifNoneMatch != null) HttpHeaders.ifNoneMatchHeader: ifNoneMatch,
            if (ifModifiedSince != null)
              HttpHeaders.ifModifiedSinceHeader: ifModifiedSince,
          },
        ));

    test('is served with something to revalidate against', () async {
      var res = await doc();
      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers[HttpHeaders.etagHeader], isNotNull);
      expect(res.headers[HttpHeaders.lastModifiedHeader], isNotNull);
    });

    test('answers 304 when the browser already has the file', () async {
      var first = await doc();
      var res = await doc(ifNoneMatch: first.headers[HttpHeaders.etagHeader]!);

      expect(res.statusCode, HttpStatus.notModified);
      expect(await res.readAsString(), isEmpty);
    });

    test('and when it only knows when it last changed', () async {
      // The stored time has to be truncated to the second before it is sent,
      // or the millisecond remainder makes the file compare as newer than
      // the date we ourselves handed out — a full body every time.
      var first = await doc();
      var res = await doc(
          ifModifiedSince: first.headers[HttpHeaders.lastModifiedHeader]!);

      expect(res.statusCode, HttpStatus.notModified);
    });

    test('a regenerated file is not answered from the browser copy', () async {
      // The tag has to move when the file does, or a rebuild is invisible to
      // every browser that already fetched the old one. Written at the same
      // length on purpose: it is the modification time carrying this, not
      // the size.
      var file = File(p.join(cache.path, 'foo', '1.0.0', 'index.html'));
      var first = await doc();

      file.writeAsStringSync('<html>the DOCS</html>');
      file.setLastModifiedSync(
          file.lastModifiedSync().add(const Duration(seconds: 1)));

      var res = await doc(ifNoneMatch: first.headers[HttpHeaders.etagHeader]!);
      expect(res.statusCode, HttpStatus.ok);
      expect(await res.readAsString(), contains('the DOCS'));
    });

    test('but sends the file when the copy is stale', () async {
      var res = await doc(ifNoneMatch: '"something-else"');
      expect(res.statusCode, HttpStatus.ok);
      expect(await res.readAsString(), contains('the docs'));
    });
  });

  group('the script reference on the page', () {
    // `no-cache` is only a request. Anything in front of this server — a CDN,
    // a tunnel, a corporate proxy — may cache a plain `.js` url on its own
    // terms and serve the previous release for hours. A url that changes with
    // the content cannot go stale.
    test('carries the bundle version', () async {
      var body = await (await get('/')).readAsString();
      expect(body, contains('src="main.dart.js?v='),
          reason: 'if the build stopped emitting `src="main.dart.js"` this '
              'silently reverts to an unversioned url');
      expect(body, isNot(contains('src="main.dart.js"')));
    });

    test('matches the bundle actually served', () async {
      var body = await (await get('/')).readAsString();
      var stamped = RegExp(r'src="main\.dart\.js\?v=([^"]+)"')
          .firstMatch(body)!
          .group(1)!;
      var bundleTag = (await get('/main.dart.js'))
          .headers[HttpHeaders.etagHeader]!
          .replaceAll('"', '');
      expect(stamped, bundleTag);
    });

    test('the versioned url serves the bundle', () async {
      var res = await get('/main.dart.js?v=whatever');
      expect(res.statusCode, HttpStatus.ok);
      expect(await res.readAsString(), isNotEmpty);
    });
  });
}

class _UnusedMetaStore extends MetaStore {
  Never _unused() => throw UnimplementedError('not used by these tests');

  @override
  Future<UnpubPackage?> queryPackage(String name) => _unused();
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
  }) =>
      _unused();
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

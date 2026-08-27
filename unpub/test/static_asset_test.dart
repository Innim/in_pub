import 'dart:io';

import 'package:in_pub/in_pub.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

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

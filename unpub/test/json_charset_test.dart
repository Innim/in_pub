import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:in_pub/in_pub.dart';
import 'package:test/test.dart';

/// The web UI fetches with `package:http`, whose `Response.body` falls back
/// to latin1 when the answer does not say how it is encoded — and everything
/// the data endpoints carry is text somebody wrote: a README, a description,
/// an author's name.
///
/// Served over a real socket and read back through the same client the
/// application uses, because neither half of that can be checked on a
/// response object in memory: shelf adds the charset on the way out for a
/// string body, and what a client makes of the bytes is the client's
/// decision.
void main() {
  late HttpServer server;

  setUp(() async {
    server = await App(
      metaStore: _OnePackage(),
      packageStore: _UnusedPackageStore(),
    ).serve('127.0.0.1', 0);
  });

  tearDown(() => server.close(force: true));

  Future<http.Response> get(String path) =>
      http.get(Uri.parse('http://127.0.0.1:${server.port}$path'));

  test('a data endpoint says what its answer is encoded in', () async {
    var res = await get('/webapi/package/package_0/1.0.0');

    expect(res.statusCode, HttpStatus.ok);
    expect(res.headers[HttpHeaders.contentTypeHeader], contains('utf-8'),
        reason: '`ContentType.json.mimeType` drops the charset that '
            '`ContentType.json` itself carries');
  });

  test('so the text arrives as it was written', () async {
    var res = await get('/webapi/package/package_0/1.0.0');

    // `res.body`, not `utf8.decode(res.bodyBytes)`: what is under test is
    // what the client decides the bytes mean.
    var data = (json.decode(res.body) as Map<String, dynamic>)['data']
        as Map<String, dynamic>;
    expect(data['readme'], 'Привет, мир');
    expect(data['description'], 'Пакет с описанием');
  });
}

/// A store holding one package whose text is not ASCII.
class _OnePackage extends MetaStore {
  Never _unused() => throw UnimplementedError('not used by these tests');

  @override
  Future<UnpubPackage?> queryPackage(String name) async {
    if (name != 'package_0') return null;
    var now = DateTime.now();
    return UnpubPackage(
      name,
      [
        UnpubVersion(
          '1.0.0',
          {
            'name': name,
            'version': '1.0.0',
            'description': 'Пакет с описанием'
          },
          null,
          'someone@example.org',
          'Привет, мир',
          null,
          now,
        )
      ],
      true,
      ['someone@example.org'],
      now,
      now,
      0,
    );
  }

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

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:in_pub/in_pub.dart';
import 'package:test/test.dart';

/// `/webapi/recent` answers with publications, not with packages.
///
/// The difference is the whole point of the endpoint: ordering packages by
/// when they were last published to can only ever name one version each —
/// the newest one — which is not necessarily the version that just went up,
/// and cannot say that two releases happened.
void main() {
  late HttpServer server;
  late _Publications store;

  setUp(() async {
    store = _Publications();
    server = await App(
      metaStore: store,
      packageStore: _UnusedPackageStore(),
    ).serve('127.0.0.1', 0);
  });

  tearDown(() => server.close(force: true));

  Future<List<Map<String, dynamic>>> recent([String query = '']) async {
    var res = await http
        .get(Uri.parse('http://127.0.0.1:${server.port}/webapi/recent$query'));
    expect(res.statusCode, HttpStatus.ok);
    var data = (json.decode(res.body) as Map<String, dynamic>)['data']
        as Map<String, dynamic>;
    return (data['publications'] as List).cast<Map<String, dynamic>>();
  }

  test('one entry per published version, newest first', () async {
    store.publications = [
      _publication('package_a', '2.0.0', DateTime.utc(2026, 9, 8, 10)),
      _publication('package_a', '1.9.1', DateTime.utc(2026, 9, 8, 9)),
      _publication('package_b', '0.1.0', DateTime.utc(2026, 9, 7)),
    ];

    var entries = await recent();

    expect(entries.map((e) => [e['name'], e['version']]), [
      ['package_a', '2.0.0'],
      ['package_a', '1.9.1'],
      ['package_b', '0.1.0'],
    ]);
  });

  test('an entry names the version that was published', () async {
    // The package's newest version is 2.0.0; what went up is a fix on the
    // 1.9 line, and that is what the entry has to say.
    store.publications = [
      _publication('package_a', '1.9.1', DateTime.utc(2026, 9, 8, 9)),
    ];

    var entry = (await recent()).single;

    expect(entry['version'], '1.9.1');
    expect(entry['publishedAt'], DateTime.utc(2026, 9, 8, 9).toIso8601String());
    expect(entry['description'], 'the 1.9.1 description');
  });

  test('size is passed through, and capped', () async {
    store.publications = [];

    await recent('?size=3');
    expect(store.askedFor, 3);

    await recent();
    expect(store.askedFor, 10, reason: 'the default');

    await recent('?size=100000');
    expect(store.askedFor, 100,
        reason: 'aggregating over every version of every package, an '
            'unbounded size asks for work that grows with the repository');

    await recent('?size=0');
    expect(store.askedFor, 1);

    await recent('?size=not-a-number');
    expect(store.askedFor, 10);
  });
}

UnpubRecentPublication _publication(
        String package, String version, DateTime at) =>
    UnpubRecentPublication(
      package,
      UnpubVersion(
        version,
        {
          'name': package,
          'version': version,
          'description': 'the $version description',
        },
        null,
        'someone@example.org',
        null,
        null,
        at,
      ),
    );

/// A store that hands back whatever the test put in it, and remembers what
/// it was asked for.
class _Publications extends MetaStore {
  var publications = <UnpubRecentPublication>[];
  int? askedFor;

  Never _unused() => throw UnimplementedError('not used by these tests');

  @override
  Future<List<UnpubRecentPublication>> queryRecentPublications({
    required int size,
  }) async {
    askedFor = size;
    return publications;
  }

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

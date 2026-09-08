import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:in_pub/in_pub.dart';
import 'package:test/test.dart';

/// What the repository API actually puts on the wire for a version published
/// before this server moved to https.
///
/// The end-to-end proof is in `hosted_url_compat_pub_get_test.dart`, but that
/// one can only run over plain http — pub has to be able to reach the socket
/// — so the https case, which is the deployment this exists for, is checked
/// here. `--proxy-origin` is what tells the server the address it is reached
/// on when TLS is terminated in front of it, and it is the same setting the
/// archive urls already depend on.
void main() {
  final public = Uri.parse('https://pub.example.org');
  late HttpServer server;

  /// The stored pubspec of `package_a`: published against the old address,
  /// naming every kind of source so the answer can be checked for what it
  /// leaves alone as well as for what it changes.
  final stored = <String, dynamic>{
    'name': 'package_a',
    'version': '1.0.0',
    'dependencies': {
      'package_b': {'hosted': 'http://pub.example.org', 'version': '^1.0.0'},
      'other_lib': {
        'hosted': 'https://some-other-repository.example.com',
        'version': '^2.0.0'
      },
      'local_lib': {'path': '../local_lib'},
      'collection': '^1.15.0',
    },
    'dev_dependencies': {
      'package_lint': {'hosted': 'http://pub.example.org'},
    },
  };

  late _OnePackage meta;

  /// [asked] false leaves the argument off altogether, which is how every
  /// deployment that has not asked for the rewrite is configured; [enabled]
  /// false is an operator who configured it and switched it off.
  Future<void> serve({bool asked = true, bool enabled = true}) async {
    meta = _OnePackage(stored);
    server = await App(
      metaStore: meta,
      packageStore: _UnusedPackageStore(),
      proxy_origin: public,
      hostedUrlCompat: asked ? HostedUrlCompat(enabled: enabled) : null,
    ).serve('127.0.0.1', 0);
  }

  tearDown(() => server.close(force: true));

  Future<Map<String, dynamic>> get(String path) async {
    var res = await http.get(Uri.parse('http://127.0.0.1:${server.port}$path'));
    expect(res.statusCode, HttpStatus.ok);
    return json.decode(res.body) as Map<String, dynamic>;
  }

  test('the version list serves the old dependency under the new address',
      () async {
    await serve();

    var body = await get('/api/packages/package_a');
    var pubspec = (body['versions'] as List).single['pubspec'] as Map;
    var deps = pubspec['dependencies'] as Map;

    expect(deps['package_b'],
        {'hosted': 'https://pub.example.org', 'version': '^1.0.0'});
    expect(deps['other_lib']['hosted'],
        'https://some-other-repository.example.com',
        reason: 'another repository is not ours to move');
    expect(deps['local_lib'], {'path': '../local_lib'});
    expect(deps['collection'], '^1.15.0');
    expect(pubspec['dev_dependencies']['package_lint']['hosted'],
        'https://pub.example.org');
  });

  test('so does `latest`, and the single-version endpoint', () async {
    await serve();

    var list = await get('/api/packages/package_a');
    expect(list['latest']['pubspec']['dependencies']['package_b']['hosted'],
        'https://pub.example.org');

    var one = await get('/api/packages/package_a/versions/1.0.0');
    expect(one['pubspec']['dependencies']['package_b']['hosted'],
        'https://pub.example.org');
  });

  test('the stored metadata is not written back', () async {
    await serve();
    await get('/api/packages/package_a');

    expect(meta.stored['dependencies']['package_b']['hosted'],
        'http://pub.example.org',
        reason: 'the layer answers requests; it does not migrate data');
  });

  test('the web UI links the dependency here rather than at the old address',
      () async {
    await serve();

    var body = await get('/webapi/package/package_a/1.0.0');
    var deps =
        (body['data']['dependencies'] as List).cast<Map<String, dynamic>>();
    var packageB = deps.firstWhere((d) => d['name'] == 'package_b');

    expect(packageB['internal'], isTrue);
    expect(packageB['url'], isNull);
  });

  test('switched off, the endpoint serves what was published', () async {
    await serve(enabled: false);

    var body = await get('/api/packages/package_a/versions/1.0.0');

    expect(body['pubspec']['dependencies']['package_b']['hosted'],
        'http://pub.example.org');
  });

  test('unasked for, it does nothing at all', () async {
    // The default, and the one worth pinning: a repository that never moved
    // must answer with what its publishers uploaded. The rewrite changes
    // that answer and logs only at FINE, so on-by-default would alter what
    // every deployment serves without any of them having asked.
    await serve(asked: false);

    var body = await get('/api/packages/package_a/versions/1.0.0');

    expect(body['pubspec']['dependencies']['package_b']['hosted'],
        'http://pub.example.org');
  });
}

/// A store holding the one package under test.
class _OnePackage extends MetaStore {
  final Map<String, dynamic> stored;

  _OnePackage(this.stored);

  Never _unused() => throw UnimplementedError('not used by these tests');

  @override
  Future<UnpubPackage?> queryPackage(String name) async {
    if (name != stored['name']) return null;
    var now = DateTime.now();
    return UnpubPackage(
      name,
      [
        UnpubVersion(stored['version'] as String, stored, null,
            'someone@example.org', null, null, now)
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

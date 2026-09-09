import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:in_pub/in_pub.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

/// The acceptance test for the compatibility layer: a real `dart pub get`,
/// against a real server, over a real socket.
///
/// The graph is the one the migration produces. `package_b` and `package_a`
/// are both published here; `package_a` was published back when this
/// repository answered on `http://pub.legacy.example.org`, so its stored
/// pubspec — and the `pubspec.yaml` inside its archive, which is left exactly
/// as it was published — asks for `package_b` there. The application asks for
/// both at the address the repository answers on today. To pub those are two
/// different `package_b`s, and the whole point of the layer is that after the
/// rewrite they are one.
///
/// Written against the solver rather than against the JSON because the JSON
/// is not the claim being made. What has to be true is that `pub get`
/// succeeds, and only pub can say that.
void main() {
  /// Where this repository used to answer, as recorded in what was published.
  final legacy = Uri.parse('http://pub.legacy.example.org');

  late Directory work;
  late Directory packages;
  late HttpServer server;
  late String hostedUrl;

  /// A `pubspec.yaml` for [name], depending on [dependency] hosted at [url].
  String pubspecYaml(String name, String version,
      {String? dependency, String? url}) {
    var buffer = StringBuffer()
      ..writeln('name: $name')
      ..writeln('version: $version')
      ..writeln('description: a package for the compatibility layer test')
      ..writeln('environment:')
      ..writeln('  sdk: ">=3.0.0 <4.0.0"');
    if (dependency != null) {
      buffer
        ..writeln('dependencies:')
        ..writeln('  $dependency:')
        ..writeln('    hosted: $url')
        ..writeln('    version: ^1.0.0');
    }
    return buffer.toString();
  }

  /// The archive a publish would have stored: the pubspec as written, plus a
  /// library, gzipped tar. Never rewritten — that is the constraint the whole
  /// design is under.
  List<int> archiveOf(String name, String yaml) {
    var archive = Archive();
    void add(String name, String content) {
      var bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('pubspec.yaml', yaml);
    add('lib/$name.dart', 'const $name = true;\n');
    return GZipEncoder().encode(TarEncoder().encode(archive))!;
  }

  /// Publishes [name] into the stores directly, as an upload would have,
  /// with [yaml] recorded verbatim in both the metadata and the archive.
  Future<void> publish(_MemoryMetaStore meta, String name, String yaml) async {
    var pubspec = _loadYaml(yaml);
    var version = pubspec['version'] as String;
    meta.add(
        name,
        UnpubVersion(version, pubspec, yaml, 'someone@example.org', null, null,
            DateTime.now()));
    await FileStore(packages.path).upload(name, version, archiveOf(name, yaml));
  }

  /// Starts the repository with [compat] and returns the address it answers
  /// on. Both stores are rebuilt each time so a test cannot see another's
  /// leftovers.
  Future<String> serveOn(int port, HostedUrlCompat compat) async {
    var meta = _MemoryMetaStore();
    // Published today, against the current address.
    await publish(meta, 'package_b', pubspecYaml('package_b', '1.0.0'));

    server = await App(
      metaStore: meta,
      packageStore: FileStore(packages.path),
      hostedUrlCompat: compat,
    ).serve('127.0.0.1', port);
    var url = 'http://localhost:${server.port}';

    // Published long ago, against the address this repository has since left.
    await publish(
        meta,
        'package_a',
        pubspecYaml('package_a', '1.0.0',
            dependency: 'package_b', url: legacy.toString()));

    return url;
  }

  Future<String> serve(HostedUrlCompat compat) => serveOn(0, compat);

  /// Runs `dart pub get` in [work] against the server, with a cache of its
  /// own so no test can be answered from another's.
  Future<ProcessResult> pubGet({String cacheName = 'pub-cache'}) async {
    var cache = Directory(path.join(work.path, cacheName))
      ..createSync(recursive: true);
    return Process.run(
      Platform.resolvedExecutable,
      ['pub', 'get', '--no-precompile'],
      workingDirectory: work.path,
      environment: {
        'PUB_HOSTED_URL': hostedUrl,
        'PUB_CACHE': cache.path,
      },
    );
  }

  setUp(() {
    work = Directory.systemTemp.createTempSync('in_pub_compat_app');
    packages = Directory.systemTemp.createTempSync('in_pub_compat_packages');
  });

  tearDown(() async {
    await server.close(force: true);
    work.deleteSync(recursive: true);
    packages.deleteSync(recursive: true);
  });

  /// Writes the application: both packages at the current address, which is
  /// what every consumer looks like after moving to https.
  void writeApp() {
    File(path.join(work.path, 'pubspec.yaml')).writeAsStringSync('''
name: app
publish_to: none
environment:
  sdk: ">=3.0.0 <4.0.0"
dependencies:
  package_b:
    hosted: $hostedUrl
    version: ^1.0.0
  package_a:
    hosted: $hostedUrl
    version: ^1.0.0
''');
  }

  test('without the rewrite, the solver reports the source conflict', () async {
    hostedUrl = await serve(HostedUrlCompat.disabled());
    writeApp();

    var result = await pubGet();

    expect(result.exitCode, isNot(0),
        reason: 'this is the failure the layer exists to remove');
    var output = '${result.stdout}${result.stderr}';
    expect(output, contains('package_b'));
    expect(output, contains(legacy.host),
        reason: 'the old address is what the solver cannot reconcile');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('with the rewrite, the same graph resolves — and keeps resolving',
      () async {
    hostedUrl = await serve(HostedUrlCompat(legacyUrls: [legacy]));
    writeApp();

    var first = await pubGet();
    expect(first.exitCode, 0,
        reason: 'stdout: ${first.stdout}\nstderr: ${first.stderr}');

    // The run that matters, and the one this test used to be missing. Pub
    // reads a hosted package's dependencies from the version listing only
    // while the package is not yet in its cache; from the second run on it
    // reads the copy it extracted. A rewrite that stops at the metadata
    // passes the first run and fails here, which is exactly how it reached
    // production looking correct.
    var second = await pubGet();
    expect(second.exitCode, 0,
        reason: 'a second `pub get` on a warm cache must resolve too.\n'
            'stdout: ${second.stdout}\nstderr: ${second.stderr}');

    var lock = File(path.join(work.path, 'pubspec.lock')).readAsStringSync();
    expect(lock, contains('package_a'));
    expect(lock, contains('package_b'));
    expect(lock, isNot(contains(legacy.host)),
        reason: 'nothing may still be resolved against the old address');

    // Which is only true because the copy pub kept names this server.
    expect(_cachedPubspec(work, 'package_a'), isNot(contains(legacy.host)));
    expect(_cachedPubspec(work, 'package_a'), contains(hostedUrl));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the archive is byte-identical on every request', () async {
    // A moving content hash would be worse than the problem it fixes: pub
    // records one in `pubspec.lock` and checks the cached copy against it.
    hostedUrl = await serve(HostedUrlCompat(legacyUrls: [legacy]));
    var url = Uri.parse('$hostedUrl/packages/package_a/versions/1.0.0.tar.gz');

    var first = await http.readBytes(url);
    var second = await http.readBytes(url);

    expect(sha256.convert(first), sha256.convert(second));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a package published since the move is served untouched', () async {
    hostedUrl = await serve(HostedUrlCompat(legacyUrls: [legacy]));

    var served = await http.readBytes(
        Uri.parse('$hostedUrl/packages/package_b/versions/1.0.0.tar.gz'));
    var stored = File(path.join(packages.path, 'package_b-1.0.0.tar.gz'))
        .readAsBytesSync();

    expect(served, stored,
        reason: 'nothing in it names an old address, so nothing is unpacked');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a cache holding the old copy is not repaired without clearing it',
      () async {
    // The state every consumer is in today: the package was extracted while
    // the repository still served the archive as published, so the copy pub
    // keeps names the old address. Constructed by putting that copy back,
    // which is exactly what is on their disk.
    hostedUrl = await serve(HostedUrlCompat(legacyUrls: [legacy]));
    writeApp();
    expect((await pubGet()).exitCode, 0);

    var cached = _cachedPubspecFile(work, 'package_a');
    cached.writeAsStringSync(
        cached.readAsStringSync().replaceAll(hostedUrl, legacy.toString()));

    var stale = await pubGet();
    expect(stale.exitCode, isNot(0),
        reason: 'pub does not re-download what it already has, so the old '
            'extracted pubspec goes on naming the old address');

    // Clearing the cache is the one thing a consumer has to do by hand, and
    // then it holds — rather than working for exactly one run, which is what
    // rewriting only the metadata bought.
    expect((await pubGet(cacheName: 'pub-cache-2')).exitCode, 0);
    expect((await pubGet(cacheName: 'pub-cache-2')).exitCode, 0);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

/// The `pubspec.yaml` pub extracted for [name], which is what every solve
/// after the first one reads.
String _cachedPubspec(Directory work, String name) =>
    _cachedPubspecFile(work, name).readAsStringSync();

File _cachedPubspecFile(Directory work, String name) =>
    Directory(path.join(work.path, 'pub-cache', 'hosted'))
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((f) =>
            path.basename(f.path) == 'pubspec.yaml' &&
            path.basename(f.parent.path).startsWith('$name-'));

Map<String, dynamic> _loadYaml(String yaml) {
  // Only what these fixtures write, so the test does not depend on a yaml
  // parser to state what it published.
  var pubspec = <String, dynamic>{};
  var lines = yaml.split('\n');
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    if (line.startsWith('name: ')) pubspec['name'] = line.substring(6).trim();
    if (line.startsWith('version: ')) {
      pubspec['version'] = line.substring(9).trim();
    }
    if (line.startsWith('description: ')) {
      pubspec['description'] = line.substring(13).trim();
    }
    if (line == 'environment:') {
      pubspec['environment'] = {'sdk': '>=3.0.0 <4.0.0'};
    }
    if (line == 'dependencies:') {
      var name = lines[i + 1].trim().replaceAll(':', '');
      var url = lines[i + 2].trim().substring('hosted: '.length);
      var constraint = lines[i + 3].trim().substring('version: '.length);
      pubspec['dependencies'] = {
        name: {'hosted': url, 'version': constraint}
      };
    }
  }
  return pubspec;
}

/// The metadata store, without MongoDB: these tests are about what the
/// endpoint serves, not about where it reads it from.
class _MemoryMetaStore extends MetaStore {
  final _packages = <String, UnpubPackage>{};

  void add(String name, UnpubVersion version) {
    var existing = _packages[name];
    var now = DateTime.now();
    _packages[name] = UnpubPackage(
      name,
      [...?existing?.versions, version],
      true,
      ['someone@example.org'],
      existing?.createdAt ?? now,
      now,
      0,
    );
  }

  Never _unused() => throw UnimplementedError('not used by these tests');

  @override
  Future<UnpubPackage?> queryPackage(String name) async => _packages[name];

  @override
  Future<void> addVersion(String name, UnpubVersion version) => _unused();
  @override
  Future<void> addUploader(String name, String email) => _unused();
  @override
  Future<void> removeUploader(String name, String email) => _unused();
  @override
  Future<void> removeVersion(String name, String version) => _unused();
  @override
  void increaseDownloads(String name, String version) {}
  @override
  Future<List<UnpubRecentPublication>> queryRecentPublications({
    required int size,
  }) =>
      _unused();
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

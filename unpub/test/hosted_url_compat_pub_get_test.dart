import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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
  Future<String> serve(HostedUrlCompat compat) async {
    var meta = _MemoryMetaStore();
    // Published today, against the current address.
    await publish(meta, 'package_b', pubspecYaml('package_b', '1.0.0'));

    server = await App(
      metaStore: meta,
      packageStore: FileStore(packages.path),
      hostedUrlCompat: compat,
    ).serve('127.0.0.1', 0);
    var url = 'http://localhost:${server.port}';

    // Published long ago, against the address this repository has since left.
    await publish(
        meta,
        'package_a',
        pubspecYaml('package_a', '1.0.0',
            dependency: 'package_b', url: legacy.toString()));

    return url;
  }

  /// Runs `dart pub get` in [work] against the server, with a cache of its
  /// own so no test can be answered from another's.
  Future<ProcessResult> pubGet() async {
    var cache = Directory(path.join(work.path, 'pub-cache'))
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

  test('with the rewrite, the same graph resolves', () async {
    hostedUrl = await serve(HostedUrlCompat(legacyUrls: [legacy]));
    writeApp();

    var result = await pubGet();

    expect(result.exitCode, 0,
        reason: 'stdout: ${result.stdout}\nstderr: ${result.stderr}');

    var lock = File(path.join(work.path, 'pubspec.lock')).readAsStringSync();
    expect(lock, contains('package_a'));
    expect(lock, contains('package_b'));
    expect(lock, isNot(contains(legacy.host)),
        reason: 'nothing may still be resolved against the old address');
    // The archive still holds the pubspec as it was published: the rewrite
    // never touched it, and pub extracted it unchanged.
    var cached = Directory(path.join(work.path, 'pub-cache', 'hosted'));
    var extracted = cached
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((f) =>
            path.basename(f.path) == 'pubspec.yaml' &&
            path.basename(f.parent.path).startsWith('package_a-'));
    expect(extracted.readAsStringSync(), contains(legacy.toString()),
        reason: 'the published archive is left exactly as it was');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

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

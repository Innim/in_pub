import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

/// Generation state of a package version's API documentation.
enum DocStatus {
  /// Never requested / not being generated and not cached.
  none,

  /// Currently being generated.
  generating,

  /// Generated and cached, ready to serve.
  ready,

  /// The last generation attempt failed.
  failed,
}

/// Thrown internally when doc generation fails; [message] is safe to show to
/// the user (the full tool output is written to stderr).
class DocGenerationException implements Exception {
  final String message;
  DocGenerationException(this.message);
  @override
  String toString() => message;
}

/// Generates and caches dartdoc API documentation for package versions on
/// demand.
///
/// The first request for a given `name@version` extracts that version's
/// tarball, runs `dart pub get` and `dart doc`, and stores the generated HTML
/// under [cacheDir]. Subsequent requests are served straight from the cache.
///
/// Generating docs requires a Dart SDK ([dartExecutable]) to be available on
/// the server host, and network access to resolve dependencies.
class DocStore {
  /// Root directory where generated documentation is cached, laid out as
  /// `<cacheDir>/<name>/<version>/`.
  final String cacheDir;

  /// Directory used for transient tarball extraction and builds.
  final String workDir;

  /// The `dart` executable used to run `pub get` and `dart doc`.
  final String dartExecutable;

  DocStore(
    this.cacheDir, {
    String? workDir,
    this.dartExecutable = 'dart',
  }) : workDir = workDir ?? path.join(cacheDir, '.work');

  /// In-progress generation futures, keyed by `name/version`, so concurrent
  /// requests share a single `dart doc` run.
  final _inFlight = <String, Future<Directory?>>{};

  /// User-facing error message from the last failed attempt, keyed the same.
  final _failed = <String, String>{};

  String _key(String name, String version) => '$name/$version';

  Directory _docDir(String name, String version) =>
      Directory(path.join(cacheDir, name, version));

  /// Returns the cached doc directory for [name]@[version] without generating
  /// anything, or null if it has not been generated yet.
  Directory? cachedDir(String name, String version) {
    final dir = _docDir(name, version);
    if (File(path.join(dir.path, 'index.html')).existsSync()) {
      return dir;
    }
    return null;
  }

  /// Current generation state of [name]@[version].
  DocStatus statusOf(String name, String version) {
    if (cachedDir(name, version) != null) return DocStatus.ready;
    final key = _key(name, version);
    if (_inFlight.containsKey(key)) return DocStatus.generating;
    if (_failed.containsKey(key)) return DocStatus.failed;
    return DocStatus.none;
  }

  /// The error message from the last failed generation of [name]@[version],
  /// or null if there is none.
  String? errorOf(String name, String version) => _failed[_key(name, version)];

  /// Starts generating docs for [name]@[version] if not already cached or in
  /// progress, and returns immediately. A previously failed attempt is retried.
  ///
  /// [readTarball] is called only when a build actually starts.
  void startGeneration(
    String name,
    String version,
    Future<List<int>> Function() readTarball,
  ) {
    _ensure(name, version, readTarball);
  }

  /// Returns the directory containing generated docs for [name]@[version],
  /// generating (and caching) them first if necessary. Returns null on
  /// failure.
  Future<Directory?> getDocs(
    String name,
    String version,
    Future<List<int>> Function() readTarball,
  ) =>
      _ensure(name, version, readTarball);

  /// Removes any cached docs (and remembered failure) for [name]@[version].
  Future<void> delete(String name, String version) async {
    _failed.remove(_key(name, version));
    final dir = _docDir(name, version);
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  Future<Directory?> _ensure(
    String name,
    String version,
    Future<List<int>> Function() readTarball,
  ) {
    final cached = cachedDir(name, version);
    if (cached != null) return Future.value(cached);

    final key = _key(name, version);
    final existing = _inFlight[key];
    if (existing != null) return existing;

    _failed.remove(key);
    final future = _run(name, version, readTarball);
    _inFlight[key] = future;
    return future;
  }

  Future<Directory?> _run(
    String name,
    String version,
    Future<List<int>> Function() readTarball,
  ) async {
    final key = _key(name, version);
    try {
      return await _generate(name, version, readTarball);
    } on DocGenerationException catch (e) {
      _failed[key] = e.message;
      return null;
    } catch (e, st) {
      stderr.writeln('Failed to generate docs for $name@$version: $e\n$st');
      _failed[key] = 'Documentation generation failed.';
      return null;
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<Directory> _generate(
    String name,
    String version,
    Future<List<int>> Function() readTarball,
  ) async {
    final docDir = _docDir(name, version);
    Directory? extractDir;
    try {
      extractDir = await _extract(name, version, await readTarball());

      final pubGet = await Process.run(
        dartExecutable,
        ['pub', 'get'],
        workingDirectory: extractDir.path,
      );
      if (pubGet.exitCode != 0) {
        stderr.writeln('dart pub get failed for $name@$version:\n'
            '${pubGet.stdout}\n${pubGet.stderr}');
        throw DocGenerationException(
            'Failed to resolve dependencies (dart pub get).');
      }

      // Generate into a temp directory, then swap it into place so a failed
      // or partial run never leaves a half-written cache dir behind.
      final tmpOut = Directory(path.join(cacheDir, name, '.tmp-$version'));
      if (await tmpOut.exists()) await tmpOut.delete(recursive: true);

      final doc = await Process.run(
        dartExecutable,
        ['doc', '--output', tmpOut.path, '.'],
        workingDirectory: extractDir.path,
      );
      if (doc.exitCode != 0) {
        stderr.writeln('dart doc failed for $name@$version:\n'
            '${doc.stdout}\n${doc.stderr}');
        await tmpOut.delete(recursive: true).catchError((_) => tmpOut);
        throw DocGenerationException('dart doc failed to build the docs.');
      }

      if (await docDir.exists()) await docDir.delete(recursive: true);
      await docDir.parent.create(recursive: true);
      await tmpOut.rename(docDir.path);
      return docDir;
    } finally {
      if (extractDir != null) {
        await extractDir.delete(recursive: true).catchError((_) => extractDir!);
      }
    }
  }

  Future<Directory> _extract(
      String name, String version, List<int> tarball) async {
    final dir = Directory(path.join(workDir, '$name-$version'));
    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    final tarBytes = GZipDecoder().decodeBytes(tarball);
    final archive = TarDecoder().decodeBytes(tarBytes);
    for (final file in archive.files) {
      if (!file.isFile) continue;
      // Guard against path traversal from a malicious archive.
      final outPath = path.normalize(path.join(dir.path, file.name));
      if (!path.isWithin(dir.path, outPath)) continue;
      final outFile = File(outPath);
      await outFile.create(recursive: true);
      await outFile.writeAsBytes(file.content as List<int>);
    }

    await _pointHomepageAtPackagePage(dir, name);
    return dir;
  }

  /// dartdoc turns the pubspec `homepage` into the top-left breadcrumb link
  /// (and shows plain, unlinked text when there is no homepage). We rewrite it
  /// to this server's package page so that breadcrumb navigates back to the
  /// package instead of off to an external site.
  Future<void> _pointHomepageAtPackagePage(Directory dir, String name) async {
    final pubspec = File(path.join(dir.path, 'pubspec.yaml'));
    if (!await pubspec.exists()) return;

    final target = 'homepage: /packages/$name';
    var content = await pubspec.readAsString();
    // Match a top-level `homepage:` key (column 0, so nested keys are safe).
    final homepageLine = RegExp(r'^homepage:.*$', multiLine: true);
    if (homepageLine.hasMatch(content)) {
      content = content.replaceFirst(homepageLine, target);
    } else {
      content = '${content.trimRight()}\n$target\n';
    }
    await pubspec.writeAsString(content);
  }
}

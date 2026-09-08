import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:logging/logging.dart';
import 'package:yaml/yaml.dart';

/// Rewrites the repository urls that a *published* pubspec names, so that
/// packages published under an earlier address of this repository resolve
/// against the address it answers on today.
///
/// The problem it exists for: pub treats the hosted source as part of a
/// package's identity, and the url is the whole of that identity. A package
/// published years ago carrying
///
/// ```yaml
/// dependencies:
///   innim_lib:
///     hosted: http://pub.example.org
/// ```
///
/// asks for a *different* `innim_lib` than an application that asks for the
/// same package on `https://pub.example.org`, and the solver reports the two
/// as an unsatisfiable conflict rather than as one package. Moving the
/// repository to https — which authentication requires, since `dart pub
/// token add` refuses a plain-http url — therefore strands every version
/// published before the move, and there are only three ways out of it:
/// republish all of them, override them in every consumer, or serve the old
/// metadata under the new address. This is the third.
///
/// Nothing stored is touched. The archives keep their original
/// `pubspec.yaml`, their content hashes stay valid, and no version number
/// changes; only the copy of the pubspec that leaves through the repository
/// API is adjusted, which is also why the whole thing can be switched off
/// again — or deleted — without anything having to be undone.
///
/// It is not a substitute for publishing new versions correctly: a package
/// published today should name the https address, and this layer leaves such
/// a pubspec untouched (rewriting is idempotent, so applying it to everything
/// is safe).
///
/// Opt-in: [App] rewrites nothing unless it is given one of these, and the
/// server switches it on with `--legacy-hosted-url-rewrite`. Constructing one
/// enables it — the object is the request — so a deployment that never moved
/// answers with exactly what its publishers uploaded, which is what a
/// repository should do unless somebody has decided otherwise.
class HostedUrlCompat {
  static final _log = Logger('in_pub.compat');

  /// Sections of a pubspec whose entries name a source.
  ///
  /// `dependency_overrides` is included for consistency rather than need:
  /// the solver ignores a dependency's dev dependencies and overrides
  /// entirely, but this server hands out the stored pubspec whole, so an
  /// override that a publish happened to carry would otherwise leave still
  /// naming an address that no longer exists.
  static const _sections = [
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  ];

  /// Whether to rewrite anything at all. Off leaves every pubspec exactly as
  /// it is stored.
  final bool enabled;

  /// Addresses this repository used to be reachable at, beyond the one
  /// derived per request (see [rewrite]).
  ///
  /// Configured rather than hardcoded, and normally empty: the ordinary
  /// http-to-https move needs no list, because the address to look for is
  /// the address the server is being asked on with its scheme changed back.
  /// This is for the rest — a hostname that was retired, a port that a
  /// reverse proxy no longer publishes.
  final List<Uri> legacyUrls;

  /// Rewrites already reported, so a repeated `dart pub get` — which asks
  /// for the same metadata every time — does not repeat the same lines.
  final Set<String> _reported = {};

  /// The last answer of [_legacyIdentities], which depends only on the
  /// address the server is being asked on. [rewrite] runs once per published
  /// version, so a package with a long history rebuilt the same short list
  /// from the same url a hundred times over to serve one request.
  Uri? _identitiesFor;
  List<String>? _identities;

  HostedUrlCompat({this.enabled = true, this.legacyUrls = const []});

  /// Off, for a deployment that wants the stored metadata served untouched.
  HostedUrlCompat.disabled() : this(enabled: false);

  /// [pubspec] with every hosted url that names an old address of this
  /// repository replaced by [canonical].
  ///
  /// [canonical] is where this server is answering right now — the caller
  /// derives it from the configured public address, falling back to the
  /// request. Deriving it that way, rather than from a mapping written down
  /// somewhere, is what keeps the rewrite honest: the only url this can ever
  /// produce is one the client has just successfully spoken to, so it can
  /// never send a client that arrived over https back to an http endpoint,
  /// with or without its credentials.
  ///
  /// Returns [pubspec] itself when nothing matched, which is the usual case:
  /// a pubspec that already names the current address costs one pass over
  /// its dependency maps and allocates nothing.
  Map<String, dynamic> rewrite(
    Map<String, dynamic> pubspec, {
    required Uri canonical,
    String? package,
    String? version,
  }) {
    if (!enabled) return pubspec;

    final targets = _targetsFor(canonical);
    if (targets.isEmpty) return pubspec;

    final replacement = _identity(canonical);
    Map<String, dynamic>? result;

    for (final section in _sections) {
      final deps = pubspec[section];
      if (deps is! Map) continue;

      Map<String, dynamic>? rewritten;
      for (final entry in deps.entries) {
        final name = entry.key;
        if (name is! String) continue;
        final updated = _rewriteDependency(entry.value, targets, replacement,
            package: package, version: version, dependency: name);
        if (updated == null) continue;
        rewritten ??= Map<String, dynamic>.of(deps.cast<String, dynamic>());
        rewritten[name] = updated;
      }

      if (rewritten == null) continue;
      result ??= Map<String, dynamic>.of(pubspec);
      result[section] = rewritten;
    }

    return result ?? pubspec;
  }

  /// [archive] — a published `.tar.gz` — with the `pubspec.yaml` inside it
  /// rewritten the same way [rewrite] rewrites the metadata. Null when
  /// nothing in it names an old address, which is the answer for everything
  /// published since the move.
  ///
  /// This exists because rewriting the metadata alone fixes exactly one
  /// resolution. `dart pub` reads a hosted package's dependencies from the
  /// version listing only while that package is not yet in the local cache;
  /// once it has been extracted into
  /// `$PUB_CACHE/hosted/<host>/<package>-<version>/`, every later solve reads
  /// *that* directory's `pubspec.yaml` instead. So a `pub get` on a clean
  /// cache succeeded and the very next one failed with the conflict again.
  /// The copy the client keeps has to name the current address too.
  ///
  /// The stored archive is never touched — this transforms the bytes on their
  /// way out — but it does change what the client receives, and therefore the
  /// content hash it records in `pubspec.lock`. That is the price, and it is
  /// paid once: pub reports the hash it had is out of date, updates it, and
  /// is quiet from then on. The output is a deterministic function of the
  /// input, so the hash does not move between requests or restarts.
  List<int>? rewriteArchive(
    List<int> archive, {
    required Uri canonical,
    String? package,
    String? version,
  }) {
    if (!enabled || _targetsFor(canonical).isEmpty) return null;

    final Archive decoded;
    try {
      decoded = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(archive));
    } catch (error) {
      // Not this layer's business to reject an archive: whatever is stored is
      // what was published, and a client that can read it should keep getting
      // it. Served untouched, with a line saying why.
      _log.warning('Could not read the archive of $package $version to '
          'rewrite its pubspec; serving it unchanged. $error');
      return null;
    }

    // `dart pub publish` puts the pubspec at the root. `./pubspec.yaml` is
    // accepted too, since not every archive in a repository this old was
    // necessarily written by the same tool.
    final pubspecFile = decoded.files.firstWhereOrNull(
        (f) => f.name == 'pubspec.yaml' || f.name == './pubspec.yaml');
    if (pubspecFile == null) return null;

    final String source;
    try {
      source = utf8.decode(pubspecFile.content as List<int>);
    } on FormatException catch (error) {
      _log.warning('The pubspec of $package $version is not valid UTF-8; '
          'serving the archive unchanged. $error');
      return null;
    }

    final rewritten = rewritePubspecYaml(source,
        canonical: canonical, package: package, version: version);
    if (rewritten == null) return null;

    final bytes = utf8.encode(rewritten);
    final result = Archive();
    for (final file in decoded.files) {
      if (!identical(file, pubspecFile)) {
        result.addFile(file);
        continue;
      }
      // Mode and timestamp carried over, so the only difference between the
      // archive that was published and the one served is the url.
      result.addFile(ArchiveFile(file.name, bytes.length, bytes)
        ..mode = file.mode
        ..lastModTime = file.lastModTime);
    }
    return _deterministicGzip(TarEncoder().encode(result));
  }

  /// [tar] gzipped with the timestamp left out of the header.
  ///
  /// `GZipEncoder` stamps `DateTime.now()` into the gzip MTIME field, so the
  /// same archive encoded two seconds apart comes out with a different
  /// SHA-256 — and pub records that hash in `pubspec.lock` and checks the
  /// cached copy against it. Every clean-cache resolve would report the hash
  /// as out of date and rewrite the lockfile, and `--enforce-lockfile` would
  /// simply fail. Zero is what RFC 1952 reserves for "no timestamp", which is
  /// what `gzip -n` writes and what every reader ignores.
  static List<int>? _deterministicGzip(List<int> tar) {
    final bytes = GZipEncoder().encode(tar);
    if (bytes == null || bytes.length < 8) return bytes;
    // Only on something that is actually gzip, so a future encoder change
    // cannot have four unrelated bytes overwritten.
    if (bytes[0] != 0x1f || bytes[1] != 0x8b) return bytes;
    for (var i = 4; i < 8; i++) {
      bytes[i] = 0;
    }
    return bytes;
  }

  /// [yaml] with the hosted urls that name an old address of this repository
  /// replaced, or null when there are none.
  ///
  /// Edits the text in place rather than re-serialising a parsed document:
  /// what goes back into the archive is the pubspec its author wrote, with
  /// comments, quoting and key order intact and one url different. Round
  /// tripping it through a YAML writer would hand the client a file that
  /// differs from what was published in ways nobody asked for.
  String? rewritePubspecYaml(
    String yaml, {
    required Uri canonical,
    String? package,
    String? version,
  }) {
    if (!enabled) return null;
    final targets = _targetsFor(canonical);
    if (targets.isEmpty) return null;
    final replacement = _identity(canonical);

    final YamlNode document;
    try {
      document = loadYamlNode(yaml);
    } on YamlException catch (error) {
      _log.warning('Could not parse the pubspec of $package $version; '
          'serving it unchanged. $error');
      return null;
    }
    if (document is! YamlMap) return null;

    // Collected first and applied last-to-first, so replacing one url cannot
    // move the offsets of the ones still to come.
    final edits = <_UrlEdit>[];
    for (final section in _sections) {
      final deps = document.nodes[section];
      if (deps is! YamlMap) continue;
      for (final entry in deps.nodes.entries) {
        final name = entry.key;
        final dependency = name is YamlScalar ? name.value : name;
        if (dependency is! String) continue;
        final spec = entry.value;
        if (spec is! YamlMap) continue;
        if (spec.containsKey('path') ||
            spec.containsKey('git') ||
            spec.containsKey('sdk')) {
          continue;
        }
        final hosted = spec.nodes['hosted'];
        YamlNode? urlNode;
        if (hosted is YamlScalar) {
          urlNode = hosted;
        } else if (hosted is YamlMap) {
          final url = hosted.nodes['url'];
          if (url is YamlScalar) urlNode = url;
        }
        final from = urlNode?.value;
        if (urlNode == null || from is! String) continue;
        final to = _rewriteUrl(from, targets, replacement);
        if (to == null) continue;
        edits.add(_UrlEdit(urlNode.span.start.offset, urlNode.span.end.offset,
            from, to, dependency));
      }
    }
    if (edits.isEmpty) return null;

    edits.sort((a, b) => b.start.compareTo(a.start));
    var result = yaml;
    for (final edit in edits) {
      final slice = result.substring(edit.start, edit.end);
      // The span is the scalar and nothing else, so the url is in it — unless
      // it was written with escapes, in which case leaving the file alone
      // beats guessing at its spelling.
      if (!slice.contains(edit.from)) continue;
      result = result.replaceRange(
          edit.start, edit.end, slice.replaceFirst(edit.from, edit.to));
      _report(
          package: package,
          version: version,
          dependency: edit.dependency,
          from: edit.from,
          to: edit.to);
    }
    return result == yaml ? null : result;
  }

  /// The addresses to look for when answering on [canonical], memoised: the
  /// answer depends on nothing else, and both entry points ask for it per
  /// published version.
  List<String> _targetsFor(Uri canonical) {
    if (_identitiesFor != canonical) {
      _identities = _legacyIdentities(canonical);
      _identitiesFor = canonical;
    }
    return _identities!;
  }

  /// The rewritten form of one dependency entry, or null to leave it alone.
  Map<String, dynamic>? _rewriteDependency(
    dynamic spec,
    List<String> targets,
    String replacement, {
    String? package,
    String? version,
    required String dependency,
  }) {
    // A plain constraint (`^1.2.3`) names no source, so there is nothing in
    // it to move.
    if (spec is! Map) return null;

    // `path`, `git` and `sdk` dependencies are not hosted anywhere and are
    // left exactly as published — a `git` url that happens to be on the same
    // host is still a git url, and switching its scheme would break a clone.
    if (spec.containsKey('path') ||
        spec.containsKey('git') ||
        spec.containsKey('sdk')) {
      return null;
    }

    final hosted = spec['hosted'];
    final String from;
    final String to;
    final dynamic updatedHosted;

    if (hosted is String) {
      // The short form: `hosted: <url>`.
      final rewritten = _rewriteUrl(hosted, targets, replacement);
      if (rewritten == null) return null;
      from = hosted;
      to = rewritten;
      updatedHosted = rewritten;
    } else if (hosted is Map) {
      // The structured form: `hosted: {name: ..., url: ...}`.
      final url = hosted['url'];
      if (url is! String) return null;
      final rewritten = _rewriteUrl(url, targets, replacement);
      if (rewritten == null) return null;
      from = url;
      to = rewritten;
      // Rebuilt rather than mutated: the stored map belongs to the metadata
      // this request loaded, and writing through it would hand the next
      // caller a pubspec that had already been altered by this one.
      updatedHosted = Map<String, dynamic>.of(hosted.cast<String, dynamic>())
        ..['url'] = rewritten;
    } else {
      return null;
    }

    _report(
        package: package,
        version: version,
        dependency: dependency,
        from: from,
        to: to);

    // Assigning over an existing key keeps its position, so the pubspec goes
    // out in the order it was published in.
    return Map<String, dynamic>.of(spec.cast<String, dynamic>())
      ..['hosted'] = updatedHosted;
  }

  /// [url] rewritten to [replacement] when it names one of [targets],
  /// preserving whether it was written with a trailing slash. Null when it
  /// names anything else.
  String? _rewriteUrl(String url, List<String> targets, String replacement) {
    final trimmed = url.trim();
    final uri = Uri.tryParse(trimmed);
    // Deliberately strict, and not a substring replace: a repository url
    // with a query or fragment is not one of ours, and neither is
    // `http://pub.example.org.attacker.test` — which any `contains` or
    // `startsWith` on the host would happily rewrite.
    if (uri == null ||
        !uri.hasScheme ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    if (!targets.contains(_identity(uri))) return null;
    return trimmed.endsWith('/') ? '$replacement/' : replacement;
  }

  /// Every address that should be read as an older spelling of [canonical].
  ///
  /// Always the same address over plain http, when the server is answering
  /// on https — that is the migration this exists for, and it needs no
  /// configuration — plus whatever [legacyUrls] adds. When the server itself
  /// is answering over http there is no such counterpart, so an unconfigured
  /// http deployment rewrites nothing.
  List<String> _legacyIdentities(Uri canonical) {
    final canonicalIdentity = _identity(canonical);
    final result = <String>[];
    if (canonical.scheme == 'https') {
      // No port juggling: `Uri` drops a port that is its scheme's default,
      // so `https://host:443` arrives here as `https://host` and the
      // counterpart comes out as the plain `http://host` old pubspecs
      // actually name, while a real port such as `:8443` is carried over —
      // which is the only defensible guess, and what --legacy-hosted-url is
      // there to correct when the old address used a different one.
      result.add(_identity(canonical.replace(scheme: 'http')));
    }
    for (final legacy in legacyUrls) {
      final identity = _identity(legacy);
      // A configured address equal to the current one would make every
      // pubspec "match" and rewrite to what it already says. Harmless, but
      // it would fill the log with rewrites that changed nothing.
      if (identity == canonicalIdentity) continue;
      if (!result.contains(identity)) result.add(identity);
    }
    return result;
  }

  /// A repository address reduced to what identifies it: scheme, host, port
  /// — dropped when it is the scheme's default — and path without a trailing
  /// slash.
  ///
  /// Comparing these rather than the strings is what makes the match both
  /// strict and forgiving in the right places: `http://pub.example.org`,
  /// `http://pub.example.org/` and `http://pub.example.org:80` are one
  /// address, while `http://pub.example.org.attacker.test` is not, and
  /// neither is the same host on another port serving another repository.
  static String _identity(Uri uri) {
    // `Uri.host` hands back an IPv6 literal without its brackets, so a
    // repository reached at `https://[::1]:4000` would otherwise be written
    // out as `https://::1:4000`, which no client can parse. Bracketing here
    // rather than at the point of use keeps matching and the replacement
    // spelling the same address.
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    final buffer = StringBuffer('${uri.scheme}://$host');
    if (uri.hasPort && uri.port != _defaultPort(uri.scheme)) {
      buffer.write(':${uri.port}');
    }
    var path = uri.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    buffer.write(path);
    return buffer.toString();
  }

  static int? _defaultPort(String scheme) => switch (scheme) {
        'http' => 80,
        'https' => 443,
        _ => null,
      };

  void _report({
    String? package,
    String? version,
    required String dependency,
    required String from,
    required String to,
  }) {
    if (!_log.isLoggable(Level.FINE)) return;
    final key = '$package|$version|$dependency|$from|$to';
    // Bounded rather than merely deduplicated: this runs on a long-lived
    // server and the set is keyed by package, so an unbounded one grows with
    // the repository. Clearing it costs nothing worse than one repeated line
    // per package after a great many distinct rewrites.
    if (!_reported.add(key)) return;
    if (_reported.length > 1000) _reported.clear();
    _log.fine('Pub compatibility rewrite: package=$package version=$version '
        'dependency=$dependency from=$from to=$to');
  }
}

/// One hosted url found in a pubspec's text, and what it should say.
class _UrlEdit {
  final int start;
  final int end;
  final String from;
  final String to;
  final String dependency;

  _UrlEdit(this.start, this.end, this.from, this.to, this.dependency);
}

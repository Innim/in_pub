import 'package:logging/logging.dart';

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

    final targets = _identitiesFor == canonical
        ? _identities!
        : (_identities = _legacyIdentities(canonical));
    _identitiesFor = canonical;
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

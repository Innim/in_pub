import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:crypto/crypto.dart' show sha1;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:googleapis/oauth2/v2.dart';
import 'package:mime/mime.dart';
import 'package:http_parser/http_parser.dart';
import 'package:shelf_cors_headers/shelf_cors_headers.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:pub_semver/pub_semver.dart' as semver;
import 'package:archive/archive.dart';
import 'package:in_pub/src/models.dart';
import 'package:in_pub/unpub_api/lib/models.dart';
import 'package:in_pub/src/meta_store.dart';
import 'package:in_pub/src/package_store.dart';
import 'package:in_pub/src/doc_store.dart';
import 'package:in_pub/src/doc_progress_page.dart';
import 'package:in_pub/src/auth/auth_service.dart';
import 'package:path/path.dart' as p;
import 'utils.dart';
import 'auth_exception.dart';
import 'static/index.html.dart' as index_html;
import 'static/main.dart.js.dart' as main_dart_js;

part 'app.g.dart';

class App {
  static const proxyOriginHeader = "proxy-origin";

  /// meta information store
  final MetaStore metaStore;

  /// package(tarball) store
  final PackageStore packageStore;

  /// generates and caches dartdoc API documentation on demand; when null the
  /// `/documentation/...` route is disabled.
  final DocStore? docStore;

  /// upstream url, default: https://pub.dev
  final String upstream;

  /// when non-null, browsing the repository requires a signed-in user; see
  /// `lib/src/auth/`. Null leaves the server open, as it was before.
  final AuthService? auth;

  /// http(s) proxy to call googleapis (to get uploader email)
  final String? googleapisProxy;
  final String? overrideUploaderEmail;

  /// A forward proxy uri
  final Uri? proxy_origin;

  final String version;

  /// validate if the package can be published
  ///
  /// for more details, see: https://github.com/Innim/in_pub#package-validator
  final Future<void> Function(
      Map<String, dynamic> pubspec, String uploaderEmail)? uploadValidator;

  App({
    required this.metaStore,
    required this.packageStore,
    this.docStore,
    this.auth,
    this.upstream = 'https://pub.dev',
    this.googleapisProxy,
    this.overrideUploaderEmail,
    this.uploadValidator,
    this.proxy_origin,
    this.version = '',
  });

  static shelf.Response _okWithJson(Map<String, dynamic> data) =>
      shelf.Response.ok(
        json.encode(data),
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          'Access-Control-Allow-Origin': '*'
        },
      );

  static shelf.Response _successMessage(String message) => _okWithJson({
        'success': {'message': message}
      });

  static shelf.Response _badRequest(String message,
          {int status = HttpStatus.badRequest}) =>
      shelf.Response(
        status,
        headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
        body: json.encode({
          'error': {'message': message}
        }),
      );

  /// 401 for the pub client.
  ///
  /// `dart pub` prints the `message` parameter of the `WWW-Authenticate`
  /// header back to the user, so it is the one place where a hint about how
  /// to authenticate actually reaches them.
  static shelf.Response _unauthorized(String message) => shelf.Response(
        HttpStatus.unauthorized,
        headers: {
          HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
          HttpHeaders.wwwAuthenticateHeader:
              'Bearer realm="pub", message="${_quoteHeaderValue(message)}"',
        },
        body: json.encode({
          'error': {'message': message}
        }),
      );

  /// Makes [value] safe to place inside a quoted HTTP header parameter.
  static String _quoteHeaderValue(String value) => value
      .replaceAll('\\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll(RegExp(r'[\r\n]+'), ' ');

  http.Client? _googleapisClient;

  String _resolveUrl(shelf.Request req, String reference) {
    if (proxy_origin != null) {
      return proxy_origin!.resolve(reference).toString();
    }
    String? proxyOriginInHeader = req.headers[proxyOriginHeader];
    if (proxyOriginInHeader != null) {
      return Uri.parse(proxyOriginInHeader).resolve(reference).toString();
    }
    return req.requestedUri.resolve(reference).toString();
  }

  Future<String> _getUploaderEmail(shelf.Request req) async {
    if (overrideUploaderEmail != null) return overrideUploaderEmail!;

    var authHeader = req.headers[HttpHeaders.authorizationHeader];
    if (authHeader == null) throw AuthException('missing authorization header');

    var token = authHeader.split(' ').last;

    if (_googleapisClient == null) {
      if (googleapisProxy != null) {
        _googleapisClient = IOClient(HttpClient()
          ..findProxy = (url) => HttpClient.findProxyFromEnvironment(url,
              environment: {"https_proxy": googleapisProxy!}));
      } else {
        _googleapisClient = http.Client();
      }
    }

    var info =
        await Oauth2Api(_googleapisClient!).tokeninfo(accessToken: token);
    if (info.email == null)
      throw AuthException('fail to get google account email');
    return info.email!;
  }

  Future<HttpServer> serve([String host = '0.0.0.0', int port = 4000]) async {
    var authService = auth;
    if (authService != null) await authService.start();

    var pipeline = const shelf.Pipeline()
        .addMiddleware(corsHeaders())
        .addMiddleware(shelf.logRequests());
    // The gate sits inside request logging so refusals are logged, and
    // outside the router so a route that does not exist cannot be probed
    // without a session.
    if (authService != null)
      pipeline = pipeline.addMiddleware(authService.gate);

    var handler = pipeline.addHandler((req) async {
      if (authService != null && req.requestedUri.path.startsWith('/auth/')) {
        var authResponse = await authService.handler(req);
        if (authResponse.statusCode != HttpStatus.notFound) return authResponse;
      }
      // Return 404 by default
      // https://github.com/google/dart-neats/issues/1
      var res = await router.call(req);
      return res;
    });
    var server = await shelf_io.serve(handler, host, port);
    return server;
  }

  Map<String, dynamic> _versionToJson(UnpubVersion item, shelf.Request req) {
    var name = item.pubspec['name'] as String;
    var version = item.version;
    return {
      'archive_url':
          _resolveUrl(req, '/packages/$name/versions/$version.tar.gz'),
      'pubspec': item.pubspec,
      'version': version,
    };
  }

  /// Picks the version to show by default for a package: the highest stable
  /// version, or the highest prerelease (dev/alpha/beta) only when there is no
  /// stable version at all. This is not necessarily the last uploaded version —
  /// a fix published for an older release must not become the default.
  UnpubVersion? _primaryVersion(List<UnpubVersion> versions) {
    if (versions.isEmpty) return null;
    var primary = semver.Version.primary(
        versions.map((v) => semver.Version.parse(v.version)).toList());
    return versions.firstWhere(
        (v) => semver.Version.parse(v.version) == primary,
        orElse: () => versions.last);
  }

  bool isPubClient(shelf.Request req) {
    var ua = req.headers[HttpHeaders.userAgentHeader];
    print(ua);
    return ua != null && ua.toLowerCase().contains('dart pub');
  }

  Router get router => _$AppRouter(this);

  @Route.get('/api/packages/<name>')
  Future<shelf.Response> getVersions(shelf.Request req, String name) async {
    var package = await metaStore.queryPackage(name);

    if (package == null) {
      return shelf.Response.found(
          Uri.parse(upstream).resolve('/api/packages/$name').toString());
    }

    package.versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(a.version), semver.Version.parse(b.version));
    });

    var versionMaps =
        package.versions.map((item) => _versionToJson(item, req)).toList();

    var primary = _primaryVersion(package.versions);

    return _okWithJson({
      'name': name,
      'latest':
          primary != null ? _versionToJson(primary, req) : versionMaps.last,
      'versions': versionMaps,
    });
  }

  @Route.get('/api/packages/<name>/versions/<version>')
  Future<shelf.Response> getVersion(
      shelf.Request req, String name, String version) async {
    // Important: + -> %2B, should be decoded here
    try {
      version = Uri.decodeComponent(version);
    } catch (err) {
      print(err);
    }

    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/api/packages/$name/versions/$version')
          .toString());
    }

    var packageVersion =
        package.versions.firstWhereOrNull((item) => item.version == version);
    if (packageVersion == null) {
      return shelf.Response.notFound('Not Found');
    }

    return _okWithJson(_versionToJson(packageVersion, req));
  }

  @Route.get('/packages/<name>/versions/<version>.tar.gz')
  Future<shelf.Response> download(
      shelf.Request req, String name, String version) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/packages/$name/versions/$version.tar.gz')
          .toString());
    }

    if (isPubClient(req)) {
      metaStore.increaseDownloads(name, version);
    }

    if (packageStore.supportsDownloadUrl) {
      return shelf.Response.found(
          await packageStore.downloadUrl(name, version));
    } else {
      return shelf.Response.ok(
        packageStore.download(name, version),
        headers: {HttpHeaders.contentTypeHeader: ContentType.binary.mimeType},
      );
    }
  }

  Future<List<int>> _readTarball(String name, String version) async {
    var builder = BytesBuilder();
    await for (var chunk in packageStore.download(name, version)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Requests without a trailing slash are redirected so the generated docs'
  /// relative asset/links resolve against the version directory.
  @Route.get('/documentation/<name>/<version>')
  Future<shelf.Response> documentationRedirect(
      shelf.Request req, String name, String version) async {
    return shelf.Response.movedPermanently(
        req.requestedUri.replace(path: '${req.requestedUri.path}/').toString());
  }

  /// JSON generation status, polled by the "generating…" progress page.
  @Route.get('/documentation/<name>/<version>/__status')
  Future<shelf.Response> documentationStatus(
      shelf.Request req, String name, String version) async {
    if (docStore == null) {
      return _okWithJson({'status': DocStatus.none.name});
    }
    try {
      version = Uri.decodeComponent(version);
    } catch (_) {}

    var status = docStore!.statusOf(name, version);
    return _okWithJson({
      'status': status.name,
      if (status == DocStatus.failed)
        'error': docStore!.errorOf(name, version) ??
            'Documentation generation failed.',
    });
  }

  @Route.get('/documentation/<name>/<version>/<file|[^]*>')
  Future<shelf.Response> documentation(
      shelf.Request req, String name, String version, String file) async {
    if (docStore == null) {
      return shelf.Response.notFound(
          'API documentation is not available on this server.');
    }

    try {
      version = Uri.decodeComponent(version);
    } catch (_) {}

    // Already generated: serve the requested file straight from the cache,
    // without a metadata lookup.
    var docDir = docStore!.cachedDir(name, version);
    if (docDir != null) {
      return _serveDocFile(docDir, file.isEmpty ? 'index.html' : file);
    }

    // A sub-resource requested before docs exist: nothing to serve yet.
    if (file.isNotEmpty && file != 'index.html') {
      return shelf.Response.notFound('Not Found');
    }

    var package = await metaStore.queryPackage(name);
    // Not hosted here — defer to the upstream server's documentation.
    if (package == null) {
      return shelf.Response.found(Uri.parse(upstream)
          .resolve('/documentation/$name/$version/')
          .toString());
    }
    if (package.versions.every((v) => v.version != version)) {
      return shelf.Response.notFound('Not Found');
    }

    // Kick off generation (idempotent) and show the progress page, which
    // polls `__status` and reloads into the docs when they are ready.
    docStore!.startGeneration(name, version, () => _readTarball(name, version));
    return shelf.Response.ok(
      docProgressPage(name, version),
      headers: {HttpHeaders.contentTypeHeader: ContentType.html.mimeType},
    );
  }

  Future<shelf.Response> _serveDocFile(Directory docDir, String file) async {
    // Resolve the requested file within the doc dir, guarding against
    // path traversal (`..`) escaping the cache.
    var target = p.normalize(p.join(docDir.path, file));
    if (!p.equals(target, docDir.path) && !p.isWithin(docDir.path, target)) {
      return shelf.Response.notFound('Not Found');
    }

    // dartdoc links to libraries as directories (e.g. `foo/`); serve the
    // directory's index.html so those links resolve.
    if (await Directory(target).exists()) {
      target = p.join(target, 'index.html');
    }

    var f = File(target);
    if (!await f.exists()) {
      return shelf.Response.notFound('Not Found');
    }

    return shelf.Response.ok(
      f.openRead(),
      headers: {
        HttpHeaders.contentTypeHeader:
            lookupMimeType(target) ?? 'application/octet-stream',
      },
    );
  }

  @Route.get('/api/packages/versions/new')
  Future<shelf.Response> getUploadUrl(shelf.Request req) async {
    return _okWithJson({
      'url': _resolveUrl(req, '/api/packages/versions/newUpload').toString(),
      'fields': {},
    });
  }

  @Route.post('/api/packages/versions/newUpload')
  Future<shelf.Response> upload(shelf.Request req) async {
    try {
      var uploader = await _getUploaderEmail(req);

      var contentType = req.headers['content-type'];
      if (contentType == null) throw 'invalid content type';

      var mediaType = MediaType.parse(contentType);
      var boundary = mediaType.parameters['boundary'];
      if (boundary == null) throw 'invalid boundary';

      var transformer = MimeMultipartTransformer(boundary);
      MimeMultipart? fileData;

      // The map below makes the runtime type checker happy.
      // https://github.com/dart-lang/pub-dev/blob/19033f8154ca1f597ef5495acbc84a2bb368f16d/app/lib/fake/server/fake_storage_server.dart#L74
      final stream = req.read().map((a) => a).transform(transformer);
      await for (var part in stream) {
        if (fileData != null) continue;
        fileData = part;
      }

      var bb = await fileData!.fold(
          BytesBuilder(), (BytesBuilder byteBuilder, d) => byteBuilder..add(d));
      var tarballBytes = bb.takeBytes();
      var tarBytes = GZipDecoder().decodeBytes(tarballBytes);
      var archive = TarDecoder().decodeBytes(tarBytes);
      ArchiveFile? pubspecArchiveFile;
      ArchiveFile? readmeFile;
      ArchiveFile? changelogFile;

      for (var file in archive.files) {
        if (file.name == 'pubspec.yaml') {
          pubspecArchiveFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'readme.md') {
          readmeFile = file;
          continue;
        }
        if (file.name.toLowerCase() == 'changelog.md') {
          changelogFile = file;
          continue;
        }
      }

      if (pubspecArchiveFile == null) {
        throw 'Did not find any pubspec.yaml file in upload. Aborting.';
      }

      var pubspecYaml = utf8.decode(pubspecArchiveFile.content);
      var pubspec = loadYamlAsMap(pubspecYaml)!;

      if (uploadValidator != null) {
        await uploadValidator!(pubspec, uploader);
      }

      // TODO: null
      var name = pubspec['name'] as String;
      var version = pubspec['version'] as String;

      var package = await metaStore.queryPackage(name);

      // Package already exists
      if (package != null) {
        if (package.private == false) {
          throw '$name is not a private package. Please upload it to https://pub.dev';
        }

        // Check uploaders
        if (package.uploaders?.contains(uploader) == false) {
          throw '$uploader is not an uploader of $name';
        }

        // Check duplicated version
        var duplicated = package.versions
            .firstWhereOrNull((item) => version == item.version);
        if (duplicated != null) {
          throw 'version invalid: $name@$version already exists.';
        }
      }

      // Upload package tarball to storage
      await packageStore.upload(name, version, tarballBytes);

      String? readme;
      String? changelog;
      if (readmeFile != null) {
        readme = utf8.decode(readmeFile.content);
      }
      if (changelogFile != null) {
        changelog = utf8.decode(changelogFile.content);
      }

      // Write package meta to database
      var unpubVersion = UnpubVersion(
        version,
        pubspec,
        pubspecYaml,
        uploader,
        readme,
        changelog,
        DateTime.now(),
      );
      await metaStore.addVersion(name, unpubVersion);

      // TODO: Upload docs
      return shelf.Response.found(
          _resolveUrl(req, '/api/packages/versions/newUploadFinish'));
    } on AuthException catch (e) {
      return _unauthorized(e.message);
    } catch (err) {
      return shelf.Response.found(_resolveUrl(
          req, '/api/packages/versions/newUploadFinish?error=$err'));
    }
  }

  @Route.get('/api/packages/versions/newUploadFinish')
  Future<shelf.Response> uploadFinish(shelf.Request req) async {
    var error = req.requestedUri.queryParameters['error'];
    if (error != null) {
      return _badRequest(error);
    }
    return _successMessage('Successfully uploaded package.');
  }

  @Route.post('/api/packages/<name>/uploaders')
  Future<shelf.Response> addUploader(shelf.Request req, String name) async {
    var body = await req.readAsString();
    var email = Uri.splitQueryString(body)['email']!; // TODO: null
    final String operatorEmail;
    try {
      operatorEmail = await _getUploaderEmail(req);
    } on AuthException catch (e) {
      return _unauthorized(e.message);
    }
    var package = await metaStore.queryPackage(name);

    if (package?.uploaders?.contains(operatorEmail) == false) {
      return _badRequest('no permission', status: HttpStatus.forbidden);
    }
    if (package?.uploaders?.contains(email) == true) {
      return _badRequest('email already exists');
    }

    await metaStore.addUploader(name, email);
    return _successMessage('uploader added');
  }

  @Route.delete('/api/packages/<name>/uploaders/<email>')
  Future<shelf.Response> removeUploader(
      shelf.Request req, String name, String email) async {
    email = Uri.decodeComponent(email);
    final String operatorEmail;
    try {
      operatorEmail = await _getUploaderEmail(req);
    } on AuthException catch (e) {
      return _unauthorized(e.message);
    }
    var package = await metaStore.queryPackage(name);

    // TODO: null
    if (package?.uploaders?.contains(operatorEmail) == false) {
      return _badRequest('no permission', status: HttpStatus.forbidden);
    }
    if (package?.uploaders?.contains(email) == false) {
      return _badRequest('email not uploader');
    }

    await metaStore.removeUploader(name, email);
    return _successMessage('uploader removed');
  }

  @Route.delete('/api/packages/<name>/versions/<version>')
  Future<shelf.Response> removeVersion(
      shelf.Request req, String name, String version) async {
    try {
      version = Uri.decodeComponent(version);
    } catch (err) {
      print(err);
    }

    final String operatorEmail;
    try {
      operatorEmail = await _getUploaderEmail(req);
    } on AuthException catch (e) {
      return _unauthorized(e.message);
    }
    var package = await metaStore.queryPackage(name);

    if (package == null) {
      return _badRequest('package not found', status: HttpStatus.notFound);
    }
    if (package.uploaders?.contains(operatorEmail) == false) {
      return _badRequest('no permission', status: HttpStatus.forbidden);
    }

    var packageVersion =
        package.versions.firstWhereOrNull((item) => item.version == version);
    if (packageVersion == null) {
      return _badRequest('version not found', status: HttpStatus.notFound);
    }
    if (package.versions.length == 1) {
      return _badRequest('cannot remove the last version of a package');
    }

    await metaStore.removeVersion(name, version);
    await packageStore.delete(name, version);
    await docStore?.delete(name, version);
    return _successMessage('version removed');
  }

  @Route.get('/webapi/packages')
  Future<shelf.Response> getPackages(shelf.Request req) async {
    var params = req.requestedUri.queryParameters;
    var size = int.tryParse(params['size'] ?? '') ?? 10;
    var page = int.tryParse(params['page'] ?? '') ?? 0;
    var sort = params['sort'] ?? 'download';
    var q = params['q'];

    String? keyword;
    String? uploader;
    String? dependency;

    if (q == null) {
    } else if (q.startsWith('email:')) {
      uploader = q.substring(6).trim();
    } else if (q.startsWith('dependency:')) {
      dependency = q.substring(11).trim();
    } else {
      keyword = q;
    }

    final result = await metaStore.queryPackages(
      size: size,
      page: page,
      sort: sort,
      keyword: keyword,
      uploader: uploader,
      dependency: dependency,
    );

    var data = ListApi(result.count, [
      for (var package in result.packages)
        if (_primaryVersion(package.versions) case var primary?)
          ListApiPackage(
            package.name,
            primary.pubspec['description'] as String?,
            getPackageTags(primary.pubspec),
            primary.version,
            package.updatedAt,
          )
    ]);

    return _okWithJson({'data': data.toJson()});
  }

  @Route.get('/packages/<name>.json')
  Future<shelf.Response> getPackageVersions(
      shelf.Request req, String name) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _badRequest('package not exists', status: HttpStatus.notFound);
    }

    var versions = package.versions.map((v) => v.version).toList();
    versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(b), semver.Version.parse(a));
    });

    return _okWithJson({
      'name': name,
      'versions': versions,
    });
  }

  @Route.get('/webapi/package/<name>/<version>')
  Future<shelf.Response> getPackageDetail(
      shelf.Request req, String name, String version) async {
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return _okWithJson({'error': 'package not exists'});
    }

    UnpubVersion? packageVersion;
    if (version == 'latest') {
      packageVersion = _primaryVersion(package.versions);
    } else {
      packageVersion =
          package.versions.firstWhereOrNull((item) => item.version == version);
    }
    if (packageVersion == null) {
      return _okWithJson({'error': 'version not exists'});
    }

    var versions = package.versions
        .map((v) => DetailViewVersion(v.version, v.createdAt))
        .toList();
    versions.sort((a, b) {
      return semver.Version.prioritize(
          semver.Version.parse(b.version), semver.Version.parse(a.version));
    });

    var pubspec = packageVersion.pubspec;
    List<String> authors;
    if (pubspec['author'] != null) {
      authors = RegExp(r'<(.*?)>')
          .allMatches(pubspec['author'])
          .map((match) => match.group(1))
          .nonNulls
          .toList();
    } else if (pubspec['authors'] != null) {
      authors = (pubspec['authors'] as List)
          .map((author) => RegExp(r'<(.*?)>').firstMatch(author)!.group(1))
          .nonNulls
          .toList();
    } else {
      authors = [];
    }

    var depMap =
        (pubspec['dependencies'] as Map? ?? {}).cast<String, dynamic>();
    var selfUri = Uri.parse(_resolveUrl(req, '/'));
    var dependencies = <DependencyView>[];
    for (var entry in depMap.entries) {
      dependencies.add(await resolveDependencyView(
        entry.key,
        entry.value,
        selfUri,
        (name) async => (await metaStore.queryPackage(name)) != null,
      ));
    }

    var data = WebapiDetailView(
      package.name,
      packageVersion.version,
      packageVersion.pubspec['description'] ?? '',
      packageVersion.pubspec['homepage'] ?? '',
      package.uploaders ?? [],
      packageVersion.createdAt,
      packageVersion.readme,
      packageVersion.changelog,
      versions,
      authors,
      dependencies,
      getPackageTags(packageVersion.pubspec),
      hasDocs: docStore != null,
    );

    return _okWithJson({'data': data.toJson()});
  }

  static bool _isPubDevHost(String host) =>
      host == 'pub.dev' || host == 'pub.dartlang.org';

  /// A normalized origin+path key used to decide whether a hosted dependency
  /// points at *this* server. Comparing only the host is not enough: the same
  /// hostname can serve different pub repositories on different ports or path
  /// prefixes (e.g. `http://localhost:8080` vs `http://localhost:4000`).
  static String _baseKey(Uri uri) {
    var path = uri.path;
    if (path.endsWith('/')) path = path.substring(0, path.length - 1);
    return '${uri.scheme}://${uri.host}:${uri.port}$path';
  }

  /// Builds a [DependencyView] for a single pubspec dependency entry,
  /// resolving where the package is actually hosted so the web UI can link
  /// to the right place (this server, pub.dev, or another hosted server).
  ///
  /// [spec] is the raw pubspec dependency value: a version string, or a map
  /// describing a `hosted`/`sdk`/`git`/`path` source.
  static Future<DependencyView> resolveDependencyView(
    String name,
    dynamic spec,
    Uri selfUri,
    Future<bool> Function(String name) isPublishedLocally,
  ) async {
    if (spec is Map) {
      // sdk dependencies: Flutter SDK packages link to the Flutter API docs
      // (matching pub.dev); other sdk sources have no pub page to link to.
      var sdk = spec['sdk'];
      if (sdk != null) {
        if (sdk == 'flutter') {
          return DependencyView(name, url: 'https://api.flutter.dev/');
        }
        return DependencyView(name);
      }

      // git/path dependencies have no pub page to link to.
      if (spec.containsKey('git') || spec.containsKey('path')) {
        return DependencyView(name);
      }

      var hosted = spec['hosted'];
      if (hosted != null) {
        // `hosted` may be a plain url string or a {name, url} map.
        String? url;
        var hostedName = name;
        if (hosted is String) {
          url = hosted;
        } else if (hosted is Map) {
          url = hosted['url'] as String?;
          hostedName = (hosted['name'] as String?) ?? name;
        }

        if (url != null) {
          var depUri = Uri.tryParse(url);
          var host = depUri?.host;
          if (depUri == null ||
              host == null ||
              host.isEmpty ||
              _baseKey(depUri) == _baseKey(selfUri)) {
            return DependencyView(name, internal: true);
          }
          if (_isPubDevHost(host)) {
            return DependencyView(name,
                url: 'https://pub.dev/packages/$hostedName');
          }
          var base = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
          return DependencyView(name, url: '$base/packages/$hostedName');
        }
      }
    }

    // Plain version string (default pub server). If this server hosts the
    // package, link internally; otherwise it comes from pub.dev.
    if (await isPublishedLocally(name)) {
      return DependencyView(name, internal: true);
    }
    return DependencyView(name, url: 'https://pub.dev/packages/$name');
  }

  /// The embedded web assets and their entity tags, computed on first use.
  /// Both are fixed for the life of the process, and the bundle is large
  /// enough that neither rendering nor hashing it belongs on a request path.
  String? _indexHtmlBody, _indexHtmlEtag;
  String? _mainDartJsBody, _mainDartJsEtag;

  static String _etagOf(String body) =>
      '"${sha1.convert(utf8.encode(body)).toString().substring(0, 16)}"';

  String get _mainDartJs => _mainDartJsBody ??= main_dart_js.content({});
  String get _mainDartJsTag => _mainDartJsEtag ??= _etagOf(_mainDartJs);

  /// The page, with the script reference stamped with the bundle's content
  /// hash.
  ///
  /// `no-cache` on `/main.dart.js` asks a browser to revalidate, but it is
  /// only a request, and anything sitting in front of this server — a CDN, a
  /// tunnel, a corporate proxy — may cache a plain `.js` url on its own
  /// terms and keep serving the previous release for hours. A url that
  /// changes with the content cannot be stale: the page itself is never
  /// cached, so it always points at the build that is actually running.
  String get _indexHtml => _indexHtmlBody ??= index_html
      .content({'APP_VERSION': version}).replaceFirst('src="main.dart.js"',
          'src="main.dart.js?v=${_mainDartJsTag.replaceAll('"', '')}"');

  String get _indexHtmlTag => _indexHtmlEtag ??= _etagOf(_indexHtml);

  /// Serves one of the embedded assets with revalidation.
  ///
  /// Their urls carry no version, so a browser left to its own devices will
  /// happily keep serving the bundle it downloaded before an upgrade — which
  /// looks exactly like the new build not working. `no-cache` makes it ask
  /// every time; the entity tag keeps that question cheap by answering 304
  /// when nothing changed.
  shelf.Response _staticAsset(
      shelf.Request req, String body, String etag, String contentType) {
    if (req.headers[HttpHeaders.ifNoneMatchHeader] == etag) {
      return shelf.Response.notModified(headers: {
        HttpHeaders.cacheControlHeader: 'no-cache',
        HttpHeaders.etagHeader: etag,
      });
    }
    return shelf.Response.ok(body, headers: {
      HttpHeaders.contentTypeHeader: contentType,
      HttpHeaders.cacheControlHeader: 'no-cache',
      HttpHeaders.etagHeader: etag,
    });
  }

  @Route.get('/')
  @Route.get('/packages')
  @Route.get('/packages/<name>')
  @Route.get('/packages/<name>/versions/<version>')
  Future<shelf.Response> indexHtml(shelf.Request req) async {
    return _staticAsset(
        req, _indexHtml, _indexHtmlTag, ContentType.html.mimeType);
  }

  @Route.get('/main.dart.js')
  Future<shelf.Response> mainDartJs(shelf.Request req) async {
    return _staticAsset(req, _mainDartJs, _mainDartJsTag, 'text/javascript');
  }

  @Route.get('/logo')
  Future<shelf.Response> logo(shelf.Request req) async {
    final uri = await resolveInPubPackageUri('src/static/logo.png');
    if (uri == null) return shelf.Response.notFound('Not found');
    final file = File(uri.toFilePath());
    if (!await file.exists()) return shelf.Response.notFound('Not found');
    return shelf.Response.ok(
      file.openRead(),
      headers: {HttpHeaders.contentTypeHeader: 'image/png'},
    );
  }

  String _getBadgeUrl(String label, String message, String color,
      Map<String, String> queryParameters) {
    var badgeUri = Uri.parse('https://img.shields.io/static/v1');
    return Uri(
        scheme: badgeUri.scheme,
        host: badgeUri.host,
        path: badgeUri.path,
        queryParameters: {
          'label': label,
          'message': message,
          'color': color,
          ...queryParameters,
        }).toString();
  }

  @Route.get('/badge/<type>/<name>')
  Future<shelf.Response> badge(
      shelf.Request req, String type, String name) async {
    var queryParameters = req.requestedUri.queryParameters;
    var package = await metaStore.queryPackage(name);
    if (package == null) {
      return shelf.Response.notFound('Not found');
    }

    switch (type) {
      case 'v':
        var latest = semver.Version.primary(package.versions
            .map((pv) => semver.Version.parse(pv.version))
            .toList());

        var color = latest.major == 0 ? 'orange' : 'blue';

        return shelf.Response.found(
            _getBadgeUrl('in_pub', latest.toString(), color, queryParameters));
      case 'd':
        return shelf.Response.found(_getBadgeUrl(
            'downloads', package.download.toString(), 'blue', queryParameters));
      default:
        return shelf.Response.notFound('Not found');
    }
  }
}

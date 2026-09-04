import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:in_pub/in_pub.dart';
import 'package:in_pub/src/auth/auth_middleware.dart'
    show bearerProvisionalContextKey, bearerPrincipalContextKey;

import 'auth/fake_provider.dart';
import 'auth/memory_auth_store.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// A credential that answers to no account on this server — the original
/// Google one, held by somebody who has never signed in here — may publish a
/// new version of a package whose uploader list already names it, because
/// that list bounds what it can reach. A brand-new package has no such list,
/// so nothing bounds it at all: without this, anyone holding any Google
/// account could fill a repository whose owner asked for authentication.
void main() {
  late _RecordingMetaStore metaStore;
  late App app;

  setUp(() {
    metaStore = _RecordingMetaStore();
    app = App(
      metaStore: metaStore,
      packageStore: _MemoryPackageStore(),
    );
  });

  /// A `dart pub publish` upload of [name], as the gate would hand it over.
  Future<shelf.Response> _publishTo(App target, String name,
      {required bool provisional}) {
    var pubspec = 'name: $name\nversion: 1.0.0\nenvironment:\n'
        "  sdk: '>=3.0.0 <4.0.0'\n";
    var archive = Archive()
      ..addFile(
          ArchiveFile('pubspec.yaml', pubspec.length, utf8.encode(pubspec)));
    var tarball =
        Uint8List.fromList(GZipEncoder().encode(TarEncoder().encode(archive))!);

    const boundary = 'unpubtestboundary';
    var head = utf8.encode('--$boundary\r\n'
        'content-disposition: form-data; name="file"; filename="p.tar.gz"\r\n'
        'content-type: application/octet-stream\r\n\r\n');
    var tail = utf8.encode('\r\n--$boundary--\r\n');

    return target.router.call(shelf.Request(
      'POST',
      Uri.parse('http://localhost:4000/api/packages/versions/newUpload'),
      headers: {
        HttpHeaders.contentTypeHeader:
            'multipart/form-data; boundary=$boundary',
      },
      body: Uint8List.fromList([...head, ...tarball, ...tail]),
      context: {
        bearerPrincipalContextKey: const AuthenticatedUser(
            id: 'google:old@example.org',
            email: 'old@example.org',
            displayName: 'old@example.org'),
        bearerProvisionalContextKey: provisional,
      },
    ));
  }

  Future<shelf.Response> publish(String name, {required bool provisional}) =>
      _publishTo(app, name, provisional: provisional);

  /// `upload` always redirects to `newUploadFinish`, carrying any failure in
  /// the query string, so the outcome is read from there rather than from the
  /// status.
  String? errorIn(shelf.Response res) {
    expect(res.statusCode, HttpStatus.found);
    return Uri.parse(res.headers[HttpHeaders.locationHeader]!)
        .queryParameters['error'];
  }

  test('a provisional publisher cannot create a new package', () async {
    var res = await publish('brand_new', provisional: true);

    expect(errorIn(res), contains('no account on this server'));
    expect(metaStore.added, isEmpty,
        reason: 'the version must not be recorded either');
  });

  test('a known publisher can', () async {
    var res = await publish('brand_new', provisional: false);

    expect(errorIn(res), isNull);
    expect(metaStore.added, contains('brand_new'));
  });

  test('the uploader list is matched without regard to case', () async {
    // The identity provider's spelling of an address and the one recorded by
    // an earlier publish need not agree: Google reports a folded address, an
    // OIDC provider may report `Alice@Example.org`. A literal comparison
    // refused the same person with "is not an uploader", and nothing on
    // screen said the two spellings differed.
    metaStore.existing['established'] = UnpubPackage(
      'established',
      const [],
      true,
      const ['OLD@Example.org'],
      DateTime.now(),
      DateTime.now(),
      null,
    );

    expect(errorIn(await publish('established', provisional: false)), isNull);
  });

  test('a provisional publisher can still publish to a package it uploads',
      () async {
    // This is every publisher from before authentication existed, and the
    // whole point of leaving the credential working.
    metaStore.existing['established'] = UnpubPackage(
      'established',
      const [],
      true,
      const ['old@example.org'],
      DateTime.now(),
      DateTime.now(),
      null,
    );

    var res = await publish('established', provisional: true);

    expect(errorIn(res), isNull);
    expect(metaStore.added, contains('established'));
  });
  test('a refusal cannot be smuggled out of the error redirect', () async {
    // The package name is read verbatim from the uploaded pubspec and lands
    // in the query string of the redirect. Interpolated, `foo#x` made
    // everything after the `#` a fragment, so the finish route saw no error
    // and reported a refused publish as a success.
    var res = await publish('foo#x', provisional: true);

    expect(res.statusCode, HttpStatus.found);
    var location = Uri.parse(res.headers[HttpHeaders.locationHeader]!);
    expect(location.fragment, isEmpty);
    expect(location.queryParameters['error'], contains('no account'));
    expect(metaStore.added, isEmpty);
  });
  test('removing an uploader spelled differently actually removes them',
      () async {
    // The permission check folds case but the store removes by exact match,
    // so a mismatched spelling passed the guard, removed nothing, and
    // answered "uploader removed" while that person kept publishing.
    metaStore.existing['established'] = UnpubPackage(
      'established',
      const [],
      true,
      const ['alice@example.org'],
      DateTime.now(),
      DateTime.now(),
      null,
    );

    var res = await app.router.call(shelf.Request(
      'DELETE',
      Uri.parse('http://localhost:4000/api/packages/established/uploaders/'
          '${Uri.encodeComponent('Alice@Example.org')}'),
      context: {
        bearerPrincipalContextKey: const AuthenticatedUser(
            id: 'u', email: 'alice@example.org', displayName: 'A'),
        bearerProvisionalContextKey: false,
      },
    ));

    expect(res.statusCode, HttpStatus.ok);
    expect(metaStore.removed, contains('alice@example.org'),
        reason: 'the stored spelling is what the store removes by');
  });

  test('publishing under a different spelling does not add a second uploader',
      () async {
    // `addVersion` adds the uploader with `addToSet`, which compares
    // literally. The permission check treats the two spellings as one
    // person, so appending a second entry left a list where removing one
    // spelling silently left the other publishing.
    metaStore.existing['established'] = UnpubPackage(
      'established',
      const [],
      true,
      const ['old@example.org'],
      DateTime.now(),
      DateTime.now(),
      null,
    );

    var res = await _publishTo(
        App(
          metaStore: metaStore,
          packageStore: _MemoryPackageStore(),
          overrideUploaderEmail: 'OLD@Example.org',
        ),
        'established',
        provisional: false);

    expect(errorIn(res), isNull);
    expect(metaStore.recordedUploaders, ['old@example.org'],
        reason: 'the spelling the package already holds');
  });

  group('a package with no uploader list', () {
    // Nobody is recorded as owning it. Reading that as "no objection" let
    // any caller who could authenticate at all take it over.
    setUp(() {
      metaStore.existing['orphaned'] = UnpubPackage(
        'orphaned',
        [
          UnpubVersion('1.0.0', const {}, '', 'someone@example.org', null, null,
              DateTime.now())
        ],
        true,
        null,
        DateTime.now(),
        DateTime.now(),
        null,
      );
    });

    shelf.Request as(String method, String path, {String? body}) =>
        shelf.Request(
          method,
          Uri.parse('http://localhost:4000$path'),
          body: body,
          context: {
            bearerPrincipalContextKey: const AuthenticatedUser(
                id: 'u', email: 'stranger@example.org', displayName: 'S'),
            bearerProvisionalContextKey: false,
          },
        );

    test('cannot have an uploader added to it', () async {
      var res = await app.router.call(as(
          'POST', '/api/packages/orphaned/uploaders',
          body: 'email=stranger@example.org'));
      expect(res.statusCode, HttpStatus.forbidden);
    });

    test('cannot have its versions deleted', () async {
      var res = await app.router
          .call(as('DELETE', '/api/packages/orphaned/versions/1.0.0'));
      expect(res.statusCode, HttpStatus.forbidden);
    });
  });

  test('adding an uploader to a package that does not exist says so', () async {
    // The store's update matches no document, so answering "uploader added"
    // reported a publish permission that was never granted.
    var res = await app.router.call(shelf.Request(
      'POST',
      Uri.parse('http://localhost:4000/api/packages/nope/uploaders'),
      body: 'email=someone@example.org',
      context: {
        bearerPrincipalContextKey: const AuthenticatedUser(
            id: 'u', email: 'someone@example.org', displayName: 'S'),
        bearerProvisionalContextKey: false,
      },
    ));

    expect(res.statusCode, HttpStatus.notFound);
  });

  test('a refused publish does not run the embedder\'s validator', () async {
    // The decision needs nothing the hook produces, and running it first
    // meant a publish about to be refused still triggered whatever the host
    // does there — audit rows, a policy call, a name reservation.
    var validated = <String>[];
    var guarded = App(
      metaStore: metaStore,
      packageStore: _MemoryPackageStore(),
      uploadValidator: (pubspec, uploader) async =>
          validated.add(pubspec['name'] as String),
    );

    var res = await _publishTo(guarded, 'brand_new', provisional: true);

    expect(errorIn(res), contains('no account on this server'));
    expect(validated, isEmpty);
  });

  group('with the pub API left open', () {
    // `--auth` without `--auth-protect-pub-api`, which is the default. The
    // gate steps aside for `/api/**` entirely, so every rule about what the
    // legacy Google credential may do has to hold here too — enforcing it
    // only in the middleware left it unenforced on most deployments.
    late App gatelessApp;

    setUp(() {
      gatelessApp = App(
        metaStore: metaStore,
        packageStore: _MemoryPackageStore(),
        auth: AuthService(
          config: AuthConfig(
            enabled: true,
            issuer: 'https://id.example.org',
            clientId: 'in-pub',
            clientSecret: 'secret',
            publicUrl: Uri.parse('https://pub.example.org'),
            secret: utf8.encode('a-test-signing-secret-long-enough-here!!'),
          ),
          store: MemoryAuthStore(),
          provider: FakeIdentityProvider(),
          legacyResolver: _FakeGoogle(),
        ),
      );
    });

    test('a Google credential cannot delete a published version', () async {
      metaStore.existing['established'] = UnpubPackage(
        'established',
        const [],
        true,
        const ['old@example.org'],
        DateTime.now(),
        DateTime.now(),
        null,
      );

      var res = await gatelessApp.router.call(shelf.Request(
        'DELETE',
        Uri.parse(
            'http://localhost:4000/api/packages/established/versions/1.0.0'),
        headers: {HttpHeaders.authorizationHeader: 'Bearer legacy-ok'},
      ));

      expect(res.statusCode, HttpStatus.unauthorized);
    });

    test('but it can still publish', () async {
      var res = await gatelessApp.router.call(shelf.Request(
        'GET',
        Uri.parse('http://localhost:4000/api/packages/versions/new'),
        headers: {HttpHeaders.authorizationHeader: 'Bearer legacy-ok'},
      ));

      expect(res.statusCode, isNot(HttpStatus.unauthorized));
    });

    test('and App never builds a Google resolver of its own', () async {
      // `resolveGoogleBearer` is documented as reachable only with
      // authentication off — with it on, the auth layer resolves every
      // credential and its resolver is the one that answers. The guard asked
      // whether *that* resolver existed, which is true exactly when this
      // path is unreachable, so calling it built a second HTTP client with a
      // second answer cache to re-ask a question already answered.
      //
      // The proxy points nowhere on purpose: a resolver built here would
      // reach for the network and report the identity service as
      // unavailable, so answering at all is the proof that none was built.
      var app = App(
        metaStore: metaStore,
        packageStore: _MemoryPackageStore(),
        googleapisProxy: 'http://127.0.0.1:1',
        auth: AuthService(
          config: AuthConfig(
            enabled: true,
            issuer: 'https://id.example.org',
            clientId: 'in-pub',
            clientSecret: 'secret',
            publicUrl: Uri.parse('https://pub.example.org'),
            secret: utf8.encode('a-test-signing-secret-long-enough-here!!'),
          ),
          store: MemoryAuthStore(),
          provider: FakeIdentityProvider(),
          legacyResolver: _FakeGoogle(),
        ),
      );
      addTearDown(app.close);

      expect(await app.resolveGoogleBearer('legacy-ok'), isNull);
    });
  });
}

class _RecordingMetaStore extends MetaStore {
  final existing = <String, UnpubPackage>{};
  final added = <String>[];

  @override
  Future<UnpubPackage?> queryPackage(String name) async => existing[name];

  final removed = <String>[];

  final recordedUploaders = <String?>[];

  @override
  Future<void> addVersion(String name, UnpubVersion version) async {
    added.add(name);
    recordedUploaders.add(version.uploader);
  }

  @override
  Future<void> removeUploader(String name, String email) async =>
      removed.add(email);

  Never _unused() => throw UnimplementedError('not used by these tests');

  @override
  Future<void> addUploader(String name, String email) => _unused();
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

class _MemoryPackageStore extends PackageStore {
  @override
  Stream<List<int>> download(String name, String version) =>
      const Stream.empty();
  @override
  Future<void> upload(String name, String version, List<int> content) async {}
  @override
  Future<void> delete(String name, String version) async {}
}

/// Stands in for the original Google credential.
class _FakeGoogle extends GoogleCredentialResolver {
  @override
  Future<String?> resolve(String token) async =>
      token == 'legacy-ok' ? 'old@example.org' : null;
}

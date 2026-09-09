import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:in_pub/in_pub.dart';
import 'package:test/test.dart';

import 'auth/fake_provider.dart';
import 'auth/memory_auth_store.dart';

/// `/health` is what a monitor polls, and it is reachable without signing in.
///
/// Both halves matter. A check that cannot tell a wedged database from a
/// working one is not worth running, and an endpoint that anybody can poll
/// on a schedule must not describe what the repository holds — that is a
/// feed, not a status.
void main() {
  late HttpServer server;
  HttpServer? started;
  late _ProbeStore store;

  Future<void> serve({bool auth = false}) async {
    await started?.close(force: true);
    server = started = await App(
      metaStore: store,
      packageStore: _UnusedPackageStore(),
      healthProbeTimeout: const Duration(milliseconds: 200),
      auth: auth
          ? AuthService(
              config: AuthConfig(
                enabled: true,
                issuer: 'https://id.example.org',
                clientId: 'in-pub',
                clientSecret: 'secret',
                publicUrl: Uri.parse('http://127.0.0.1:4000'),
                secret:
                    utf8.encode('a-test-signing-secret-of-sufficient-length!!'),
              ),
              store: MemoryAuthStore(),
              provider: FakeIdentityProvider(),
              googleAuth: false,
            )
          : null,
    ).serve('127.0.0.1', 0);
  }

  setUp(() => store = _ProbeStore());
  tearDown(() => started?.close(force: true));

  Future<http.Response> health() =>
      http.get(Uri.parse('http://127.0.0.1:${server.port}/health'));

  Map<String, dynamic> body(http.Response res) =>
      json.decode(res.body) as Map<String, dynamic>;

  Map<String, dynamic> database(http.Response res) =>
      (body(res)['checks'] as Map<String, dynamic>)['database']
          as Map<String, dynamic>;

  group('with authentication off', () {
    setUp(() => serve());

    test('a store that answers is a healthy server', () async {
      var res = await health();

      expect(res.statusCode, HttpStatus.ok);
      expect(body(res)['status'], 'ok');
      expect(database(res)['status'], 'ok');
      expect(database(res)['latencyMs'], isA<int>());
      expect(store.probes, 1);
    });

    test('answers with the status and nothing about the repository', () async {
      // Every key at every level, rather than a list of fields that must be
      // absent: what has to hold is that nothing describing the packages
      // here can be read off a public endpoint, and a field added later
      // should have to be argued for in this test rather than slip in
      // somewhere the assertions do not reach.
      var res = await health();

      expect(body(res).keys, ['status', 'checks']);
      expect((body(res)['checks'] as Map).keys, ['database']);
      expect(database(res).keys, ['status', 'latencyMs']);
    });

    test('a failing check says no more than a passing one', () async {
      // The path that has something to say: it carries the reason the store
      // could not be reached, which is the one place a leak would be easy.
      store.failure = const _StoreDown();

      var res = await health();

      expect(body(res).keys, ['status', 'checks']);
      expect(database(res).keys, ['status', 'error']);
    });

    test('a store that throws is a 503, not a 500', () async {
      // The distinction a monitor acts on: this server is running and its
      // database is not, which is neither "up" nor an unhandled error.
      store.failure = const _StoreDown();

      var res = await health();

      expect(res.statusCode, HttpStatus.serviceUnavailable);
      expect(body(res)['status'], 'error');
      expect(database(res)['status'], 'error');
      expect(database(res).containsKey('latencyMs'), isFalse);
    });

    test('a store that hangs fails the check rather than the request',
        () async {
      // Left unbounded this is the failure that reads as a network problem:
      // the probe never comes back and the monitor blames its own timeout.
      store.hang = true;

      var res = await health();

      expect(res.statusCode, HttpStatus.serviceUnavailable);
      expect(database(res)['error'], 'TimeoutException');
    });

    test('the failure is named by type, never by its message', () async {
      // A driver error spells out the connection string it failed on, and
      // this endpoint is read by anyone who asks.
      store.failure =
          const _StoreDown('mongodb://admin:hunter2@db.internal:27017');

      var res = await health();

      expect(database(res)['error'], '_StoreDown');
      expect(res.body, isNot(contains('hunter2')));
      expect(res.body, isNot(contains('db.internal')));
    });

    test('is not served from a cache', () async {
      var res = await health();

      expect(res.headers[HttpHeaders.cacheControlHeader], 'no-store');
    });
  });

  group('with authentication on', () {
    setUp(() => serve(auth: true));

    test('answers without a session', () async {
      var res = await health();

      expect(res.statusCode, HttpStatus.ok);
      expect(body(res)['status'], 'ok');
      expect(database(res)['status'], 'ok');
    });

    test('answers the same as it does with authentication off', () async {
      // The gate resolves no credential for a public route, so this handler
      // cannot tell who is asking; one answer for everybody is the only
      // thing it can honestly give.
      var res = await health();

      expect(body(res).keys, ['status', 'checks']);
      expect(database(res).keys, ['status', 'latencyMs']);
    });

    test('a store that is down is still a 503', () async {
      store.failure = const _StoreDown();

      var res = await health();

      expect(res.statusCode, HttpStatus.serviceUnavailable);
      expect(body(res)['status'], 'error');
    });
  });
}

/// A metadata store whose health probe is scripted.
class _ProbeStore extends MetaStore {
  Object? failure;
  bool hang = false;
  int probes = 0;

  @override
  Future<void> checkHealth() async {
    probes++;
    if (hang) return Completer<void>().future;
    if (failure case var e?) throw e;
  }

  Never _unused() => throw UnimplementedError('not used by these tests');

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

class _StoreDown implements Exception {
  final String detail;

  const _StoreDown([this.detail = 'connection closed']);

  @override
  String toString() => 'Store down: $detail';
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

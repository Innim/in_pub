import 'package:in_pub/in_pub.dart';
import 'package:in_pub/unpub_api/lib/models.dart';
import 'package:test/test.dart';

/// These are pure unit tests for [App.resolveDependencyView] — the logic that
/// decides where a package's dependency link should point (this server,
/// pub.dev, another hosted server, the Flutter API docs, or nowhere). They do
/// not touch MongoDB or the network: the "is this package published here?"
/// check is provided as a callback.
void main() {
  const selfHost = 'pub.mycompany.com';
  final selfUri = Uri.parse('https://$selfHost');

  // Callbacks for the plain-version-string ("default pub server") branch.
  Future<bool> localHas(String _) async => true;
  Future<bool> localMissing(String _) async => false;

  Future<DependencyView> resolve(dynamic spec,
          {String name = 'foo', bool local = false, Uri? self}) =>
      App.resolveDependencyView(
          name, spec, self ?? selfUri, local ? localHas : localMissing);

  group('plain version string', () {
    test('links internally when published on this server', () async {
      var dep = await resolve('^1.0.0', local: true);
      expect(dep.name, 'foo');
      expect(dep.internal, isTrue);
      expect(dep.url, isNull);
    });

    test('links to pub.dev when not published on this server', () async {
      var dep = await resolve('^1.0.0', local: false);
      expect(dep.internal, isFalse);
      expect(dep.url, 'https://pub.dev/packages/foo');
    });

    test('empty constraint is treated as a plain string', () async {
      var dep = await resolve('', local: false);
      expect(dep.url, 'https://pub.dev/packages/foo');
    });
  });

  group('hosted', () {
    test('same host as this server links internally', () async {
      var dep = await resolve({
        'hosted': {'name': 'foo', 'url': 'https://$selfHost'},
        'version': '^1.0.0',
      });
      expect(dep.internal, isTrue);
      expect(dep.url, isNull);
    });

    test('pub.dev host links to pub.dev', () async {
      var dep = await resolve({
        'hosted': {'name': 'foo', 'url': 'https://pub.dev'},
        'version': '^1.0.0',
      });
      expect(dep.internal, isFalse);
      expect(dep.url, 'https://pub.dev/packages/foo');
    });

    test('legacy pub.dartlang.org host links to pub.dev', () async {
      var dep = await resolve({
        'hosted': {'name': 'foo', 'url': 'https://pub.dartlang.org'},
      });
      expect(dep.url, 'https://pub.dev/packages/foo');
    });

    test('same host but different port is treated as external', () async {
      var dep = await resolve(
        {
          'hosted': {'name': 'foo', 'url': 'http://localhost:8080'},
        },
        self: Uri.parse('http://localhost:4000'),
      );
      expect(dep.internal, isFalse);
      expect(dep.url, 'http://localhost:8080/packages/foo');
    });

    test('same host but different path prefix is treated as external',
        () async {
      var dep = await resolve(
        {
          'hosted': {'name': 'foo', 'url': 'https://$selfHost/repo-b'},
        },
        self: Uri.parse('https://$selfHost/repo-a'),
      );
      expect(dep.internal, isFalse);
      expect(dep.url, 'https://$selfHost/repo-b/packages/foo');
    });

    test('same origin with matching port links internally', () async {
      var dep = await resolve(
        {
          'hosted': {'name': 'foo', 'url': 'http://localhost:4000'},
        },
        self: Uri.parse('http://localhost:4000'),
      );
      expect(dep.internal, isTrue);
      expect(dep.url, isNull);
    });

    test('third-party host links to that server package page', () async {
      var dep = await resolve({
        'hosted': {'name': 'foo', 'url': 'https://pub.other.com'},
        'version': '^1.0.0',
      });
      expect(dep.internal, isFalse);
      expect(dep.url, 'https://pub.other.com/packages/foo');
    });

    test('trailing slash in host url is not doubled', () async {
      var dep = await resolve({
        'hosted': {'name': 'foo', 'url': 'https://pub.other.com/'},
      });
      expect(dep.url, 'https://pub.other.com/packages/foo');
    });

    test('shorthand string form (url only) is supported', () async {
      var dep = await resolve({
        'hosted': 'https://pub.other.com',
        'version': '^1.0.0',
      });
      expect(dep.url, 'https://pub.other.com/packages/foo');
    });

    test('uses the hosted name, not the dependency key, in the url', () async {
      var dep = await resolve(
        {
          'hosted': {'name': 'real_name', 'url': 'https://pub.other.com'},
        },
        name: 'alias',
      );
      // The visible label stays the dependency key; only the link target uses
      // the hosted name.
      expect(dep.name, 'alias');
      expect(dep.url, 'https://pub.other.com/packages/real_name');
    });
  });

  group('sdk', () {
    test('flutter links to the Flutter API docs', () async {
      var dep = await resolve({'sdk': 'flutter'}, name: 'flutter');
      expect(dep.name, 'flutter');
      expect(dep.internal, isFalse);
      expect(dep.url, 'https://api.flutter.dev/');
    });

    test('non-flutter sdk is not linkable', () async {
      var dep = await resolve({'sdk': 'dart'}, name: 'some_dart_sdk_pkg');
      expect(dep.internal, isFalse);
      expect(dep.url, isNull);
    });
  });

  group('non-hosted sources are not linkable', () {
    test('git', () async {
      var dep = await resolve({
        'git': {'url': 'https://github.com/foo/bar.git'},
      });
      expect(dep.internal, isFalse);
      expect(dep.url, isNull);
    });

    test('path', () async {
      var dep = await resolve({'path': '../bar'});
      expect(dep.internal, isFalse);
      expect(dep.url, isNull);
    });
  });
}

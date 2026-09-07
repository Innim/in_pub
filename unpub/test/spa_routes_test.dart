import 'dart:io';

import 'package:in_pub/unpub_api/lib/spa_routes.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The shell routes of the web UI are declared once, in `SpaRoutePaths`, and
/// read by three things that a running server cannot compare for itself:
///
///  * the `@Route.get` annotations on `App.indexHtml`, which a code
///    generator turns into `lib/src/app.g.dart` — an annotation argument has
///    to be a compile-time constant, so the router cannot loop over a list;
///  * `App.indexHtml`'s gate, through `authOnlyRoutes`, which is
///    `SpaRoutePaths.authOnly` itself and so cannot drift;
///  * `unpub_web/lib/src/routes.dart`, in a separate package, which names a
///    component per route.
///
/// The first and the last are checked here by reading the two files. That is
/// blunt, but the alternative is what this replaces: three lists kept in
/// step by hand, where a route added to the web application and missed in
/// the annotations shipped a page whose first request 404s, and one added to
/// the annotations alone was a link the application could not render.
///
/// `app.g.dart` is not a stand-in for the router: it *is* the router, the
/// generator's own record of the strings it resolved those constants to. If
/// it and the shared list disagree, the server and the shared list disagree.
void main() {
  final root = _repoRoot();
  final declared = _declaredConstants(root);
  final listed = _membersOfAll(root);

  group('the shared shell-route list', () {
    test('is what these tests actually read', () {
      // Everything below compares text against `SpaRoutePaths`. If the
      // parsing quietly stopped matching, the comparisons would pass on
      // nothing at all, so tie the two together first.
      expect(listed, isNotEmpty, reason: 'SpaRoutePaths.all parsed as empty');
      expect(
        [for (var name in listed) declared[name]],
        SpaRoutePaths.all,
        reason: 'the parsed declaration and the compiled one disagree, which '
            'means the parsing below is looking at the wrong thing',
      );
    });

    test('has no auth-only route that is not a route', () {
      expect(SpaRoutePaths.authOnly, everyElement(isIn(SpaRoutePaths.all)));
    });

    test('is written in the server router\'s syntax', () {
      // `clientRoutePath` assumes it, and the annotations carry it
      // literally.
      expect(SpaRoutePaths.all, everyElement(startsWith('/')));
      expect(SpaRoutePaths.all, isNot(contains(matches(':'))));
    });
  });

  group('the generated server router', () {
    // Read from the generator's output rather than the annotations, because
    // the value of `@Route.get(SpaRoutePaths.detail)` is whatever the
    // generator resolved that constant to — and that resolution is the part
    // worth checking.
    final served = _shellRoutesInGeneratedRouter(root);

    test('serves the shell somewhere', () {
      expect(served, isNotEmpty,
          reason: 'no `service.indexHtml` route found in app.g.dart; either '
              'the handler was renamed or the generator output changed shape');
    });

    test('serves the shell at exactly the shared shell routes', () {
      expect(
        served,
        SpaRoutePaths.all.toSet(),
        reason: 'add or remove a `@Route.get(SpaRoutePaths...)` on '
            '`App.indexHtml` and run `dart run build_runner build`, or fix '
            'SpaRoutePaths.all — one of the two was changed without the '
            'other, and a shell route the router does not serve is a 404 on '
            'a pasted link',
      );
    });
  });

  group('the web application', () {
    final wired = _routesWiredInWebApp(root);

    test('wires a component to something', () {
      expect(wired, isNotEmpty,
          reason: 'no `SpaRoutePaths.x:` keys found in '
              'unpub_web/lib/src/routes.dart; the `_components` map was '
              'renamed or restructured');
    });

    test('wires a component to exactly the shared shell routes', () {
      expect(
        wired,
        listed.toSet(),
        reason: 'unpub_web/lib/src/routes.dart and SpaRoutePaths.all '
            'disagree; a route the application renders and the server does '
            'not serve is a 404 on a reload, and one the server serves and '
            'the application does not render is a blank page',
      );
    });
  });

  group('the client-side spelling of a route', () {
    test('drops the leading slash and marks parameters with a colon', () {
      expect(clientRoutePath(SpaRoutePaths.home), '');
      expect(clientRoutePath(SpaRoutePaths.list), 'packages');
      expect(clientRoutePath(SpaRoutePaths.account), 'account');
      expect(clientRoutePath(SpaRoutePaths.detail), 'packages/:name');
      expect(clientRoutePath(SpaRoutePaths.detailVersion),
          'packages/:name/versions/:version');
    });
  });
}

/// The directory holding both packages.
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 5; i++) {
    if (File(p.join(dir.path, 'unpub', 'lib', 'src', 'app.g.dart'))
            .existsSync() &&
        File(p.join(dir.path, 'unpub_web', 'lib', 'src', 'routes.dart'))
            .existsSync()) {
      return dir;
    }
    if (dir.parent.path == dir.path) break;
    dir = dir.parent;
  }
  throw StateError(
      'neither ${Directory.current.path} nor any parent of it holds both '
      'unpub/ and unpub_web/; these tests compare the two packages and '
      'cannot run against only one of them');
}

String _read(Directory root, List<String> parts) =>
    File(p.joinAll([root.path, ...parts])).readAsStringSync();

/// The `static const name = '/path';` declarations of `SpaRoutePaths`.
Map<String, String> _declaredConstants(Directory root) {
  final source =
      _read(root, ['unpub', 'lib', 'unpub_api', 'lib', 'spa_routes.dart']);
  return {
    for (var m in RegExp(r"static const (\w+) = '([^']*)';").allMatches(source))
      m.group(1)!: m.group(2)!,
  };
}

/// The constants `SpaRoutePaths.all` lists, in order.
List<String> _membersOfAll(Directory root) {
  final source =
      _read(root, ['unpub', 'lib', 'unpub_api', 'lib', 'spa_routes.dart']);
  final body = RegExp(r'static const all = <String>\[(.*?)\];', dotAll: true)
      .firstMatch(source);
  if (body == null) {
    throw StateError('SpaRoutePaths.all is no longer a `<String>[...]` '
        'literal, so these tests cannot read the names it lists');
  }
  return [
    for (var m
        in RegExp(r'^\s*(\w+),', multiLine: true).allMatches(body.group(1)!))
      m.group(1)!,
  ];
}

/// The paths the generated router answers with `App.indexHtml`.
Set<String> _shellRoutesInGeneratedRouter(Directory root) {
  final source = _read(root, ['unpub', 'lib', 'src', 'app.g.dart']);
  return {
    for (var m in RegExp(
            r"router\.add\(\s*'GET',\s*r?'([^']*)',\s*service\.indexHtml\b")
        .allMatches(source))
      m.group(1)!,
  };
}

/// The constants `unpub_web` gives a component to.
Set<String> _routesWiredInWebApp(Directory root) {
  final source = _read(root, ['unpub_web', 'lib', 'src', 'routes.dart']);
  final map = RegExp(
          r'_components = <String, ComponentFactory<Object>>\{'
          r'(.*?)\n  \};',
          dotAll: true)
      .firstMatch(source);
  if (map == null) {
    throw StateError('the `_components` map of unpub_web/lib/src/routes.dart '
        'is no longer where these tests look for it');
  }
  return {
    for (var m in RegExp(r'SpaRoutePaths\.(\w+)\s*:').allMatches(map.group(1)!))
      m.group(1)!,
  };
}

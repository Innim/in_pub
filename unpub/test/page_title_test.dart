import 'package:in_pub/src/static/index.html.dart' as index_html;
import 'package:in_pub/unpub_api/lib/page_title.dart';
import 'package:test/test.dart';

/// The browser tab's title is written in two places that cannot see each
/// other: the shell's `<title>`, served before any script runs, and the web
/// application, which renames the tab on every navigation. Both read
/// [appTitle], and this checks that they still do — a shell that lost the
/// template variable would show a blank tab until the bundle loaded, and one
/// that went back to a literal name would say something else than the
/// application does the moment the repository is renamed.
void main() {
  group('pageTitle', () {
    test('puts the page first and the repository after it', () {
      // pub.dev's shape. What differs between two open tabs has to come
      // first, because that is the part a tab strip has room for.
      expect(pageTitle('my_package'), 'my_package | in_pub');
      expect(pageTitle('my_package 1.2.3'), 'my_package 1.2.3 | in_pub');
    });

    test('is the repository alone for a page that names nothing', () {
      // The home page is the repository itself; `in_pub | in_pub` would be
      // the same word twice.
      expect(pageTitle(), appTitle);
      expect(pageTitle(null), appTitle);
      expect(pageTitle(''), appTitle);
    });
  });

  test('the served shell is titled with the same name', () {
    // Through the generated source rather than the template it came from:
    // this is what a browser is actually sent. `app.dart` passes `appTitle`
    // under this key.
    expect(
      index_html.content({'APP_TITLE': appTitle}),
      contains('<title>$appTitle</title>'),
    );
  });
}

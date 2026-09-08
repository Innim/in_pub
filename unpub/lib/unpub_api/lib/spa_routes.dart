/// The shell routes of the single-page web application.
///
/// This is the one declaration of that list. Three things have to agree
/// about it and they live in different packages, so it is kept here, in the
/// small package both the server and the web UI already depend on:
///
///  * the server's router — the `@Route.get` annotations on `App.indexHtml`
///    reference these constants by name, so the generated router serves the
///    shell at every one of them. Opening a route directly, as a pasted link
///    or a reload does, reaches the router rather than the application, and
///    an address the router does not know comes back "not found";
///  * the server's gate — [authOnly] names the routes that only mean
///    anything once `--auth` is on. Serving one otherwise gives a page whose
///    very first request goes to an endpoint that is not routed;
///  * the web UI — `unpub_web/lib/src/routes.dart` builds its `RoutePath`s
///    and its `RouteDefinition`s from [all], so a route the client can
///    navigate to is by construction a route the server serves.
///
/// `unpub/test/spa_routes_test.dart` checks all three against this list, so
/// a route added to one of them and forgotten in the others fails the suite
/// rather than shipping.
///
/// The paths are written in the server router's syntax, `<name>` for a
/// parameter, because that is the one an annotation has to carry literally.
/// [clientRoutePath] rewrites one into the syntax the client-side router
/// uses.
class SpaRoutePaths {
  SpaRoutePaths._();

  static const home = '/';
  static const account = '/account';
  static const admin = '/admin';
  static const list = '/packages';
  static const detailVersion = '/packages/<name>/versions/<version>';
  static const detail = '/packages/<name>';

  /// Every shell route.
  ///
  /// The order is the client-side router's: it tries these in turn and stops
  /// at the first match, so `detailVersion` has to come before `detail`,
  /// whose parameter would otherwise swallow the version segment. The
  /// server's router anchors each pattern at both ends and is indifferent to
  /// the order.
  static const all = <String>[
    home,
    account,
    admin,
    list,
    detailVersion,
    detail,
  ];

  /// The routes that exist only on a server started with `--auth`.
  ///
  /// A subset of [all]; the gate in `App.indexHtml` answers "not found" for
  /// these when authentication is off.
  static const authOnly = <String>{account, admin};
}

/// [route] written in the syntax the client-side router uses.
///
/// The two differ in two details and nothing else: the client's paths are
/// relative, so they carry no leading slash, and they mark a parameter with
/// a leading colon rather than angle brackets.
String clientRoutePath(String route) {
  final relative = route.startsWith('/') ? route.substring(1) : route;
  return relative.replaceAllMapped(
      RegExp(r'<([^>]+)>'), (match) => ':${match.group(1)}');
}

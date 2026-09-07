import 'package:ngdart/angular.dart' show ComponentFactory;
import 'package:ngrouter/angular_router.dart';
import 'package:unpub_api/spa_routes.dart';

import 'home_component.template.dart' as home_template;
import 'list_component.template.dart' as list_template;
import 'detail_component.template.dart' as detail_template;
import 'account_component.template.dart' as account_template;
import 'admin_component.template.dart' as admin_template;
// import 'not_found_component.template.dart' as not_found_template;

/// The client-side address of each shell route.
///
/// Built from [SpaRoutePaths], which the server's router and its
/// authentication gate are built from too, so a route this application can
/// navigate to is a route the server serves. Nothing below names a path of
/// its own.
class RoutePaths {
  RoutePaths._();

  static final _byRoute = <String, RoutePath>{
    for (final route in SpaRoutePaths.all)
      route: RoutePath(path: clientRoutePath(route)),
  };

  /// The client-side path of the shared route [route].
  static RoutePath of(String route) => _byRoute[route]!;

  static final home = of(SpaRoutePaths.home);
  static final list = of(SpaRoutePaths.list);
  static final detail = of(SpaRoutePaths.detail);
  static final detailVersion = of(SpaRoutePaths.detailVersion);
  static final account = of(SpaRoutePaths.account);
  static final admin = of(SpaRoutePaths.admin);
}

class Routes {
  Routes._();

  /// What each shell route renders.
  ///
  /// The one thing about a route this package still has to say for itself,
  /// because a component cannot be named from the server's package. Leaving
  /// a route out of this map is the drift that used to ship silently;
  /// `unpub/test/spa_routes_test.dart` now reads these keys and fails when
  /// they and [SpaRoutePaths.all] disagree.
  static final _components = <String, ComponentFactory<Object>>{
    SpaRoutePaths.home: home_template.HomeComponentNgFactory,
    SpaRoutePaths.account: account_template.AccountComponentNgFactory,
    SpaRoutePaths.admin: admin_template.AdminComponentNgFactory,
    SpaRoutePaths.list: list_template.ListComponentNgFactory,
    SpaRoutePaths.detailVersion: detail_template.DetailComponentNgFactory,
    SpaRoutePaths.detail: detail_template.DetailComponentNgFactory,
  };

  /// Every shell route, in the order the router should try them — that of
  /// [SpaRoutePaths.all], which puts `detailVersion` ahead of `detail`.
  static final all = <RouteDefinition>[
    for (final route in SpaRoutePaths.all)
      RouteDefinition(
        routePath: RoutePaths.of(route),
        component: _components[route]!,
      ),
    // RouteDefinition.redirect(
    //   path: '',
    //   redirectTo: RoutePaths.heroes.toUrl(),
    // ),
    // RouteDefinition(
    //   path: '.*',
    //   component: not_found_template.NotFoundComponentNgFactory,
    // ),
  ];
}

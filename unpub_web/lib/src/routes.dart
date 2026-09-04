import 'package:ngrouter/angular_router.dart';

import 'home_component.template.dart' as home_template;
import 'list_component.template.dart' as list_template;
import 'detail_component.template.dart' as detail_template;
import 'account_component.template.dart' as account_template;
import 'admin_component.template.dart' as admin_template;
// import 'not_found_component.template.dart' as not_found_template;

class RoutePaths {
  static final home = RoutePath(path: '');
  static final list = RoutePath(path: 'packages');
  static final detail = RoutePath(path: 'packages/:name');
  static final detailVersion =
      RoutePath(path: 'packages/:name/versions/:version');
  static final account = RoutePath(path: 'account');
  static final admin = RoutePath(path: 'admin');
}

class Routes {
  static final home = RouteDefinition(
    routePath: RoutePaths.home,
    component: home_template.HomeComponentNgFactory,
  );
  static final list = RouteDefinition(
    routePath: RoutePaths.list,
    component: list_template.ListComponentNgFactory,
  );
  static final detail = RouteDefinition(
    routePath: RoutePaths.detail,
    component: detail_template.DetailComponentNgFactory,
  );
  static final detailVersion = RouteDefinition(
    routePath: RoutePaths.detailVersion,
    component: detail_template.DetailComponentNgFactory,
  );

  static final account = RouteDefinition(
    routePath: RoutePaths.account,
    component: account_template.AccountComponentNgFactory,
  );

  static final admin = RouteDefinition(
    routePath: RoutePaths.admin,
    component: admin_template.AdminComponentNgFactory,
  );

  static final all = <RouteDefinition>[
    home,
    account,
    admin,
    list,
    detailVersion,
    detail,
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

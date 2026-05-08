import 'package:ngdart/angular.dart';
import 'package:ngrouter/angular_router.dart';
import 'package:unpub_web/app_service.dart';
import 'routes.dart';
import 'package:unpub_api/models.dart';

@Component(
  selector: 'home',
  templateUrl: 'home_component.html',
  directives: [routerDirectives, coreDirectives],
  exports: [RoutePaths],
)
class HomeComponent implements OnActivate {
  final AppService appService;

  late ListApi data;
  bool dataLoaded = false;
  HomeComponent(this.appService);

  @override
  void onActivate(RouterState? previous, RouterState current) async {
    appService.setLoading(true);
    data = await appService.fetchPackages(size: 15);
    dataLoaded = true;
    appService.setLoading(false);
  }

  getDetailUrl(ListApiPackage package) {
    return RoutePaths.detail.toUrl(parameters: {'name': package.name});
  }
}

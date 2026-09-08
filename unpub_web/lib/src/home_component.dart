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

  /// How many entries each of the two lists shows. The home lists lay out
  /// three to a row where the window is wide enough, so both are multiples
  /// of three.
  static const _recentSize = 9;
  static const _topSize = 15;

  /// Null when that list could not be read, in which case the page leaves it
  /// out rather than showing nothing at all.
  RecentApi? recent;
  ListApi? top;
  bool dataLoaded = false;
  HomeComponent(this.appService);

  @override
  void onActivate(RouterState? previous, RouterState current) async {
    appService.keyword = '';
    appService.setLoading(true);
    try {
      // Both at once: two independent lists, and waiting for them in turn
      // would hold the page back for no reason. Each is allowed to fail on
      // its own — the home page is still worth showing with either one of
      // them.
      var results = await Future.wait([
        _guard(() => appService.fetchRecentPublications(size: _recentSize)),
        _guard(() => appService.fetchPackages(size: _topSize)),
      ]);
      recent = results[0] as RecentApi?;
      top = results[1] as ListApi?;
      dataLoaded = true;
    } finally {
      appService.setLoading(false);
    }
  }

  /// [request]'s answer, or null if the server would not give one.
  Future<Object?> _guard(Future<Object> Function() request) async {
    try {
      return await request();
    } catch (e) {
      print('in_pub: could not read a home page list: $e');
      return null;
    }
  }

  /// When a version was published.
  String formatPublished(DateTime? date) => formatTimestamp(date);

  String getPublicationUrl(RecentApiPublication publication) {
    // The version that was published, not the package's newest one: this is
    // the page for that event.
    return RoutePaths.detailVersion.toUrl(parameters: {
      'name': publication.name,
      'version': publication.version,
    });
  }

  getDetailUrl(ListApiPackage package) {
    return RoutePaths.detail.toUrl(parameters: {'name': package.name});
  }
}

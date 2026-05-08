import 'dart:async';
import 'dart:math';
import 'package:intl/intl.dart';
import 'package:ngdart/angular.dart';
import 'package:ngrouter/angular_router.dart';
import 'package:unpub_web/app_service.dart';
import 'routes.dart';
import 'package:unpub_api/models.dart';

@Component(
  selector: 'list',
  templateUrl: 'list_component.html',
  directives: [routerDirectives, coreDirectives],
  exports: [RoutePaths],
)
class ListComponent implements OnInit, OnActivate {
  final AppService appService;
  static final size = 10;

  String? q;
  int currentPage = 0;
  late ListApi data;
  bool dataLoaded = false;
  ListComponent(this.appService);

  int get pageCount => (data.count / size).ceil();

  List<int> get pages {
    if (!dataLoaded) return [];
    var leftCount = min(currentPage, 5);
    var rightCount = min(pageCount - currentPage, 5);
    var offset = max(currentPage - 5, 0);
    return List.generate(leftCount + rightCount + 1, (i) => i + offset);
  }

  String formatDate(DateTime? date) {
    if (date == null) return '';
    return DateFormat.yMMMd().format(date);
  }

  @override
  Future<Null> ngOnInit() async {}

  @override
  void onActivate(RouterState? previous, RouterState current) async {
    q = current.queryParameters['q'];
    currentPage = int.tryParse(current.queryParameters['page'] ?? '0') ?? 0;
    appService.setLoading(true);
    data = await appService.fetchPackages(size: size, page: currentPage, q: q);
    dataLoaded = true;
    appService.setLoading(false);
  }

  getListUrl(int page) {
    Map<String, String> queryParameters = {};
    if (q != null) queryParameters['q'] = q!;
    if (page > 0) queryParameters['page'] = page.toString();

    return RoutePaths.list.toUrl(queryParameters: queryParameters);
  }

  getDetailUrl(ListApiPackage package) {
    return RoutePaths.detail.toUrl(parameters: {'name': package.name});
  }
}

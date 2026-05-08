import 'dart:async';
import 'dart:html';
import 'package:intl/intl.dart';
import 'package:ngdart/angular.dart';
import 'package:ngrouter/angular_router.dart';
import 'package:markdown/markdown.dart';
import 'package:unpub_web/app_service.dart';
import 'routes.dart';
import 'package:unpub_api/models.dart';

// Allow all url
// https://stackoverflow.com/questions/18867266/dart-removing-disallowed-attribute-after-editor-upgraded
class _MyUriPolicy implements UriPolicy {
  bool allowsUri(String uri) => true;
}

final _myUriPolify = _MyUriPolicy();

final NodeValidatorBuilder _htmlValidator = NodeValidatorBuilder.common()
  ..allowElement('a', attributes: ['href'], uriPolicy: _myUriPolify)
  ..allowElement('img', uriAttributes: ['src'], uriPolicy: _myUriPolify);

@Component(
  selector: 'detail',
  templateUrl: 'detail_component.html',
  directives: [routerDirectives, coreDirectives],
  exports: [RoutePaths],
  styles: ['.not-exists { margin-top: 100px }'],
)
class DetailComponent implements OnInit, OnActivate {
  final AppService appService;
  DetailComponent(this.appService);

  late WebapiDetailView package;
  bool packageLoaded = false;
  String? packageName;
  String? packageVersion;
  int activeTab = 0;
  bool packageNotExists = false;

  String? get readmeHtml =>
      package.readme == null ? null : markdownToHtml(package.readme!);

  String? get changelogHtml =>
      package.changelog == null ? null : markdownToHtml(package.changelog!);

  String get pubDevLink {
    var url = 'https://pub.dev/packages/$packageName';
    if (packageVersion != null) {
      url += '/versions/$packageVersion';
    }
    return url;
  }

  String formatDate(DateTime? date) {
    if (date == null) return '';
    return DateFormat.yMMMd().format(date);
  }

  @override
  Future<Null> ngOnInit() async {
    activeTab = 0;
  }

  @override
  void onActivate(RouterState? _, RouterState current) async {
    final name = current.parameters['name'];
    final version = current.parameters['version'];

    if (name != null) {
      packageName = name;
      packageVersion = version;
      packageLoaded = false;
      packageNotExists = false;
      appService.setLoading(true);
      try {
        package = await appService.fetchPackage(name, version);
        packageLoaded = true;
        await Future.delayed(Duration(seconds: 0));
        querySelector('#readme')
            ?.setInnerHtml(readmeHtml ?? '', validator: _htmlValidator);
        querySelector('#changelog')
            ?.setInnerHtml(changelogHtml ?? '', validator: _htmlValidator);
      } on PackageNotExistsException {
        packageNotExists = true;
      } finally {
        appService.setLoading(false);
      }
    }
  }

  getListUrl(String q) {
    return RoutePaths.list.toUrl(queryParameters: {'q': q});
  }

  getDetailUrl(String name, [String? version]) {
    if (version == null) {
      return RoutePaths.detail.toUrl(parameters: {'name': name});
    } else {
      return RoutePaths.detailVersion
          .toUrl(parameters: {'name': name, 'version': version});
    }
  }
}

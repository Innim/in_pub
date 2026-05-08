import 'dart:html' as html;
import 'package:ngdart/angular.dart';
import 'package:ngrouter/angular_router.dart';
import 'package:ngforms/angular_forms.dart';
import 'package:unpub_web/src/routes.dart';
import 'app_service.dart';

@Component(
  selector: 'my-app',
  styleUrls: ['app_component.css'],
  templateUrl: 'app_component.html',
  directives: [routerDirectives, coreDirectives, formDirectives],
  exports: [RoutePaths, Routes],
  providers: [ClassProvider(AppService)],
)
class AppComponent {
  final AppService appService;
  final Router _router;
  AppComponent(this.appService, this._router);

  submit() async {
    if (appService.keyword == '') {
      return html.window.alert('keyword empty');
    }
    var result = await _router.navigate(RoutePaths.list.toUrl(),
        NavigationParams(queryParameters: {'q': appService.keyword}));
    // print(result);
  }

  String get homeUrl => RoutePaths.home.toUrl();
  bool get loading => appService.loading;

  String get version =>
      html.document
          .querySelector('meta[name="app-version"]')
          ?.getAttribute('content') ??
      '';
}

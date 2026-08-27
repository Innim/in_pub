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
class AppComponent implements OnInit {
  final AppService appService;
  final Router _router;
  final NgZone _zone;
  AppComponent(this.appService, this._router, this._zone);

  CurrentUser? _user;

  @override
  void ngOnInit() {
    // Nothing depends on the answer, so the header simply fills in once it
    // arrives rather than holding up the page.
    appService.fetchCurrentUser().then((user) {
      // Applied through the zone rather than assigned directly: the answer
      // comes back from an http callback, and only a turn that ends inside
      // the Angular zone schedules a change detection pass. Without this the
      // field is set and the header never redraws.
      _zone.run(() => _user = user);
    });
  }

  bool get signedIn => _user != null;
  String get userName => _user?.name ?? '';
  bool get isAdmin => _user?.isAdmin ?? false;

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

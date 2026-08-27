import 'dart:convert';
import 'dart:html' as html;
import 'package:http/http.dart' as http;
import 'package:ngdart/angular.dart';
import 'package:unpub_web/constants.dart';
import 'src/routes.dart';
import 'package:unpub_api/models.dart';

class PackageNotExistsException implements Exception {
  final String message;
  PackageNotExistsException(this.message);
}

/// Who the server says is signed in.
class CurrentUser {
  final String name;
  final String email;
  final bool isAdmin;

  CurrentUser(this.name, this.email, this.isAdmin);
}

@Injectable()
class AppService {
  bool loading = false;
  String keyword = '';

  void setLoading(bool value) {
    loading = value;
  }

  Uri _uri(String path, [Map<String, dynamic> queryParameters = const {}]) {
    var baseUrl = isProduction ? '' : 'http://localhost:4000';
    return Uri.parse(baseUrl).replace(
      path: path,
      queryParameters: queryParameters.map((k, v) => MapEntry(k, v.toString())),
    );
  }

  /// The signed-in user, or null when nobody is signed in — which is also the
  /// answer when the server was started without `--auth`, in which case
  /// `/auth/me` is not routed at all.
  ///
  /// Deliberately not routed through [_fetch]: that turns an unauthenticated
  /// answer into a redirect to the sign-in page, which for this call would
  /// mean the header could never render for an anonymous visitor.
  Future<CurrentUser?> fetchCurrentUser() async {
    try {
      var res = await http.get(_uri('/auth/me'));
      if (res.statusCode == 404) return null; // the server runs without --auth
      if (res.statusCode != 200) {
        // Anything else is unexpected, and silently showing no user would
        // make it look like the header was never built.
        print('in_pub: /auth/me returned HTTP ${res.statusCode}');
        return null;
      }
      var data = json.decode(res.body) as Map<String, dynamic>;
      if (data['authenticated'] != true) return null;
      return CurrentUser(
        (data['name'] as String?) ?? (data['email'] as String?) ?? '',
        (data['email'] as String?) ?? '',
        data['admin'] == true,
      );
    } catch (e) {
      print('in_pub: could not read /auth/me: $e');
      return null;
    }
  }

  Future _fetch(String path,
      [Map<String, dynamic> queryParameters = const {}]) async {
    queryParameters.entries
        .where((entry) => entry.value == null)
        .toList()
        .forEach((entry) => queryParameters.remove(entry.key));

    var res = await http.get(_uri(path, queryParameters));

    // The session ended while the app was open — expired, signed out
    // elsewhere, or revoked. An XHR cannot follow the sign-in redirect, so
    // the server answers with a status and the page navigates there itself.
    if (res.statusCode == 401 || res.statusCode == 403) {
      var current = Uri.parse(html.window.location.href);
      var target = Uri.encodeComponent(
          current.path + (current.hasQuery ? '?${current.query}' : ''));
      html.window.location.assign('/auth/login?return=$target');
      throw 'authentication required';
    }

    var data = json.decode(res.body);

    if (data['error'] != null) {
      var error = data['error'] as String;
      if (error.contains('package not exists')) {
        throw PackageNotExistsException(error);
      }
      throw error;
    }

    return data['data'];
  }

  Future<ListApi> fetchPackages(
      {int? size, int? page, String? sort, String? q}) async {
    var res = await _fetch(
        '/webapi/packages', {'size': size, 'page': page, 'sort': sort, 'q': q});
    return ListApi.fromJson(res);
  }

  Future<WebapiDetailView> fetchPackage(String name, String? version) async {
    version = version ?? 'latest';
    var res = await _fetch('/webapi/package/$name/$version');
    return WebapiDetailView.fromJson(res);
  }

  getDetailUrl(package) {
    return RoutePaths.detail.toUrl(parameters: {'name': package['name']});
  }
}

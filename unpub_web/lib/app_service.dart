import 'dart:convert';

import 'package:intl/intl.dart';
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

/// A request the server refused. [status] is what callers should branch on:
/// matching on the wording breaks the moment the message is reworded.
class ApiRefusedException implements Exception {
  final int status;
  final String message;

  /// The server's own tag for why, where it sends one. 403 carries two
  /// unrelated meanings — "you are not an administrator" and "this request
  /// could not be verified" — so the status alone cannot be branched on.
  final String? reason;

  ApiRefusedException(this.status, this.message, {this.reason});

  /// Signed in, and this section is not for you. Specifically not any 403:
  /// a stale anti-forgery token is one too, and reading that as "not an
  /// administrator" tells an administrator they are not one.
  bool get isForbidden => status == 403 && reason == 'notAdmin';

  @override
  String toString() => message;
}

/// Renders a timestamp the way both account and administration screens do.
/// Shared so the two cannot drift over what an absent date looks like.
String formatTimestamp(DateTime? date) =>
    date == null ? 'never' : DateFormat.yMMMd().add_Hm().format(date.toLocal());

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

  /// Decodes a response body, or says plainly that it was not JSON — a bare
  /// `FormatException` on screen explains nothing.
  ///
  /// Only a 404 gets the "running without authentication" reading, because
  /// that is what that case actually looks like: the account endpoints are
  /// not routed at all. Attaching it to every non-JSON body sent people
  /// checking their startup flags over what was really a 500.
  Map<String, dynamic> _decode(http.Response res) {
    try {
      var decoded = json.decode(res.body);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    if (res.statusCode == 404) {
      throw 'this endpoint is not available on this server; '
          'it may be running without authentication';
    }
    throw 'the server did not answer with JSON (HTTP ${res.statusCode})';
  }

  /// Turns a refused response into the message to throw, or null if it was
  /// not a refusal.
  ///
  /// The two kinds have to be told apart. "You are not signed in" is answered
  /// by leaving for the sign-in flow; "you are signed in and still not
  /// allowed" — a non-administrator opening the administration section — must
  /// not, or the sign-in redirects straight back and the browser loops. The
  /// server marks the first kind by including a `login` field.
  ApiRefusedException? _refusal(http.Response res) {
    if (res.statusCode != 401 && res.statusCode != 403) return null;

    Map<String, dynamic>? body;
    try {
      body = json.decode(res.body) as Map<String, dynamic>;
    } catch (_) {}

    var message = body?['error'];
    var reason = body?['reason'];
    var tag = reason is String ? reason : null;

    // The server says where to go, if anywhere: `login` when signing in
    // would help, `denied` when the person is signed in and still refused.
    // Neither means the caller has to deal with it — a non-administrator
    // opening the administration section, say.
    if (body?['denied'] != null) {
      // A fixed path, not the one in the body. The value is only a signal
      // that this is the denied case; navigating to whatever it contains
      // would make any endpoint able to redirect the app wherever it liked.
      //
      // The reason travels with it. Leaving it behind meant a session ended
      // by a change to the allowed groups read as "your access has been
      // withdrawn, an administrator can restore it" — which sent people
      // hunting for a block nobody had applied. Passed through opaquely: the
      // server signed it and verifies it again, so nothing this app does can
      // make that page say anything the server did not say.
      var detail = body?['deniedDetail'];
      html.window.location.assign(detail is String && detail.isNotEmpty
          ? '/auth/denied?d=${Uri.encodeQueryComponent(detail)}'
          : '/auth/denied');
      return ApiRefusedException(res.statusCode,
          message is String ? message : 'access has been withdrawn',
          reason: tag);
    }
    if (res.statusCode == 401 || body?['login'] != null) {
      _goToSignIn();
      return ApiRefusedException(res.statusCode,
          message is String ? message : 'authentication required',
          reason: tag);
    }
    return ApiRefusedException(res.statusCode,
        message is String ? message : 'you do not have access to this',
        reason: tag);
  }

  /// Leaves the app for the sign-in flow, remembering where to come back to.
  void _goToSignIn() {
    var current = Uri.parse(html.window.location.href);
    var target = Uri.encodeComponent(
        current.path + (current.hasQuery ? '?${current.query}' : ''));
    html.window.location.assign('/auth/login?return=$target');
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

    var refusal = _refusal(res);
    if (refusal != null) throw refusal;

    var data = _decode(res);

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

  /// Posts to an account endpoint, carrying the anti-forgery token the
  /// account view handed out.
  Future<Map<String, dynamic>> _post(
      String path, String csrfToken, Map<String, dynamic> body) async {
    var res = await http.post(
      _uri(path),
      headers: {
        'content-type': 'application/json',
        'x-csrf-token': csrfToken,
      },
      body: json.encode(body),
    );
    var refusal = _refusal(res);
    if (refusal != null) throw refusal;

    var data = _decode(res);
    var error = data['error'];
    if (error != null) throw error is String ? error : error.toString();
    return (data['data'] as Map<String, dynamic>?) ?? const {};
  }

  Future<AccountView> fetchAccount() async {
    var res = await _fetch('/auth/api/account');
    return AccountView.fromJson(res as Map<String, dynamic>);
  }

  /// Ends a session. Returns true when it was the current one, meaning the
  /// caller has just signed itself out.
  Future<bool> revokeSession(String csrfToken, String sessionId) async {
    var res = await _post(
        '/auth/api/account/sessions/revoke', csrfToken, {'session': sessionId});
    return res['signedOut'] == true;
  }

  Future<CreatedToken> createToken(
    String csrfToken, {
    required String name,
    required int lifetimeDays,
    String kind = 'personal',
    String? email,
  }) async {
    var res = await _post('/auth/api/account/tokens/create', csrfToken, {
      'name': name,
      'lifetimeDays': lifetimeDays,
      'kind': kind,
      if (email != null) 'email': email,
    });
    return CreatedToken.fromJson(res);
  }

  Future<void> revokeToken(String csrfToken, String tokenId) async {
    await _post(
        '/auth/api/account/tokens/revoke', csrfToken, {'token': tokenId});
  }

  Future<AdminView> fetchAdmin() async {
    var res = await _fetch('/auth/api/admin');
    return AdminView.fromJson(res as Map<String, dynamic>);
  }

  /// Applies an administrative action and returns the refreshed view, so the
  /// screen never has to guess what the change did.
  Future<AdminView> adminAction(
      String csrfToken, String userId, String action) async {
    var res = await _post(
        '/auth/api/admin/action', csrfToken, {'user': userId, 'do': action});
    return AdminView.fromJson(res);
  }

  getDetailUrl(package) {
    return RoutePaths.detail.toUrl(parameters: {'name': package['name']});
  }
}

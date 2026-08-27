import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;

/// Parses a `Cookie` request header. Shelf leaves cookies alone, so this is
/// the only place that knows their wire format.
Map<String, String> parseCookies(shelf.Request req) {
  var header = req.headers[HttpHeaders.cookieHeader];
  if (header == null || header.isEmpty) return const {};
  var out = <String, String>{};
  for (var pair in header.split(';')) {
    var cut = pair.indexOf('=');
    if (cut <= 0) continue;
    var name = pair.substring(0, cut).trim();
    var value = pair.substring(cut + 1).trim();
    if (name.isEmpty) continue;
    // Cookie values are sometimes quoted; the auth cookies never are, but a
    // proxy or another app on the same host may add one.
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    out[name] = value;
  }
  return out;
}

/// Builds a `Set-Cookie` value.
///
/// [maxAge] of [Duration.zero] deletes the cookie.
String buildCookie(
  String name,
  String value, {
  required bool secure,
  Duration? maxAge,
  String path = '/',
  String sameSite = 'Lax',
  bool httpOnly = true,
}) {
  var parts = <String>['$name=$value', 'Path=$path', 'SameSite=$sameSite'];
  if (httpOnly) parts.add('HttpOnly');
  if (secure) parts.add('Secure');
  if (maxAge != null) {
    parts.add('Max-Age=${maxAge.inSeconds}');
    if (maxAge == Duration.zero) {
      parts.add('Expires=Thu, 01 Jan 1970 00:00:00 GMT');
    }
  }
  return parts.join('; ');
}

/// Adds a `Set-Cookie` header to [response] without dropping any already
/// present.
///
/// Shelf exposes headers as a flat map but accepts a list of values per
/// header, which is what makes several cookies on one response possible.
shelf.Response withCookies(shelf.Response response, List<String> cookies) {
  if (cookies.isEmpty) return response;
  var existing = response.headersAll[HttpHeaders.setCookieHeader] ?? const [];
  return response.change(headers: {
    HttpHeaders.setCookieHeader: [...existing, ...cookies],
  });
}

/// The address the request came from, as far as it can be trusted.
///
/// `X-Forwarded-For` is honoured only when the immediate peer is one of
/// [trustedProxies]. Taking it unconditionally would let any client dictate
/// its own recorded address, which would make both the session binding and
/// the audit trail decorative.
String clientIp(shelf.Request req, List<String> trustedProxies) {
  var direct = _directPeer(req);
  if (trustedProxies.isEmpty || !trustedProxies.contains(direct)) {
    return direct;
  }
  var forwarded = req.headers['x-forwarded-for'];
  if (forwarded == null || forwarded.trim().isEmpty) return direct;
  // Left-most entry is the original client; entries after it were added by
  // successive proxies.
  var first = forwarded.split(',').first.trim();
  return first.isEmpty ? direct : first;
}

String _directPeer(shelf.Request req) {
  var connection = req.context['shelf.io.connection_info'];
  if (connection is HttpConnectionInfo) {
    return connection.remoteAddress.address;
  }
  return '';
}

/// Whether the client looks like it wants a page rather than data.
///
/// Used to choose between redirecting to the login flow and answering with a
/// machine-readable 401.
bool prefersHtml(shelf.Request req) {
  if (req.method != 'GET' && req.method != 'HEAD') return false;
  var requestedWith = req.headers['x-requested-with'];
  if (requestedWith != null &&
      requestedWith.toLowerCase() == 'xmlhttprequest') {
    return false;
  }
  // Fetch metadata, when the browser sends it, says outright whether this is
  // a navigation.
  var mode = req.headers['sec-fetch-mode'];
  if (mode != null) return mode.toLowerCase() == 'navigate';
  var accept = req.headers[HttpHeaders.acceptHeader];
  return accept != null && accept.contains('text/html');
}

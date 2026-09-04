import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;

import 'crypto_box.dart';

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

/// Percent-encodes every byte dart:io refuses to write into a header value.
///
/// The rule is one rule — a code unit of 32..126 travels as itself and
/// anything else as its utf-8 octets — and it lives here because two very
/// different headers need it: a quoted `WWW-Authenticate` parameter and a
/// `Location`. Neither may let the byte through. dart:io throws on it inside
/// shelf_io's `_writeResponse`, which runs after the try that turns a
/// handler's error into a 500, so the caller is left with a dropped
/// connection and no response at all.
///
/// A literal `%` is left alone, because in a url it is already the escape
/// character and re-encoding it would corrupt the path. A caller that needs
/// the result to decode back to exactly what it was given escapes it before
/// calling — see [quoteHeaderValue].
String percentEncodeUnwritable(String value) {
  // The common case by far, and worth not building a buffer for.
  if (!value.codeUnits.any((c) => c < 0x20 || c > 0x7e)) return value;
  var out = StringBuffer();
  // Over the utf-8 bytes rather than the runes: a character outside the
  // writable range has to leave as its own octets, which is what a reader
  // percent-decodes back into it.
  for (var byte in utf8.encode(value)) {
    if (byte >= 0x20 && byte <= 0x7e) {
      out.writeCharCode(byte);
    } else {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// Makes [value] safe to sit inside a quoted HTTP header parameter.
///
/// Quoting is the smaller half of the job; [percentEncodeUnwritable] is the
/// other. What arrives here is text an operator controls — a revocation
/// reason typed in Cyrillic, or an accented `--auth-public-url` — and it is
/// on its way into `WWW-Authenticate`, so a byte dart:io will not write
/// hangs every unauthenticated pub request rather than answering 401.
///
/// Percent-encoded rather than dropped, because what passes through here is
/// an instruction somebody has to act on: a url still works after the trip,
/// where a row of question marks would not. The literal `%` is escaped first
/// so that what comes out can be read back unambiguously.
String quoteHeaderValue(String value) => percentEncodeUnwritable(value
    .replaceAll('%', '%25')
    .replaceAll('\\', r'\\')
    .replaceAll('"', r'\"'));

/// The refusal the web application understands.
///
/// It branches on which field is present to decide whether to leave for the
/// sign-in flow, to show the access-denied page, or to let the caller deal
/// with it. Built in one place because both the gate and the account API
/// answer this shape, and a disagreement between them sends a blocked person
/// round the identity provider or loops a non-administrator through sign-in.
shelf.Response webRefusal(String message,
        {required bool denied,
        required CryptoBox crypto,
        List<String> cookies = const []}) =>
    withCookies(
        shelf.Response(denied ? HttpStatus.forbidden : HttpStatus.unauthorized,
            body: json.encode({
              'error': message,
              // Signing in only helps somebody who is not signed in.
              if (denied) 'denied': '/auth/denied' else 'login': '/auth/login',
              // The same explanation again, in the only form that survives
              // the trip to a page the browser navigates to on its own. See
              // [signRefusalDetail].
              if (denied) 'deniedDetail': signRefusalDetail(crypto, message),
            }),
            headers: {
              HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
              HttpHeaders.cacheControlHeader: 'no-store',
            }),
        cookies);

/// Carries a refusal's own wording to the access-denied page.
///
/// That page is reached by a full navigation the running application makes
/// for itself, so the query string is the only thing that travels with it —
/// and a query string is written by whoever holds the link. Signed for that
/// reason: unsigned, this server's denial page would repeat any sentence at
/// all, in this server's name, to somebody who has just been told there is
/// something wrong with their access. What it buys is that a session ended
/// by a change to `--auth-allowed-groups` says so, instead of sending the
/// person hunting for a block nobody applied.
String signRefusalDetail(CryptoBox crypto, String message) =>
    crypto.sign(base64Url.encode(utf8.encode(message)));

/// Reads back a value produced by [signRefusalDetail], or null when it was
/// not produced by this server.
String? readRefusalDetail(CryptoBox crypto, String? value) {
  if (value == null || value.isEmpty) return null;
  var payload = crypto.verify(value);
  if (payload == null) return null;
  try {
    var message = utf8.decode(base64Url.decode(payload));
    return message.isEmpty ? null : message;
  } catch (_) {
    return null;
  }
}

/// The post-sign-in return target for a request, encoded for the query
/// string `safeReturnPath` reads it back out of.
String returnTargetFor(shelf.Request req) =>
    Uri.encodeComponent(req.requestedUri.path +
        (req.requestedUri.hasQuery ? '?${req.requestedUri.query}' : ''));

/// The 401 the pub client understands.
///
/// `dart pub` prints the `message` parameter of `WWW-Authenticate` back to
/// the user, which makes it the only place an instruction reaches somebody
/// stuck at the prompt. Built in one place because it is a contract with an
/// external client: two copies would drift, and a caller would see a
/// different shape depending on which refused it.
shelf.Response pubUnauthorized(String message) => shelf.Response(
      HttpStatus.unauthorized,
      headers: {
        HttpHeaders.contentTypeHeader: 'application/json; charset=utf-8',
        HttpHeaders.wwwAuthenticateHeader:
            'Bearer realm="pub", message="${quoteHeaderValue(message)}"',
        HttpHeaders.cacheControlHeader: 'no-store',
      },
      body: json.encode({
        'error': {'message': message}
      }),
    );

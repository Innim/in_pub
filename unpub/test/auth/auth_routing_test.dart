import 'dart:io';

import 'package:in_pub/in_pub.dart';
import 'package:in_pub/src/auth/auth_middleware.dart';
import 'package:in_pub/src/auth/auth_routes.dart';
import 'package:in_pub/src/auth/crypto_box.dart';
import 'package:in_pub/src/auth/http_helpers.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;
import 'package:test/test.dart';

void main() {
  group('route classification', () {
    // The pub client and the browser get different answers to "you are not
    // signed in", so every path has to land in the right bucket. Getting this
    // wrong either redirects `dart pub` to an HTML login page or leaves a
    // page open that was meant to be private.
    test('the web UI and its pages are browser routes', () {
      expect(classifyRoute('/'), RouteKind.web);
      expect(classifyRoute('/packages'), RouteKind.web);
      expect(classifyRoute('/packages/my_package'), RouteKind.web);
      expect(
          classifyRoute('/packages/my_package/versions/1.0.0'), RouteKind.web);
      expect(classifyRoute('/main.dart.js'), RouteKind.web);
      expect(classifyRoute('/documentation/my_package/1.0.0/'), RouteKind.web);
    });

    test('the web UI data endpoints are XHR routes', () {
      expect(classifyRoute('/webapi/packages'), RouteKind.webApi);
      expect(classifyRoute('/webapi/package/foo/latest'), RouteKind.webApi);
    });

    test('the pub client surface is a pub route', () {
      expect(classifyRoute('/api/packages/foo'), RouteKind.pubApi);
      expect(
          classifyRoute('/api/packages/foo/versions/1.0.0'), RouteKind.pubApi);
      expect(
          classifyRoute('/api/packages/versions/newUpload'), RouteKind.pubApi);
      expect(classifyRoute('/packages/foo/versions/1.0.0.tar.gz'),
          RouteKind.pubApi);
      expect(classifyRoute('/packages/foo.json'), RouteKind.pubApi);
    });

    test('a package page is not mistaken for a tarball', () {
      // Both live under /packages/; only the extension tells them apart.
      expect(classifyRoute('/packages/foo/versions/1.0.0'), RouteKind.web);
      expect(classifyRoute('/packages/foo/versions/1.0.0.tar.gz'),
          RouteKind.pubApi);
    });

    test('the sign-in flow is always reachable', () {
      expect(classifyRoute('/auth/login'), RouteKind.public);
      expect(classifyRoute('/auth/callback'), RouteKind.public);
      expect(classifyRoute('/auth/sessions'), RouteKind.public);
    });

    test('badges follow the flag', () {
      expect(classifyRoute('/badge/v/foo'), RouteKind.public);
      // Closed, but still reachable with a credential: `pubApi` is the kind
      // that accepts a bearer token, and a session cookie for reads besides.
      // As `web` a token holder — a README renderer, a CI job that has run
      // `dart pub token add` — had no way to authenticate for it at all.
      expect(
          classifyRoute('/badge/v/foo', publicBadges: false), RouteKind.pubApi);
    });

    test('and one rule decides that, for the gate as well', () {
      // The gate has to demand a credential for a closed badge even where
      // `--auth-protect-pub-api` leaves the rest of the pub surface open, and
      // it used to decide that from its own copy of the prefix. Nothing tied
      // the two together: changing the prefix here alone would have gone on
      // serving closed badges to anyone.
      for (var path in const [
        '/badge/v/foo',
        '/badge/d/foo',
        '/api/packages/foo',
        '/packages/foo.json',
        '/logo',
        '/packages/foo',
      ]) {
        expect(
            isClosedBadge(path, publicBadges: false),
            classifyRoute(path) == RouteKind.public &&
                classifyRoute(path, publicBadges: false) == RouteKind.pubApi,
            reason: path);
        expect(isClosedBadge(path, publicBadges: true), isFalse, reason: path);
      }
    });

    test('the logo is public whatever the flag says', () {
      // It is the site's own asset, the same bytes whatever is hosted here,
      // so closing it buys nothing and costs a re-download on every page.
      expect(classifyRoute('/logo'), RouteKind.public);
      expect(classifyRoute('/logo', publicBadges: false), RouteKind.public);
    });
  });

  group('post-login redirect', () {
    // A crafted `?return=` would otherwise bounce someone who has just
    // authenticated straight off this site. Values arrive already decoded,
    // from `Uri.queryParameters`.
    test('keeps a path on this server', () {
      expect(safeReturnPath('/packages/foo'), '/packages/foo');
      expect(safeReturnPath('/packages?q=abc'), '/packages?q=abc');
    });

    test('keeps a literal percent intact', () {
      // Decoding a second time would turn this into a dangling percent and
      // lose the query it belongs to.
      expect(safeReturnPath('/packages?q=100%25'), '/packages?q=100%25');
    });

    test('refuses anything that leaves this server', () {
      expect(safeReturnPath('https://evil.example.com'), '/');
      expect(safeReturnPath('//evil.example.com'), '/');
      expect(safeReturnPath(r'/\evil.example.com'), '/');
      expect(safeReturnPath('javascript:alert(1)'), '/');
    });

    test('an encoded escape does not survive the round trip', () {
      // What the router hands over after decoding `%2F%2Fevil.example.com`.
      expect(
          safeReturnPath(Uri.decodeComponent('%2F%2Fevil.example.com')), '/');
    });

    test('refuses to send anyone back into the sign-in flow', () {
      expect(safeReturnPath('/auth/login'), '/');
      expect(safeReturnPath('/auth/callback?code=x'), '/');
      // Only those two. Everything else under `/auth/` is a legitimate place
      // to come back to.
      expect(safeReturnPath('/auth/sessions'), '/auth/sessions');
    });

    test('refuses control characters', () {
      // These reach the `Location` header. dart:io refuses to write a header
      // containing a newline, so without this the crafted link is an
      // unauthenticated 500 rather than a redirect.
      expect(safeReturnPath('/foo\r\nX-Injected: 1'), '/');
      expect(safeReturnPath('/foo\nSet-Cookie: a=b'), '/');
      expect(safeReturnPath('/foo\u0000bar'), '/');
    });

    test('encodes what a header cannot carry rather than refusing it', () {
      // dart:io will not write a byte of 128 or more into `Location` either,
      // and that throw lands outside the try that would have made it a 500 —
      // the caller gets a dropped connection instead. But unlike a newline
      // this is ordinary: the application's own search box produces
      // `/packages?q=<term>`, and the value arrives here already decoded.
      // Sending that person to the home page after signing in would be a
      // strange way to answer.
      expect(safeReturnPath('/packages?q=привет'),
          '/packages?q=%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82');
      expect(safeReturnPath('/packages/café'), '/packages/caf%C3%A9');
    });

    test('a path that is already encoded is left as it is', () {
      // Otherwise a second trip through the sign-in flow — the callback
      // hands its return target back to `/auth/login` — would double-encode
      // it and land somewhere that does not exist.
      expect(safeReturnPath('/packages?q=%D0%BF'), '/packages?q=%D0%BF');
    });

    test('falls back to the home page', () {
      expect(safeReturnPath(null), '/');
      expect(safeReturnPath(''), '/');
    });
  });

  group('a flag that only means something with --auth', () {
    // Leaving the server open while the operator believes otherwise is worse
    // than refusing to start, which is the reasoning `--auth-protect-pub-api`
    // already carried.
    test('--auth-protect-pub-api needs it', () {
      expect(
          AuthConfig.disabled(protectPubApi: true).validate(),
          contains(predicate<String>(
              (e) => e.contains('--auth-protect-pub-api'), 'names the flag')));
    });

    test('--no-auth-public-badges needs it too', () {
      // Dropped on the floor by `bin/in_pub.dart`, the flag was a silent
      // no-op on a server without `--auth`: badges went on being served to
      // everyone — and a badge answers differently for a package that
      // exists, so that is the private names and their latest versions.
      expect(
          AuthConfig.disabled(publicBadges: false).validate(),
          contains(predicate<String>(
              (e) => e.contains('--no-auth-public-badges'), 'names the flag')));
    });

    test('--auth-dev-origins needs it as well', () {
      // The odd one out in that it cannot leave the server *more* open —
      // with `--auth` off the CORS answer is a wildcard with credentials
      // refused, so an origin dropped here changes nothing about who may
      // read. What it does is read as though it configured something while
      // configuring nothing, and take a typo with it: `validate` is the only
      // thing that ever looks at an entry's shape, and it never reached that
      // loop for a disabled config.
      expect(
          AuthConfig.disabled(devOrigins: ['http://localhost:8080']).validate(),
          contains(predicate<String>(
              (e) => e.contains('--auth-dev-origins'), 'names the flag')));
    });

    test('and none of them is complained about when unstated', () {
      expect(AuthConfig.disabled().validate(), isEmpty);
      expect(AuthConfig.disabled(publicBadges: true).validate(), isEmpty);
      expect(AuthConfig.disabled(devOrigins: const []).validate(), isEmpty);
    });

    test('the badge default still follows the pub API flag', () {
      // Unstated, `publicBadges` is the opposite of `protectPubApi`, so with
      // that flag already reported the badge message would only repeat it.
      expect(AuthConfig.disabled(protectPubApi: true).validate(), hasLength(1));
    });
  });

  group('the callback uri', () {
    AuthConfig withPublicUrl(String url) => AuthConfig(
          enabled: true,
          issuer: 'https://id.example.org',
          clientId: 'in-pub',
          clientSecret: 'secret',
          publicUrl: Uri.parse(url),
          secret: List<int>.generate(48, (i) => i),
        );

    test('is the callback path on this server', () {
      expect(withPublicUrl('https://pub.example.org').redirectUri.toString(),
          'https://pub.example.org/auth/callback');
      expect(withPublicUrl('https://pub.example.org/').redirectUri.toString(),
          'https://pub.example.org/auth/callback');
    });

    test('a path prefix is refused rather than half-supported', () {
      // The built page carries `<base href="/">`, so the application's own
      // links resolve against the root whatever the callback says. Refusing
      // at startup beats a deployment where half the urls work.
      expect(
          withPublicUrl('https://example.org/pub').validate(),
          contains(predicate<String>((e) => e.contains('path prefix'),
              'complains about the path prefix')));
      expect(withPublicUrl('https://example.org/').validate(), isEmpty);
    });

    test('keeps a non-default port', () {
      expect(withPublicUrl('http://localhost:4000').redirectUri.toString(),
          'http://localhost:4000/auth/callback');
    });

    test('drops any query or fragment on the public url', () {
      expect(
          withPublicUrl('https://pub.example.org/?x=1#frag')
              .redirectUri
              .toString(),
          'https://pub.example.org/auth/callback');
    });
  });

  group('client address', () {
    shelf.Request request({String? forwardedFor}) => shelf.Request(
        'GET', Uri.parse('https://pub.example.org/'),
        headers: {if (forwardedFor != null) 'x-forwarded-for': forwardedFor});

    test('ignores X-Forwarded-For from an untrusted peer', () {
      // Without this, any client dictates its own recorded address and both
      // the session binding and the audit trail become decorative.
      expect(clientIp(request(forwardedFor: '1.2.3.4'), []), '');
      expect(clientIp(request(forwardedFor: '1.2.3.4'), ['10.0.0.1']), '');
    });
  });

  group('telling a page request from a data request', () {
    shelf.Request get(Map<String, String> headers) =>
        shelf.Request('GET', Uri.parse('https://pub.example.org/packages'),
            headers: headers);

    test('a browser navigation wants a page', () {
      expect(prefersHtml(get({'sec-fetch-mode': 'navigate'})), isTrue);
      expect(prefersHtml(get({'accept': 'text/html,application/xhtml+xml'})),
          isTrue);
    });

    test('a fetch from the running app does not', () {
      expect(prefersHtml(get({'sec-fetch-mode': 'cors'})), isFalse);
      expect(prefersHtml(get({'x-requested-with': 'XMLHttpRequest'})), isFalse);
      expect(prefersHtml(get({'accept': 'application/json'})), isFalse);
    });

    test('a POST never wants a page', () {
      var post = shelf.Request('POST', Uri.parse('https://pub.example.org/x'),
          headers: {'accept': 'text/html'});
      expect(prefersHtml(post), isFalse);
    });
  });

  group('cookies', () {
    test('are parsed out of the request header', () {
      var req = shelf.Request('GET', Uri.parse('https://pub.example.org/'),
          headers: {'cookie': 'a=1; inpub_session=abc.def; b="quoted"'});
      var cookies = parseCookies(req);
      expect(cookies['inpub_session'], 'abc.def');
      expect(cookies['a'], '1');
      expect(cookies['b'], 'quoted');
    });

    test('several can be set on one response', () {
      var response = withCookies(shelf.Response.ok('hi'), ['a=1', 'b=2']);
      expect(response.headersAll['set-cookie'], ['a=1', 'b=2']);
    });

    test('a session cookie is not readable from scripts', () {
      var cookie = buildCookie('inpub_session', 'x',
          secure: true, maxAge: const Duration(hours: 1));
      expect(cookie, contains('HttpOnly'));
      expect(cookie, contains('Secure'));
      expect(cookie, contains('SameSite=Lax'));
    });
  });

  group('crypto helpers', () {
    var box = CryptoBox(List<int>.generate(48, (i) => i * 7 % 251));

    test('a signed value survives a round trip', () {
      var signed = box.sign('hello world');
      expect(box.verify(signed), 'hello world');
    });

    test('a tampered value is rejected', () {
      var signed = box.sign('hello world');
      expect(box.verify('tampered${signed.substring(8)}'), isNull);
      expect(box.verify('${signed}x'), isNull);
      expect(box.verify('nodot'), isNull);
    });

    test('a value signed with another secret is rejected', () {
      var other = CryptoBox(List<int>.generate(48, (i) => i));
      expect(box.verify(other.sign('hello')), isNull);
    });

    test('an encrypted value survives a round trip', () {
      var secret = box.encrypt('refresh-token-value');
      expect(secret, isNot(contains('refresh-token-value')));
      expect(box.decrypt(secret), 'refresh-token-value');
    });

    test('encryption is not deterministic', () {
      // Equal ciphertexts would leak that two users hold the same token.
      expect(box.encrypt('same'), isNot(box.encrypt('same')));
    });

    test('a value encrypted under another secret cannot be read', () {
      var other = CryptoBox(List<int>.generate(48, (i) => i));
      expect(box.decrypt(other.encrypt('secret')), isNull);
      expect(box.decrypt('not base64 at all'), isNull);
    });

    test('the PKCE challenge is the base64url sha256 of the verifier', () {
      // RFC 7636 A.1's worked example.
      expect(
          CryptoBox.codeChallenge(
              'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
          'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    });

    test('comparison does not short-circuit on length', () {
      expect(CryptoBox.constantTimeEquals('abc', 'abc'), isTrue);
      expect(CryptoBox.constantTimeEquals('abc', 'abd'), isFalse);
      expect(CryptoBox.constantTimeEquals('abc', 'abcd'), isFalse);
      expect(CryptoBox.constantTimeEquals('', ''), isTrue);
    });
  });

  group('the publish handshake', () {
    // `_isPublishFlow` special-cases three literal paths so that the two GETs
    // bracketing an upload are not mistaken for metadata reads. Nothing in
    // the compiler ties that set to the router, so a rename would silently
    // reclassify a publish step and `dart pub publish` would fail at its
    // first or last step with a credential error pointing nowhere near the
    // cause. This is that tie.
    test('every path in the set is a route on the server', () async {
      var app = App(
        metaStore: _UnroutedMetaStore(),
        packageStore: _UnroutedPackageStore(),
      );

      for (var path in publishHandshakePaths) {
        // A GET reaches `new` and `newUploadFinish`; `newUpload` is a POST.
        // Either way what is being asserted is only that the router knows
        // the path — a 404 is the failure this guards against.
        var routed = false;
        for (var method in const ['GET', 'POST']) {
          var res = await app.router.call(
              shelf.Request(method, Uri.parse('http://localhost:4000$path')));
          if (res.statusCode != HttpStatus.notFound) routed = true;
        }
        expect(routed, isTrue,
            reason: '$path is in publishHandshakePaths but is not routed by '
                'App; the gate would treat it as a metadata read');
      }
    });

    test('a package literally named versions is not a publish step', () {
      // `versions` is a legal package name, so the set has to be matched
      // exactly rather than by the prefix the three share.
      expect(publishHandshakePaths,
          isNot(contains('/api/packages/versions/1.0.0')));
    });
  });

  group('header values dart:io will actually write', () {
    // Served over a real socket rather than reasoned about. dart:io refuses
    // any code unit outside 32..127 in a header value, and the throw happens
    // inside shelf_io's `_writeResponse` — after the try that turns a
    // handler's error into a 500 — so the failure is not a status code at
    // all: the connection is dropped and the caller waits. A response object
    // examined in memory looks perfectly fine.

    /// Serves [response] once and returns what a client actually received.
    Future<HttpClientResponse> serve(shelf.Response response) async {
      var server =
          await io.serve((_) => response, InternetAddress.loopbackIPv4, 0);
      var client = HttpClient();
      try {
        var request =
            await client.getUrl(Uri.parse('http://127.0.0.1:${server.port}/'));
        request.followRedirects = false;
        var result = await request.close().timeout(const Duration(seconds: 5),
            onTimeout: () => throw StateError(
                'the response was never written; dart:io refused a header'));
        await result.drain<void>();
        return result;
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    }

    test('the pub client 401 survives a message that is not ASCII', () async {
      // Both halves of this are operator-controlled: an administrator types
      // the revocation reason, and `--auth-public-url` is a flag. Either one
      // hung every unauthenticated pub request.
      var res = await serve(
          pubUnauthorized('this token has been revoked (доступ отозван). '
              'Run: dart pub token add https://pub.éxample.org'));

      expect(res.statusCode, HttpStatus.unauthorized);
      var header = res.headers.value(HttpHeaders.wwwAuthenticateHeader)!;
      expect(header, contains('%D0%B4'),
          reason: 'the reason survives, encoded');
      expect(header, contains('%C3%A9'),
          reason: 'and so does the accented host in the url');
    });

    test('a redirect to a non-ASCII return path is written', () async {
      var res = await serve(
          shelf.Response.found(safeReturnPath('/packages?q=привет')));

      expect(res.statusCode, HttpStatus.found);
      expect(res.headers.value(HttpHeaders.locationHeader),
          '/packages?q=%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82');
    });
  });

  group('quoting a header parameter', () {
    test('escapes what the grammar needs escaped', () {
      expect(quoteHeaderValue(r'a "b" \c'), r'a \"b\" \\c');
    });

    test('percent-encodes what dart:io will not write', () {
      expect(quoteHeaderValue('café'), 'caf%C3%A9');
      expect(quoteHeaderValue('one\r\ntwo'), 'one%0D%0Atwo');
    });

    test('so that the result is one dart:io accepts', () {
      for (var unit in quoteHeaderValue('пакет "x" \\ 100%').codeUnits) {
        expect(unit, greaterThanOrEqualTo(0x20));
        expect(unit, lessThan(0x7f));
      }
    });

    test('the escape character is encoded too', () {
      // Otherwise the output cannot be read back: a literal `%D0` in the
      // text would be indistinguishable from an octet this added.
      expect(quoteHeaderValue('100% sure'), '100%25 sure');
    });
  });
}

class _UnroutedMetaStore extends MetaStore {
  Never _unused() => throw UnimplementedError('routing only');

  @override
  Future<UnpubPackage?> queryPackage(String name) => _unused();
  @override
  Future<void> addVersion(String name, UnpubVersion version) => _unused();
  @override
  Future<void> addUploader(String name, String email) => _unused();
  @override
  Future<void> removeUploader(String name, String email) => _unused();
  @override
  Future<void> removeVersion(String name, String version) => _unused();
  @override
  void increaseDownloads(String name, String version) => _unused();
  @override
  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
  }) =>
      _unused();
}

class _UnroutedPackageStore extends PackageStore {
  Never _unused() => throw UnimplementedError('routing only');

  @override
  Stream<List<int>> download(String name, String version) => _unused();
  @override
  Future<void> upload(String name, String version, List<int> content) =>
      _unused();
  @override
  Future<void> delete(String name, String version) => _unused();
}

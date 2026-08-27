import 'package:in_pub/src/auth/auth_config.dart';
import 'package:in_pub/src/auth/auth_middleware.dart';
import 'package:in_pub/src/auth/auth_routes.dart';
import 'package:in_pub/src/auth/crypto_box.dart';
import 'package:in_pub/src/auth/http_helpers.dart';
import 'package:shelf/shelf.dart' as shelf;
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
      expect(classifyRoute('/logo'), RouteKind.public);
      expect(classifyRoute('/badge/v/foo', publicBadges: false), RouteKind.web);
      expect(classifyRoute('/logo', publicBadges: false), RouteKind.web);
    });
  });

  group('post-login redirect', () {
    // A crafted `?return=` would otherwise bounce someone who has just
    // authenticated straight off this site.
    test('keeps a path on this server', () {
      expect(safeReturnPath('/packages/foo'), '/packages/foo');
      expect(safeReturnPath('/packages?q=abc'), '/packages?q=abc');
      expect(safeReturnPath(Uri.encodeComponent('/packages/foo')),
          '/packages/foo');
    });

    test('refuses anything that leaves this server', () {
      expect(safeReturnPath('https://evil.example.com'), '/');
      expect(safeReturnPath('//evil.example.com'), '/');
      expect(safeReturnPath(r'/\evil.example.com'), '/');
      expect(safeReturnPath('javascript:alert(1)'), '/');
      expect(safeReturnPath(Uri.encodeComponent('//evil.example.com')), '/');
    });

    test('refuses to send anyone back into the sign-in flow', () {
      expect(safeReturnPath('/auth/login'), '/');
      expect(safeReturnPath('/auth/callback?code=x'), '/');
      expect(safeReturnPath('/auth/sessions'), '/auth/sessions');
    });

    test('falls back to the home page', () {
      expect(safeReturnPath(null), '/');
      expect(safeReturnPath(''), '/');
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

    test('keeps a path prefix', () {
      // Uri.resolve would read `pub` as a file name and drop it, producing a
      // callback the provider has not been told about — which it then
      // refuses.
      expect(withPublicUrl('https://example.org/pub').redirectUri.toString(),
          'https://example.org/pub/auth/callback');
      expect(withPublicUrl('https://example.org/pub/').redirectUri.toString(),
          'https://example.org/pub/auth/callback');
      expect(withPublicUrl('https://example.org/a/b').redirectUri.toString(),
          'https://example.org/a/b/auth/callback');
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
}

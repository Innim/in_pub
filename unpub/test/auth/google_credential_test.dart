import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:in_pub/src/auth/google_credential.dart';
import 'package:in_pub/src/auth/identity.dart';
import 'package:test/test.dart';

/// The legacy Google credential is the only scheme a server running without
/// `--auth` has, and the one every publisher used before this branch existed.
/// Whatever else changes, it has to keep working for as long as the process
/// does.
void main() {
  test(
      'a closed resolver builds a fresh client rather than reusing the dead '
      'one', () async {
    // `close()` closed the client and left the field pointing at it, so
    // `_client ??=` handed the closed one straight back: every later
    // resolution threw `Client is already closed`, which the generic catch
    // turned into "the identity service could not be reached — please try
    // again" against a client that could never work again. Nothing recovers
    // from that short of a restart.
    var resolver = _StubResolver();

    expect(await resolver.resolve('token-1'), 'ci@example.org');
    resolver.close();

    expect(await resolver.resolve('token-2'), 'ci@example.org',
        reason: 'a different token, so the answer cannot come from the cache');
    expect(resolver.clientsBuilt, 2);
  });

  test('closing twice is not an error', () async {
    var resolver = _StubResolver();
    await resolver.resolve('token-1');

    resolver.close();
    resolver.close();

    expect(resolver.clientsBuilt, 1);
  });

  test('closing forgets what Google said, not only the client', () async {
    // Answers are remembered for a minute so one `dart pub publish` does not
    // ask Google three times. Left standing across a close, a credential
    // Google accepted a moment earlier went on opening publishes for the
    // rest of that minute without a single call — including one revoked in
    // between, which is the exact window the cache's short life exists to
    // bound. Reuse after close is a supported path, so this is reachable.
    var resolver = _StubResolver();
    expect(await resolver.resolve('token-1'), 'ci@example.org');
    expect(resolver.asked, 1);

    resolver.close();
    resolver.email = 'someone-else@example.org';

    expect(await resolver.resolve('token-1'), 'someone-else@example.org',
        reason: 'the same token has to be put to Google again');
    expect(resolver.asked, 2);
  });

  test('an answer googleapis could put no status on is an outage, not a no',
      () async {
    // googleapis raises `DetailedApiRequestError` for everything outside
    // 2xx, and reads the status out of the error body rather than off the
    // response — so a body carrying a message and no `code` produces one
    // with a null status. That is what an intercepting proxy, a captive
    // portal or a gateway answering in its own shape looks like, and it is
    // the case the type's own comment describes: not Google considering the
    // credential and refusing it. Read as a refusal, it stopped a
    // `dart pub publish` mid-flight and sent its owner off to reissue a
    // credential that was never the problem.
    var resolver = _StubResolver()
      ..status = HttpStatus.badGateway
      ..body = '{"error": {"message": "upstream unavailable"}}';

    await expectLater(resolver.resolve('token-1'),
        throwsA(isA<IdentityUnavailableException>()));
  });

  test('and a considered refusal is still a refusal', () async {
    // The other side of the same branch, so the fix above cannot quietly
    // turn every rejected credential into a retry loop.
    var resolver = _StubResolver()
      ..status = HttpStatus.unauthorized
      ..body = '{"error": {"code": 401, "message": "Invalid Credentials"}}';

    expect(await resolver.resolve('token-1'), isNull);
  });
}

/// A resolver that answers from a stub instead of googleapis, and counts how
/// many clients it has had to build.
class _StubResolver extends GoogleCredentialResolver {
  int clientsBuilt = 0;

  /// How many times a client actually asked Google, across every client this
  /// resolver has built. A cached answer never gets here.
  int asked = 0;

  /// What the stub answers with. Changed mid-test to tell a fresh answer
  /// from a remembered one.
  String email = 'ci@example.org';

  /// The status and body to put on the wire, when a test cares what
  /// googleapis makes of a particular error shape rather than what this
  /// resolver does with an exception.
  int status = 200;
  String? body;

  @override
  http.Client createClient() {
    clientsBuilt++;
    return _StubClient(this);
  }
}

/// Refuses to serve after being closed, exactly as `http.Client` does — the
/// behaviour the bug turned into a permanent outage.
class _StubClient extends http.BaseClient {
  final _StubResolver owner;
  bool _closed = false;

  _StubClient(this.owner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closed) throw StateError('Client is already closed');
    owner.asked++;
    return http.StreamedResponse(
        Stream.value(utf8.encode(owner.body ?? '{"email": "${owner.email}"}')),
        owner.status,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }

  @override
  void close() => _closed = true;
}

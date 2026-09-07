import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The startup path exists to answer a misconfiguration in words: every
/// problem `AuthConfig.validate` can see, printed as a list, before anything
/// is opened or served.
///
/// A value that `Uri.parse` refuses used to escape that entirely — it threw
/// while the configuration was still being built, so the one flag with a typo
/// in it produced a Dart stack trace instead of the list. Checked in a child
/// process because the thing under test is what the operator sees on the
/// terminal, which is the process exiting and what it wrote on the way out.
void main() {
  Future<ProcessResult> start(List<String> args) => Process.run(
        Platform.resolvedExecutable,
        [File('bin/in_pub.dart').absolute.path, ...args],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
        environment: {
          // Long enough to pass the length check, so nothing but the flag
          // under test can put an entry in the list.
          'INPUB_AUTH_SESSION_SECRET': '0123456789abcdef0123456789abcdef',
        },
      );

  List<String> authArgs(String publicUrl) => [
        '--auth',
        '--auth-issuer',
        'https://id.example.org',
        '--auth-client-id',
        'in-pub',
        '--auth-client-secret',
        's3cret',
        '--auth-public-url',
        publicUrl,
      ];

  test('a --auth-public-url that is not a uri at all is reported, not thrown',
      () async {
    // `Uri.parse` throws `FormatException` on this one: the `[` opens an IPv6
    // literal that is never closed.
    final result = await start(authArgs('http://[::1'));

    final output = '${result.stdout}${result.stderr}';
    expect(result.exitCode, 1,
        reason: 'a misconfigured server should refuse to start, and say so '
            'through the report rather than by crashing');
    expect(output, contains('Authentication is misconfigured:'));
    expect(output, contains('--auth-public-url'),
        reason: 'the report has to name the flag that was wrong');
    expect(output, isNot(contains('FormatException')),
        reason: 'the parse must not escape ahead of the report');
    expect(output, isNot(contains('Unhandled exception')));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a --auth-public-url with no scheme is reported the same way', () async {
    // Parses fine and is still no use as a public base url. Same message, so
    // that "it did not parse" and "it is not absolute" do not read as two
    // different kinds of mistake to the person fixing one.
    final result = await start(authArgs('pub.example.org'));

    final output = '${result.stdout}${result.stderr}';
    expect(result.exitCode, 1);
    expect(output, contains('Authentication is misconfigured:'));
    expect(output, contains('--auth-public-url must be an absolute url'));
    expect(output, contains('https://pub.example.org'),
        reason: 'the shape wanted is worth stating: unstated and unparseable '
            'reach this message alike, and neither says what was expected');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

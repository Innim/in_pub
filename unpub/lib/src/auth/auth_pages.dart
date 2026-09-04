import 'dart:convert';

/// The handful of pages that cannot live in the application.
///
/// Signing in, being turned away and signing out all happen at moments when
/// the application either has not loaded or must not be trusted to say what
/// went wrong. Everything else — the account screen, administration — is a
/// route in the web UI proper.

const _style = '''
  :root { color-scheme: light; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #f5f5f7; color: #1d1d1f; margin: 0; padding: 24px;
    display: flex; min-height: calc(100vh - 48px); align-items: center;
    justify-content: center; }
  .box { background: #fff; padding: 36px 44px; border-radius: 12px;
    max-width: 460px; width: 100%; box-shadow: 0 2px 16px rgba(0,0,0,.08);
    text-align: center; }
  h1 { font-size: 20px; margin: 0 0 12px; }
  p { line-height: 1.5; color: #555; margin: 0 0 12px; }
  a.button { display: inline-block; background: #0175c2; color: #fff;
    padding: 9px 18px; border-radius: 8px; font-size: 14px;
    text-decoration: none; }
  a.button:hover { background: #01568f; }
''';

String _page(String title, String body) => '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_esc(title)}</title>
<style>$_style</style>
</head>
<body>
<div class="box">
$body
</div>
</body>
</html>
''';

String _esc(String value) => const HtmlEscape().convert(value);

/// Shown when a person is authenticated but not allowed in, or when their
/// session was ended for them.
String accessDeniedPage(String heading, String message,
        {bool offerRetry = true}) =>
    _page(heading, '''
  <h1>${_esc(heading)}</h1>
  <p>${_esc(message)}</p>
  ${offerRetry ? '<p><a class="button" href="/auth/login">Try signing in again</a></p>' : ''}
''');

/// Shown when the sign-in flow itself failed (misconfiguration, provider
/// unreachable, tampered callback).
String authErrorPage(String message) => _page('Sign-in failed', '''
  <h1>Sign-in failed</h1>
  <p>${_esc(message)}</p>
  <p><a class="button" href="/auth/login">Start over</a></p>
''');

/// The signed-out landing page, so a person who logs out is not bounced
/// straight back into the provider.
String signedOutPage() => _page('Signed out', '''
  <h1>Signed out</h1>
  <p>You have been signed out of this package repository.</p>
  <p><a class="button" href="/auth/login">Sign in again</a></p>
''');

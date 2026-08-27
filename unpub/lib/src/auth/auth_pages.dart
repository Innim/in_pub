import 'dart:convert';

import 'auth_store.dart';

/// Server-rendered pages for the sign-in flow and session management.
///
/// These are plain HTML on purpose: the web UI is an AngularDart application
/// whose build is awkward enough that keeping the auth screens out of it lets
/// the whole feature ship without touching the front end.

const _style = '''
  :root { color-scheme: light; }
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: #f5f5f7; color: #1d1d1f; margin: 0; padding: 24px;
    display: flex; min-height: calc(100vh - 48px); align-items: center;
    justify-content: center; }
  .box { background: #fff; padding: 36px 44px; border-radius: 12px;
    max-width: 720px; width: 100%; box-shadow: 0 2px 16px rgba(0,0,0,.08); }
  .narrow { max-width: 460px; text-align: center; }
  h1 { font-size: 20px; margin: 0 0 12px; }
  p { line-height: 1.5; color: #555; margin: 0 0 12px; }
  a.button, button { display: inline-block; border: 0; cursor: pointer;
    background: #0a84ff; color: #fff; padding: 9px 18px; border-radius: 8px;
    font-size: 14px; text-decoration: none; font-family: inherit; }
  button.danger { background: #c62828; }
  button.ghost { background: #e8e8ed; color: #1d1d1f; }
  table { border-collapse: collapse; width: 100%; margin-top: 16px;
    font-size: 13px; }
  th, td { text-align: left; padding: 8px 10px; border-bottom: 1px solid #ececf0;
    vertical-align: middle; }
  th { color: #6e6e73; font-weight: 600; text-transform: uppercase;
    font-size: 11px; letter-spacing: .04em; }
  .muted { color: #86868b; }
  .tag { display: inline-block; padding: 2px 8px; border-radius: 20px;
    font-size: 11px; background: #e8f5e9; color: #256029; }
  .tag.bad { background: #fdecea; color: #b3261e; }
  .current { font-weight: 600; }
  form.inline { display: inline; }
''';

String _page(String title, String body, {bool narrow = false}) =>
    '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${_esc(title)}</title>
<style>$_style</style>
</head>
<body>
<div class="box${narrow ? ' narrow' : ''}">
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
    _page(
        heading,
        '''
  <h1>${_esc(heading)}</h1>
  <p>${_esc(message)}</p>
  ${offerRetry ? '<p><a class="button" href="/auth/login">Try signing in again</a></p>' : ''}
''',
        narrow: true);

/// Shown when the sign-in flow itself failed (misconfiguration, provider
/// unreachable, tampered callback).
String authErrorPage(String message) => _page(
    'Sign-in failed',
    '''
  <h1>Sign-in failed</h1>
  <p>${_esc(message)}</p>
  <p><a class="button" href="/auth/login">Start over</a></p>
''',
    narrow: true);

/// The signed-out landing page, so a person who logs out is not bounced
/// straight back into the provider.
String signedOutPage() => _page(
    'Signed out',
    '''
  <h1>Signed out</h1>
  <p>You have been signed out of this package repository.</p>
  <p><a class="button" href="/auth/login">Sign in again</a></p>
''',
    narrow: true);

/// A person's own sessions, with the ability to end any of them.
String sessionsPage({
  required StoredUser user,
  required List<StoredSession> sessions,
  required String currentSessionId,
  required String csrfToken,
  required bool isAdmin,
}) {
  var rows = StringBuffer();
  for (var session in sessions) {
    var isCurrent = session.id == currentSessionId;
    var status = session.isRevoked
        ? '<span class="tag bad">ended</span>'
        : '<span class="tag">active</span>';
    rows.write('''
    <tr>
      <td>${_esc(session.ip.isEmpty ? 'unknown' : session.ip)}
        ${isCurrent ? '<span class="current">&nbsp;· this session</span>' : ''}
        ${session.ipHistory.length > 1 ? '<div class="muted">also seen from ${_esc(session.ipHistory.take(session.ipHistory.length - 1).join(', '))}</div>' : ''}
      </td>
      <td>${_esc(_formatTime(session.createdAt))}</td>
      <td>${_esc(_formatTime(session.lastSeenAt))}</td>
      <td>$status${session.revokedReason != null ? '<div class="muted">${_esc(session.revokedReason!)}</div>' : ''}</td>
      <td>${session.isRevoked ? '' : '''
        <form class="inline" method="post" action="/auth/sessions/revoke">
          <input type="hidden" name="csrf" value="${_esc(csrfToken)}">
          <input type="hidden" name="session" value="${_esc(session.id)}">
          <button class="${isCurrent ? 'ghost' : 'danger'}" type="submit">${isCurrent ? 'Sign out' : 'End'}</button>
        </form>'''}</td>
    </tr>''');
  }

  return _page('Your sessions', '''
  <h1>Your sessions</h1>
  <p>Signed in as <strong>${_esc(user.displayName)}</strong>
     ${user.email.isEmpty ? '' : '&lt;${_esc(user.email)}&gt;'}.
     ${user.groups.isEmpty ? '' : 'Groups: ${_esc(user.groups.join(', '))}.'}</p>
  <p>If you see a session you do not recognise, end it and change your
     password on the identity provider.</p>
  <table>
    <tr><th>Address</th><th>Started</th><th>Last used</th><th>Status</th><th></th></tr>
    $rows
  </table>
  <p style="margin-top:24px">
    <a class="button" href="/">Back to packages</a>
    ${isAdmin ? '<a class="button" style="background:#e8e8ed;color:#1d1d1f" href="/auth/admin">Administration</a>' : ''}
  </p>
''');
}

/// The administration view: every known user, their status, and the levers to
/// end their sessions or block them outright.
String adminPage({
  required List<StoredUser> users,
  required Map<String, int> sessionCounts,
  required String csrfToken,
}) {
  var rows = StringBuffer();
  for (var user in users) {
    var live = sessionCounts[user.id] ?? 0;
    var status = switch (user.status) {
      UserStatus.active => '<span class="tag">active</span>',
      UserStatus.blockedLocal => '<span class="tag bad">blocked here</span>',
      UserStatus.blockedUpstream =>
        '<span class="tag bad">revoked by provider</span>',
    };
    rows.write('''
    <tr>
      <td><strong>${_esc(user.displayName)}</strong>
        <div class="muted">${_esc(user.email.isEmpty ? user.id : user.email)}</div></td>
      <td>${_esc(user.groups.join(', '))}</td>
      <td>$status${user.blockedReason != null ? '<div class="muted">${_esc(user.blockedReason!)}</div>' : ''}</td>
      <td>$live</td>
      <td>${_esc(user.lastValidatedAt == null ? 'never' : _formatTime(user.lastValidatedAt!))}</td>
      <td>
        ${live == 0 ? '' : '''
        <form class="inline" method="post" action="/auth/admin/action">
          <input type="hidden" name="csrf" value="${_esc(csrfToken)}">
          <input type="hidden" name="user" value="${_esc(user.id)}">
          <input type="hidden" name="do" value="end-sessions">
          <button class="ghost" type="submit">End sessions</button>
        </form>'''}
        <form class="inline" method="post" action="/auth/admin/action">
          <input type="hidden" name="csrf" value="${_esc(csrfToken)}">
          <input type="hidden" name="user" value="${_esc(user.id)}">
          <input type="hidden" name="do" value="${user.status == UserStatus.blockedLocal ? 'unblock' : 'block'}">
          <button class="${user.status == UserStatus.blockedLocal ? 'ghost' : 'danger'}" type="submit">
            ${user.status == UserStatus.blockedLocal ? 'Unblock' : 'Block'}</button>
        </form>
      </td>
    </tr>''');
  }

  return _page('Administration', '''
  <h1>Users</h1>
  <p>Blocking here is independent of the identity provider: it keeps someone
     out of this repository even while their account elsewhere is untouched.
     Accounts disabled on the provider are picked up automatically and show as
     revoked.</p>
  <table>
    <tr><th>User</th><th>Groups</th><th>Status</th><th>Sessions</th>
        <th>Last checked</th><th></th></tr>
    $rows
  </table>
  <p style="margin-top:24px"><a class="button" href="/">Back to packages</a></p>
''');
}

String _formatTime(DateTime time) {
  var local = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

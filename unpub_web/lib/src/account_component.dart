import 'dart:async';
import 'dart:html' as html;

import 'package:ngdart/angular.dart';
import 'package:ngforms/angular_forms.dart';
import 'package:ngrouter/angular_router.dart';
import 'package:unpub_api/models.dart';
import 'package:unpub_web/app_service.dart';

import 'routes.dart';

/// Your own account: the sessions signed in as you, and the tokens that let
/// the pub client reach this repository.
@Component(
  selector: 'account',
  templateUrl: 'account_component.html',
  directives: [routerDirectives, coreDirectives, formDirectives],
  exports: [RoutePaths],
  styleUrls: ['account_component.css'],
)
class AccountComponent implements OnActivate, OnDestroy {
  final AppService appService;
  final NgZone _zone;
  AccountComponent(this.appService, this._zone);

  AccountView? account;
  bool loaded = false;
  String? error;

  /// Which tab is showing. Kept in the url so the tabs can be linked to and
  /// survive a reload. Tokens leads: it is what people come here to do,
  /// while sessions are looked at when something is wrong.
  String tab = 'tokens';

  // New personal token.
  String newName = '';
  int newLifetime = 90;

  // New service token, administrators only.
  String newServiceName = '';
  String newServiceEmail = '';
  int newServiceLifetime = 0;

  /// The value of a token just created. Held only in memory and only until
  /// the page is left: the server keeps a hash and cannot produce it again.
  CreatedToken? justCreated;

  bool busy = false;

  /// Which block was copied a moment ago, so its button can say so. Null
  /// once the acknowledgement has faded.
  String? copied;
  Timer? _copiedTimer;

  @override
  void onActivate(RouterState? previous, RouterState current) async {
    tab = current.queryParameters['tab'] == 'sessions' ? 'sessions' : 'tokens';

    // Switching tabs is a navigation — the tab lives in the query string —
    // but it is pure client-side state. Nothing else here may run for it:
    // refetching costs three store round trips and a session rotation per
    // click, and clearing the panel below would destroy the one copy of a
    // freshly created token the moment its owner clicked "Sessions" before
    // copying it. The server keeps only a hash, so that value is gone.
    if (account != null && previous?.routePath == current.routePath) return;

    // A genuine arrival. Whether the router reuses this instance or builds a
    // fresh one is its business — guarding on `loaded` made the screen's
    // correctness depend on that answer, and got it wrong either way: a
    // reused instance went on offering End and Revoke for sessions and
    // tokens the server had already dropped.
    justCreated = null;
    // Paired with it everywhere else, and the class promises the value is
    // held only until the page is left; leaving the derived list holding the
    // secret would break that the moment anything rendered outside the
    // `*ngIf` that hides it today.
    _rebuildCopyTargets();
    await _load();
  }

  Future<void> _load() async {
    appService.setLoading(true);
    try {
      account = await appService.fetchAccount();
      error = null;
    } catch (e) {
      // An expired session has already sent the browser to sign in by now;
      // anything reaching here is worth showing rather than swallowing.
      error = e.toString();
    } finally {
      loaded = true;
      appService.setLoading(false);
    }
  }

  String tabUrl(String name) => RoutePaths.account
      .toUrl(queryParameters: name == 'tokens' ? {} : {'tab': name});

  // The template compiler does not narrow a nullable through `*ngIf`, so
  // everything the template touches is exposed non-nullable here.
  bool get hasAccount => account != null;
  String get displayName => account?.name ?? '';
  String get email => account?.email ?? '';
  String get groupsLabel => (account?.groups ?? const []).join(', ');
  bool get pubApiProtected => account?.pubApiProtected ?? false;
  bool get hasCreatedToken => justCreated != null;
  String get createdValue => justCreated?.value ?? '';

  bool get isAdmin => account?.isAdmin ?? false;
  List<AccountSession> get sessions => account?.sessions ?? const [];
  List<AccountToken> get tokens => account?.tokens ?? const [];
  List<AccountToken> get serviceTokens => account?.serviceTokens ?? const [];

  bool isCurrentSession(AccountSession session) =>
      session.id == account?.currentSessionId;

  String formatDate(DateTime? date) => formatTimestamp(date);

  String get addTokenCommand =>
      'dart pub token add ${account?.publicUrl ?? ''}';

  List<CopyTarget> _copyTargets = const [];

  /// The two things worth copying off this screen, so the button and its
  /// icon are described once rather than twice.
  ///
  /// Held in a field, not rebuilt per read: `NgFor` tracks by identity, so a
  /// fresh list every change detection pass would destroy and recreate both
  /// buttons — inline SVG included — on every tick.
  List<CopyTarget> get copyTargets => _copyTargets;

  void _rebuildCopyTargets() {
    _copyTargets = justCreated == null
        ? const []
        : [
            CopyTarget('token', createdValue, 'Copy the token'),
            CopyTarget('command', addTokenCommand, 'Copy the command'),
          ];
  }

  Future<void> endSession(AccountSession session) async {
    var csrf = account?.csrfToken;
    if (csrf == null || busy) return;
    busy = true;
    try {
      var signedOut = await appService.revokeSession(csrf, session.id);
      if (signedOut) {
        // The session being ended is the one holding this page up. A full
        // navigation, not a router one: the confirmation is a server-rendered
        // page and the router only knows the application's own routes.
        html.window.location.assign('/auth/signed-out');
        return;
      }
      await _load();
    } catch (e) {
      error = e.toString();
    } finally {
      busy = false;
    }
  }

  Future<void> createToken() async {
    if (newName.trim().isEmpty) return;
    await _create(
      name: newName.trim(),
      days: newLifetime,
      onCreated: () => newName = '',
    );
  }

  Future<void> createServiceToken() async {
    if (newServiceName.trim().isEmpty || newServiceEmail.trim().isEmpty) return;
    await _create(
      name: newServiceName.trim(),
      days: newServiceLifetime,
      kind: 'service',
      email: newServiceEmail.trim(),
      onCreated: () {
        newServiceName = '';
        newServiceEmail = '';
      },
    );
  }

  /// The body both of the above share. One copy, so that a fix to the busy
  /// handling or the error path cannot land in one and miss the other.
  Future<void> _create({
    required String name,
    required int days,
    required void Function() onCreated,
    String kind = 'personal',
    String? email,
  }) async {
    var csrf = account?.csrfToken;
    if (csrf == null || busy) return;
    busy = true;
    try {
      justCreated = await appService.createToken(csrf,
          name: name, lifetimeDays: days, kind: kind, email: email);
      _rebuildCopyTargets();
      onCreated();
      await _load();
    } catch (e) {
      error = e.toString();
    } finally {
      busy = false;
    }
  }

  Future<void> revokeToken(AccountToken token) async {
    var csrf = account?.csrfToken;
    if (csrf == null || busy) return;
    busy = true;
    try {
      await appService.revokeToken(csrf, token.id);
      if (justCreated?.token.id == token.id) {
        justCreated = null;
        _rebuildCopyTargets();
      }
      await _load();
    } catch (e) {
      error = e.toString();
    } finally {
      busy = false;
    }
  }

  void dismissCreated() {
    justCreated = null;
    _rebuildCopyTargets();
  }

  @override
  void ngOnDestroy() {
    // Otherwise the pending acknowledgement keeps this component — and the
    // one-time token value it holds — alive after the screen is gone, then
    // writes to a view that no longer exists.
    _copiedTimer?.cancel();
    // The class promises the plaintext is held only until the page is left.
    // `onActivate` cleared it on the way back in; leaving never did, so it
    // sat on an instance the router still referenced.
    justCreated = null;
    _rebuildCopyTargets();
  }

  /// Puts [text] on the clipboard and briefly marks [what] as copied.
  Future<void> copy(String what, String text) async {
    var ok = await _writeToClipboard(text);
    // The clipboard promise resolves outside the Angular zone, so the
    // acknowledgement would be set and never drawn without this.
    _zone.run(() {
      if (!ok) {
        error = 'Could not reach the clipboard — copy the text by hand.';
        return;
      }
      copied = what;
      _copiedTimer?.cancel();
      _copiedTimer = Timer(const Duration(seconds: 2), () {
        _zone.run(() => copied = null);
      });
    });
  }

  Future<bool> _writeToClipboard(String text) async {
    var clipboard = html.window.navigator.clipboard;
    if (clipboard != null) {
      try {
        await clipboard.writeText(text);
        return true;
      } catch (_) {
        // The modern API refuses outside a secure context, which is exactly
        // where a server reached over plain http leaves us.
      }
    }
    return _copyBySelection(text);
  }

  /// The older mechanism: select hidden text and let the browser copy the
  /// selection. Deprecated, and the only thing that works without https.
  bool _copyBySelection(String text) {
    var area = html.TextAreaElement()
      ..value = text
      ..setAttribute('readonly', '')
      ..style.position = 'fixed'
      ..style.top = '0'
      ..style.opacity = '0';
    html.document.body!.append(area);
    area.select();
    var copiedOk = false;
    try {
      copiedOk = html.document.execCommand('copy');
    } catch (_) {
      copiedOk = false;
    }
    area.remove();
    return copiedOk;
  }
}

/// Something the account screen offers to put on the clipboard.
class CopyTarget {
  /// Distinguishes this button's copied state from the others'.
  final String key;
  final String text;
  final String label;

  const CopyTarget(this.key, this.text, this.label);
}

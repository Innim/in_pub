import 'package:ngdart/angular.dart';
import 'package:ngrouter/angular_router.dart';
import 'package:unpub_api/models.dart';
import 'package:unpub_web/app_service.dart';

import 'routes.dart';

/// Administration: everyone who has ever signed in, and the levers over them.
///
/// Deliberately its own section rather than a tab of the account screen —
/// that one is about you, this one is about everybody else.
@Component(
  selector: 'admin',
  templateUrl: 'admin_component.html',
  directives: [routerDirectives, coreDirectives],
  exports: [RoutePaths],
  styleUrls: ['admin_component.css'],
)
class AdminComponent implements OnActivate {
  final AppService appService;
  AdminComponent(this.appService);

  AdminView? view;
  bool loaded = false;
  bool busy = false;
  String? error;

  /// True when the server refused because this account does not administer
  /// it, as opposed to anything having gone wrong.
  bool forbidden = false;

  @override
  void onActivate(RouterState? previous, RouterState current) async {
    // Retried on the way back in when the last attempt failed: otherwise a
    // moment's trouble on first load is permanent for the life of the
    // screen, with nothing to click.
    // Unconditionally, for the same reason the account screen is: guarding
    // on `loaded` makes correctness depend on whether the router reuses this
    // instance, and a reused one shows a stale user table, stale session
    // counts and a stale anti-forgery token — then acts on them.
    await _load();
  }

  Future<void> _load() async {
    appService.setLoading(true);
    try {
      view = await appService.fetchAdmin();
      error = null;
      forbidden = false;
    } on ApiRefusedException catch (e) {
      // The server's own tag is the reliable signal; matching on the wording
      // would break the next time the message is reworded, and the status
      // alone conflates "not an administrator" with a stale request.
      // Whatever was on screen goes with it — showing the previous user
      // table under a notice that access is denied is worse than nothing.
      view = null;
      forbidden = e.isForbidden;
      error = forbidden ? null : e.message;
    } catch (e) {
      forbidden = false;
      error = e.toString();
    } finally {
      loaded = true;
      appService.setLoading(false);
    }
  }

  // The template compiler does not narrow a nullable through `*ngIf`.
  bool get hasView => view != null;
  List<AdminUser> get users => view?.users ?? const [];

  /// Whether more accounts exist than the table shows. Said out loud,
  /// because a list that quietly stops looks like the account being searched
  /// for does not exist.
  bool get truncated => view?.truncated ?? false;

  String formatDate(DateTime? date) => formatTimestamp(date);

  /// Access is actually withdrawn — as opposed to merely unconfirmed. Only
  /// this earns the red tag: `needsSignIn` means the server has run out of
  /// ways to re-check the account, which is a prompt, not a punishment, and
  /// showing it as "blocked" sends an administrator hunting for a block
  /// nobody applied.
  bool isBlocked(AdminUser user) =>
      user.status == 'blockedLocal' || user.status == 'blockedUpstream';

  bool isBlockedHere(AdminUser user) => user.status == 'blockedLocal';

  /// The row belonging to whoever is reading the table.
  ///
  /// The server refuses `block` on it outright — blocking yourself would
  /// leave nothing short of editing the database to undo — so offering the
  /// button could only ever produce an error in the banner above. Ending
  /// your own sessions is a different matter and stays: it signs you out,
  /// which is a real thing to want.
  bool isSelf(AdminUser user) => user.id == view?.viewerId;

  /// Whether clearing the status is worth offering. `unblock` puts the
  /// account back to active with no confirmation on record, so the next
  /// request re-checks it against the provider — the way back for an
  /// upstream revocation the provider has since reversed, without having to
  /// block the account first just to unblock it.
  ///
  /// Deliberately not offered for `needsSignIn`. That state means the server
  /// has nothing left to re-check the account with, so the forced
  /// revalidation this triggers finds the same nothing and writes the state
  /// straight back: a button that always reverts, and worse, one that
  /// distracts from the only thing that helps — its owner signing in.
  bool canRestore(AdminUser user) => user.status == 'blockedUpstream';

  String statusLabel(AdminUser user) {
    switch (user.status) {
      case 'blockedLocal':
        return 'blocked here';
      case 'blockedUpstream':
        return 'revoked by provider';
      case 'needsSignIn':
        return 'must sign in again';
      default:
        return 'active';
    }
  }

  String groupsOf(AdminUser user) => user.groups.join(', ');

  Future<void> act(AdminUser user, String action) async {
    var csrf = view?.csrfToken;
    if (csrf == null || busy) return;
    busy = true;
    try {
      view = await appService.adminAction(csrf, user.id, action);
      error = null;
    } on ApiRefusedException catch (e) {
      if (e.isForbidden) {
        // Not an administrator after all — their groups changed under them.
        // Whatever was on screen goes with it, because a user table under
        // "access is denied" is worse than nothing.
        view = null;
        forbidden = true;
        error = null;
      } else {
        // A refusal of this one action — most often a stale anti-forgery
        // token after the session rotated. The table is still valid and
        // still theirs, so it stays: clearing it would strand an
        // administrator on an empty screen that only a reload recovers.
        error = e.message;
      }
    } catch (e) {
      error = e.toString();
    } finally {
      busy = false;
    }
  }
}

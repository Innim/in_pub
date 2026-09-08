// The browser tab's title.
//
// Composed here, in the small package both the server and the web UI
// already depend on, because both write one:
//
//  * the server stamps `appTitle` into the shell's `<title>` through the
//    build-time template mechanism, which is what a tab says until the
//    application has loaded;
//  * the web UI replaces it on every navigation, through
//    `AppService.setPageTitle`.
//
// Written twice, the two would drift the first time the repository was
// renamed, and the tab would flip from one name to another on load.

/// What this repository is called, wherever its name is shown to a person.
const appTitle = 'in_pub';

/// The tab title of a page that is showing [page].
///
/// pub.dev's shape — the specific thing first, the repository after a pipe.
/// A row of tabs is read by its first few characters, so what differs
/// between them has to come first; the name they all share is what gets cut
/// off. A page with nothing of its own to name — the home page — is
/// [appTitle] alone rather than a doubled `in_pub | in_pub`.
String pageTitle([String? page]) =>
    page == null || page.isEmpty ? appTitle : '$page | $appTitle';

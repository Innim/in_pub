/// How this server decides what an email address is and when two of them are
/// the same one.
///
/// Pure string rules, kept apart from both subsystems that apply them. They
/// lived in `src/auth/auth_store.dart` while the package layer needed them
/// too, which had `App` importing the authentication store to check a
/// publisher's address and `bin/in_pub.dart` importing it to build a query
/// against the *package* collection — neither of which has anything to
/// authenticate.
library;

/// How this server decides two email addresses are the same one.
///
/// Case-folded and trimmed, in one place. It used to be spelled out
/// separately in `App`, in `MongoAuthStore` and in the uploader-lookup
/// closure in `bin/in_pub.dart`, and they did not agree: the closure's regex
/// did not trim, so an uploader entry with a stray space slipped past the
/// check that stops a service token being given somebody else's address,
/// while `App` trimmed and let that same token publish as them.
String normalizeAddress(String email) => email.trim().toLowerCase();

/// The pattern that matches a *stored* address equal to [email], for the two
/// queries that cannot go through a folded key.
///
/// User records written before `emailKey` existed hold only the address as
/// the provider spelled it, and the uploader arrays in the package metadata
/// hold whatever an earlier publish recorded — neither is folded, and both
/// may carry stray whitespace. Callers must ask for a case-insensitive
/// match; the pattern folds nothing itself.
///
/// It exists because this rule was written out by hand in three places and
/// they did not agree: the uploader lookup did not trim, so an entry with a
/// stray space slipped past the check that stops a service token being given
/// somebody else's address, and `findUsersByEmail` did not fold, so a legacy
/// record matched nothing and a blocked publisher's credential was taken for
/// one belonging to no account here.
String storedAddressPattern(String email) =>
    '^\\s*${RegExp.escape(normalizeAddress(email))}\\s*\$';

/// Enough of a check to catch a name typed where an address belongs.
///
/// Deliberately not an attempt at the full grammar — [normalizeAddress], not
/// this, decides what two addresses being equal means. What it is for is the
/// value that is not an address at all: a token's address is recorded as the
/// uploader of everything it publishes and matched against uploader lists,
/// and an empty one is an identity every account with no `email` claim
/// shares.
///
/// The dot in the domain is required on purpose, and it is the part worth
/// stating because it refuses things that do exist: `alice@corp`,
/// `ci@internal`, every single-label intranet name a directory might hold.
/// Only addresses that could be delivered to are wanted here, so
/// `dart pub uploader add ops@intranet` is refused — and on a provider that
/// reports dotless addresses, so is every token an account could create,
/// which with `--auth-protect-pub-api` leaves that person unable to
/// authenticate at all. The answer to that is a real address on the
/// directory entry, not a looser rule here.
bool looksLikeEmailAddress(String value) =>
    RegExp(r'^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$').hasMatch(value);

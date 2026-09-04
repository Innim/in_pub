import 'package:in_pub/src/auth/identity.dart';

/// Scripted [IdentityProvider] for tests.
class FakeIdentityProvider implements IdentityProvider {
  /// What [refresh] does. Replace to simulate a revoked grant or an outage.
  Object? refreshError;

  /// What [userInfo] does.
  Object? userInfoError;

  /// The profile [userInfo] returns when it succeeds.
  AuthenticatedUser profile;

  /// Refresh token handed back on each refresh, simulating rotation.
  String nextRefreshToken = 'refresh-2';

  int refreshCalls = 0;
  int userInfoCalls = 0;

  FakeIdentityProvider({AuthenticatedUser? profile})
      : profile = profile ??
            const AuthenticatedUser(
                id: 'user-1',
                email: 'someone@example.org',
                displayName: 'Someone',
                groups: ['developers']);

  /// Whether the last authorization url asked for a fresh consent.
  bool consentForced = false;

  /// What [authorizationUrl] does. Replace to simulate a provider that
  /// cannot be reached at the moment a sign-in starts.
  Object? authorizationError;

  @override
  Future<Uri> authorizationUrl({
    required String state,
    required String nonce,
    required String codeChallenge,
    bool forceConsent = false,
  }) async {
    var error = authorizationError;
    if (error != null) throw error;
    consentForced = forceConsent;
    return Uri.parse('https://idp.example.org/authorize?state=$state');
  }

  /// What the token exchange hands back. Null stands in for a provider that
  /// issues a refresh token only on first consent.
  String? initialRefreshToken = 'refresh-1';

  @override
  Future<OidcTokens> exchangeCode({
    required String code,
    required String codeVerifier,
    required String nonce,
  }) async =>
      OidcTokens(accessToken: 'access-1', refreshToken: initialRefreshToken);

  @override
  Future<OidcTokens> refresh(String refreshToken) async {
    refreshCalls++;
    var error = refreshError;
    if (error != null) throw error;
    return OidcTokens(
        accessToken: 'access-$refreshCalls', refreshToken: nextRefreshToken);
  }

  @override
  Future<AuthenticatedUser> userInfo(String accessToken) async {
    userInfoCalls++;
    var error = userInfoError;
    if (error != null) throw error;
    return profile;
  }

  @override
  Future<Uri?> endSessionUrl(
          {String? idToken, Uri? postLogoutRedirect}) async =>
      Uri.parse('https://idp.example.org/logout');
}

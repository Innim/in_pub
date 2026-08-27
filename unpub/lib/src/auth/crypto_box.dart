import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

final _random = Random.secure();

/// Cryptographic odds and ends shared by the auth layer.
///
/// Nothing here is novel; it exists so the rest of the code never hand-rolls
/// a comparison or a nonce.
class CryptoBox {
  /// AES key derived from the configured secret. Deriving rather than using
  /// the secret directly means the same config value can safely also feed the
  /// HMAC below without the two uses sharing key material verbatim.
  final Uint8List _aesKey;
  final List<int> _macKey;

  CryptoBox(List<int> secret)
      : _aesKey = Uint8List.fromList(
            sha256.convert([...secret, ...utf8.encode('inpub:aes')]).bytes),
        _macKey =
            sha256.convert([...secret, ...utf8.encode('inpub:mac')]).bytes;

  /// [count] cryptographically random bytes, url-safe base64 without padding.
  static String randomToken([int count = 32]) =>
      base64Url.encode(randomBytes(count)).replaceAll('=', '');

  static Uint8List randomBytes(int count) => Uint8List.fromList(
      List<int>.generate(count, (_) => _random.nextInt(256)));

  /// SHA-256 of [value], hex encoded. Used for the values kept in the
  /// database (session secrets, user agents) so a database dump does not
  /// hand out working credentials.
  static String hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  /// Length-independent, timing-safe comparison of two hex digests.
  ///
  /// `==` on strings short-circuits on the first differing byte, which leaks
  /// how much of a guess was correct.
  static bool constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// PKCE code challenge (S256) for a given verifier.
  static String codeChallenge(String verifier) => base64Url
      .encode(sha256.convert(ascii.encode(verifier)).bytes)
      .replaceAll('=', '');

  /// Signs [payload] so it can be handed to the browser and trusted when it
  /// comes back. Returns `<payload>.<mac>`.
  String sign(String payload) {
    var mac = Hmac(sha256, _macKey).convert(utf8.encode(payload));
    return '$payload.${base64Url.encode(mac.bytes).replaceAll('=', '')}';
  }

  /// Reverses [sign], returning null when the value was tampered with.
  String? verify(String signed) {
    var cut = signed.lastIndexOf('.');
    if (cut <= 0) return null;
    var payload = signed.substring(0, cut);
    var expected = sign(payload).substring(cut + 1);
    if (!constantTimeEquals(signed.substring(cut + 1), expected)) return null;
    return payload;
  }

  /// Encrypts [plainText] with AES-256-GCM under a fresh nonce.
  ///
  /// Refresh tokens live in mongo for as long as a user has sessions; keeping
  /// them encrypted means a leaked database backup does not also leak the
  /// ability to impersonate everyone against the identity provider.
  String encrypt(String plainText) {
    var nonce = randomBytes(12);
    var cipher = GCMBlockCipher(AESEngine())
      ..init(true,
          AEADParameters(KeyParameter(_aesKey), 128, nonce, Uint8List(0)));
    var out = cipher.process(Uint8List.fromList(utf8.encode(plainText)));
    return base64.encode([...nonce, ...out]);
  }

  /// Reverses [encrypt]. Returns null if the value is corrupt or was
  /// encrypted under a different secret — the caller treats that the same as
  /// having no refresh token, which forces a fresh login.
  String? decrypt(String cipherText) {
    try {
      var raw = base64.decode(cipherText);
      if (raw.length <= 12) return null;
      var nonce = Uint8List.fromList(raw.sublist(0, 12));
      var body = Uint8List.fromList(raw.sublist(12));
      var cipher = GCMBlockCipher(AESEngine())
        ..init(false,
            AEADParameters(KeyParameter(_aesKey), 128, nonce, Uint8List(0)));
      return utf8.decode(cipher.process(body));
    } catch (_) {
      return null;
    }
  }
}

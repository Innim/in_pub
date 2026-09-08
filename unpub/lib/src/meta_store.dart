import 'package:in_pub/src/models.dart';

abstract class MetaStore {
  Future<UnpubPackage?> queryPackage(String name);

  Future<void> addVersion(String name, UnpubVersion version);

  Future<void> addUploader(String name, String email);

  Future<void> removeUploader(String name, String email);

  Future<void> removeVersion(String name, String version);

  void increaseDownloads(String name, String version);

  /// The most recently published versions across every package, newest
  /// first, at most [size] of them.
  ///
  /// A feed of publications, not of packages: a package published twice
  /// appears twice, each entry carrying the version that went up and when.
  /// Ordering packages by their last publication cannot say that, and a
  /// package's newest version is not necessarily the one just published —
  /// a fix released on an older line moves neither.
  Future<List<UnpubRecentPublication>> queryRecentPublications({
    required int size,
  });

  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
  });
}

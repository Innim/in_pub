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

  /// Reaches the store, for `/health`. Throws when it cannot be reached —
  /// the caller turns that into what it reports.
  ///
  /// A round trip on purpose, rather than a look at whatever the driver
  /// calls its connection state: a socket that still describes itself as
  /// open is exactly what a wedged database leaves behind, and only an
  /// answer that came back over the wire says the store can still be used.
  /// Nothing is returned, because the probe answers one question — did the
  /// store answer — and `/health` reports nothing else about it.
  ///
  /// Concrete rather than abstract because `MetaStore` is a documented
  /// extension point (README, "Customize meta and package store"): an
  /// implementation outside this repository must not stop compiling for a
  /// probe it never asked for. The default asks for a single package, which
  /// is the cheapest round trip this interface can express; a store that
  /// can do better — [MongoStore] counts, and reads nothing — overrides it.
  Future<void> checkHealth() async {
    await queryPackages(size: 1, page: 0, sort: 'download');
  }
}

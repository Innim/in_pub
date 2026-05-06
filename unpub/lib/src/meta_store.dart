import 'package:in_pub/src/models.dart';

abstract class MetaStore {
  Future<UnpubPackage?> queryPackage(String name);

  Future<void> addVersion(String name, UnpubVersion version);

  Future<void> addUploader(String name, String email);

  Future<void> removeUploader(String name, String email);

  Future<void> removeVersion(String name, String version);

  void increaseDownloads(String name, String version);

  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
  });
}

import 'package:mongo_dart/mongo_dart.dart';
import 'package:intl/intl.dart';
import 'package:in_pub/src/models.dart';
import 'meta_store.dart';

final packageCollection = 'packages';
final statsCollection = 'stats';

class MongoStore extends MetaStore {
  Db db;

  MongoStore(this.db);

  static SelectorBuilder _selectByName(String? name) => where.eq('name', name);

  Future<UnpubQueryResult> _queryPackagesBySelector(
      SelectorBuilder selector) async {
    final count = await db.collection(packageCollection).count(selector);
    final packages = await db
        .collection(packageCollection)
        .find(selector)
        .map((item) => UnpubPackage.fromJson(item))
        .toList();
    return UnpubQueryResult(count, packages);
  }

  @override
  queryPackage(name) async {
    var json =
        await db.collection(packageCollection).findOne(_selectByName(name));
    if (json == null) return null;
    return UnpubPackage.fromJson(json);
  }

  @override
  addVersion(name, version) async {
    await db.collection(packageCollection).update(
        _selectByName(name),
        modify
            .push('versions', version.toJson())
            .addToSet('uploaders', version.uploader)
            .setOnInsert('createdAt', version.createdAt)
            .setOnInsert('private', true)
            .setOnInsert('download', 0)
            .set('updatedAt', version.createdAt),
        upsert: true);
  }

  @override
  addUploader(name, email) async {
    await db
        .collection(packageCollection)
        .update(_selectByName(name), modify.push('uploaders', email));
  }

  @override
  removeUploader(name, email) async {
    await db
        .collection(packageCollection)
        .update(_selectByName(name), modify.pull('uploaders', email));
  }

  @override
  removeVersion(name, version) async {
    await db.collection(packageCollection).update(
        _selectByName(name), modify.pull('versions', {'version': version}));
  }

  @override
  increaseDownloads(name, version) {
    var today = DateFormat('yyyyMMdd').format(DateTime.now());
    db
        .collection(packageCollection)
        .update(_selectByName(name), modify.inc('download', 1));
    db
        .collection(statsCollection)
        .update(_selectByName(name), modify.inc('d$today', 1));
  }

  @override
  Future<UnpubQueryResult> queryPackages({
    required size,
    required page,
    required sort,
    keyword,
    uploader,
    dependency,
  }) {
    var selector =
        where.sortBy(sort, descending: true).limit(size).skip(page * size);

    if (keyword != null) {
      selector = selector.match('name', '.*$keyword.*');
    }
    if (uploader != null) {
      selector = selector.eq('uploaders', uploader);
    }
    if (dependency != null) {
      // Use eq() rather than raw(): raw() replaces the whole selector map,
      // but the driver reads the filter from map['$query'], so a raw() filter
      // is ignored (returning all packages) and sortBy/skip/limit are lost.
      selector = selector.eq('versions', {
        r'$elemMatch': {
          r'$or': [
            {
              'pubspec.dependencies.$dependency': {r'$exists': true}
            },
            {
              'pubspec.dev_dependencies.$dependency': {r'$exists': true}
            },
          ]
        }
      });
    }

    return _queryPackagesBySelector(selector);
  }

  @override
  Future<void> checkHealth() async {
    // A count over the whole collection, which Mongo answers out of its own
    // metadata: it proves the connection still carries a query without
    // reading a document to do it. The number is discarded — `/health` does
    // not report one.
    await db.collection(packageCollection).count();
  }

  @override
  Future<List<UnpubRecentPublication>> queryRecentPublications({
    required int size,
  }) async {
    // Aggregated rather than queried: versions are an array inside the
    // package document, so ordering documents can only ever order packages.
    // `$unwind` makes each version a row of its own, which is what the feed
    // is a list of — two versions of one package are two rows.
    final rows = await db.collection(packageCollection).aggregateToStream([
      {r'$unwind': r'$versions'},
      {
        r'$sort': {'versions.createdAt': -1}
      },
      {r'$limit': size},
      {
        r'$project': {'name': 1, 'versions': 1}
      },
    ]).toList();

    return [
      for (var row in rows)
        UnpubRecentPublication(
          row['name'] as String,
          UnpubVersion.fromJson(row['versions'] as Map<String, dynamic>),
        ),
    ];
  }
}

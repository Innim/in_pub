import 'package:mongo_dart/mongo_dart.dart';
import 'package:in_pub/in_pub.dart' as in_pub;

main(List<String> args) async {
  final db = Db('mongodb://localhost:27017/dart_pub');
  await db.open(); // make sure the MongoDB connection opened

  final app = in_pub.App(
    metaStore: in_pub.MongoStore(db),
    packageStore: in_pub.FileStore('./unpub-packages'),
  );

  final server = await app.serve('0.0.0.0', 4000);
  print('Serving at http://${server.address.host}:${server.port}');
}

import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:in_pub/in_pub.dart' as in_pub;
import 'package:mongo_dart/mongo_dart.dart';

final notExistingPackage = 'not_existing_package';
final baseDir = path.absolute('unpub-packages');
final pubHostedUrl = 'http://localhost:4000';
final baseUri = Uri.parse(pubHostedUrl);

final package0 = 'package_0';
final package1 = 'package_1';
final email0 = 'email0@example.com';
final email1 = 'email1@example.com';
final email2 = 'email2@example.com';
final email3 = 'email3@example.com';

createServer(String opEmail) async {
  final db = Db('mongodb://localhost:27017/dart_pub_test');
  await db.open();
  var mongoStore = in_pub.MongoStore(db);

  var app = in_pub.App(
    metaStore: mongoStore,
    packageStore: in_pub.FileStore(baseDir),
    overrideUploaderEmail: opEmail,
  );

  var server = await app.serve('0.0.0.0', 4000);
  return server;
}

Future<http.Response> getVersions(String package) {
  package = Uri.encodeComponent(package);
  return http.get(baseUri.resolve('/api/packages/$package'));
}

Future<http.Response> getSpecificVersion(String package, String version) {
  package = Uri.encodeComponent(package);
  version = Uri.encodeComponent(version);
  return http.get(baseUri.resolve('/api/packages/$package/versions/$version'));
}

Future<ProcessResult> pubPublish(String name, String version) {
  return Process.run('dart', ['pub', 'publish', '--force'],
      workingDirectory: path.absolute('test/fixtures', name, version),
      environment: {'PUB_HOSTED_URL': pubHostedUrl});
}

Future<ProcessResult> pubUploader(String name, String operation, String email) {
  assert(['add', 'remove'].contains(operation), 'operation error');

  return Process.run('dart', ['pub', 'uploader', operation, email],
      workingDirectory: path.absolute('test/fixtures', name, '0.0.1'),
      environment: {'PUB_HOSTED_URL': pubHostedUrl});
}

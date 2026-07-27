import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:args/args.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:yaml/yaml.dart';
import 'package:in_pub/in_pub.dart' as in_pub;
import 'package:in_pub/src/utils.dart';

main(List<String> args) async {
  final parser = ArgParser();
  parser.addOption('host', abbr: 'h', defaultsTo: '0.0.0.0');
  parser.addOption('port', abbr: 'p', defaultsTo: '4000');
  parser.addOption('database',
      abbr: 'd', defaultsTo: 'mongodb://localhost:27017/dart_pub');
  parser.addOption('proxy-origin', abbr: 'o', defaultsTo: '');
  parser.addOption('dart-executable',
      help: 'Dart SDK executable used to generate API documentation.',
      defaultsTo: 'dart');
  parser.addFlag('docs',
      help: 'Generate and serve API documentation (requires a Dart SDK).',
      defaultsTo: true);

  final results = parser.parse(args);

  final host = results['host'] as String;
  final port = int.parse(results['port'] as String);
  final dbUri = results['database'] as String;
  final proxy_origin = results['proxy-origin'] as String;
  final dartExecutable = results['dart-executable'] as String;
  final docsEnabled = results['docs'] as bool;

  if (results.rest.isNotEmpty) {
    print('Got unexpected arguments: "${results.rest.join(' ')}".\n\nUsage:\n');
    print(parser.usage);
    exit(1);
  }

  String version = '';
  try {
    print('Reading package version...');
    final libUri = await resolveInPubPackageUri('');
    if (libUri == null) {
      print('Warning: could not resolve package URI, version will be empty.');
    } else {
      final pubspecFile = File(libUri.resolve('../pubspec.yaml').toFilePath());
      if (!await pubspecFile.exists()) {
        print('Warning: pubspec.yaml not found at ${pubspecFile.path}');
      } else {
        final yaml = loadYaml(await pubspecFile.readAsString()) as YamlMap;
        version = yaml['version']?.toString() ?? '';
        print('Version: $version');
      }
    }
  } catch (e) {
    print('Warning: failed to read version: $e');
  }

  final db = Db(dbUri);
  await db.open();

  final baseDir = path.absolute('unpub-packages');

  final app = in_pub.App(
      metaStore: in_pub.MongoStore(db),
      packageStore: in_pub.FileStore(baseDir),
      docStore: docsEnabled
          ? in_pub.DocStore(path.absolute('unpub-docs'),
              dartExecutable: dartExecutable)
          : null,
      version: version,
      proxy_origin:
          proxy_origin.trim().isEmpty ? null : Uri.parse(proxy_origin));

  final server = await app.serve(host, port);
  print('Serving at http://${server.address.host}:${server.port}');
}

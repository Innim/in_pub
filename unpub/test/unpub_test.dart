import 'dart:io';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:in_pub/src/utils.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:mongo_dart/mongo_dart.dart';
import 'utils.dart';
import 'package:in_pub/in_pub.dart';

main() {
  Db _db = Db('mongodb://localhost:27017/dart_pub_test');
  late HttpServer _server;

  setUpAll(() async {
    await _db.open();
  });

  Future<Map<String, dynamic>> _readMeta(String name) async {
    var res =
        await _db.collection(packageCollection).findOne(where.eq('name', name));
    res!.remove('_id'); // TODO: null
    return res;
  }

  Map<String, String> _pubspecCache = {};

  Future<String?> _readFile(
      String package, String version, String filename) async {
    var key = package + version + filename;
    if (_pubspecCache[key] == null) {
      var filePath = path.absolute('test/fixtures', package, version, filename);
      _pubspecCache[key] = await File(filePath).readAsString();
    }
    return _pubspecCache[key];
  }

  _cleanUpDb() async {
    // Delete all documents rather than dropCollection: in mongo_dart 0.7.4
    // dropCollection silently no-ops unless getCollectionInfos returns exactly
    // one match, which does not hold on all mongo builds (e.g. CI), leaving
    // state to leak between groups. deleteMany has no such guard.
    await _db.collection(packageCollection).deleteMany(<String, dynamic>{});
    await _db.collection(statsCollection).deleteMany(<String, dynamic>{});
  }

  tearDownAll(() async {
    await _db.close();
  });

  group('publish', () {
    setUpAll(() async {
      await _cleanUpDb();
      _server = await createServer(email0, _db);
    });

    tearDownAll(() async {
      await _server.close();
    });

    test('fresh', () async {
      var version = '0.0.1';

      var result = await pubPublish(package0, version);
      expect(result.stderr, '');

      var meta = await _readMeta(package0);

      expect(meta['name'], package0);
      expect(meta['uploaders'], [email0]);
      expect(meta['private'], true);
      expect(meta['createdAt'], isA<DateTime>());
      expect(meta['updatedAt'], isA<DateTime>());
      expect(meta['versions'], isList);
      expect(meta['versions'], hasLength(1));

      var item = meta['versions'][0];
      expect(item['createdAt'], isA<DateTime>());
      item.remove('createdAt');
      expect(
        DeepCollectionEquality().equals(item, {
          'version': version,
          'pubspecYaml': await _readFile(package0, version, 'pubspec.yaml'),
          'pubspec':
              loadYamlAsMap(await _readFile(package0, version, 'pubspec.yaml')),
          'readme': await _readFile(package0, version, 'README.md'),
          'changelog': await _readFile(package0, version, 'CHANGELOG.md'),
          'uploader': email0,
        }),
        true,
      );
    });

    test('existing package', () async {
      var version = '0.0.3';

      var result = await pubPublish(package0, version);
      expect(result.stderr, '');

      var meta = await _readMeta(package0);

      expect(meta['name'], package0);
      expect(meta['uploaders'], [email0]);
      expect(meta['versions'], isList);
      expect(meta['versions'], hasLength(2));
      expect(meta['versions'][0]['version'], '0.0.1');
      expect(meta['versions'][1]['version'], version);
    });

    test('duplicated version', () async {
      var result = await pubPublish(package0, '0.0.3');
      expect(result.stderr, contains('version invalid'));
    });

    test('no readme and changelog', () async {
      var version = '1.0.0-noreadme';
      await pubPublish(package0, version);
      // expect(result.stderr, ''); // Suggestions:

      var meta = await _readMeta(package0);

      expect(meta['name'], package0);
      expect(meta['uploaders'], [email0]);
      expect(meta['versions'], isList);
      expect(meta['versions'], hasLength(3));
      expect(meta['versions'][0]['version'], '0.0.1');
      expect(meta['versions'][1]['version'], '0.0.3');

      var item = meta['versions'][2];
      expect(item['createdAt'], isA<DateTime>());
      item.remove('createdAt');
      expect(
        DeepCollectionEquality().equals(item, {
          'version': version,
          'pubspecYaml': await _readFile(package0, version, 'pubspec.yaml'),
          'pubspec':
              loadYamlAsMap(await _readFile(package0, version, 'pubspec.yaml')),
          'uploader': email0,
        }),
        true,
      );
    });
  });

  group('get versions', () {
    setUpAll(() async {
      await _cleanUpDb();
      _server = await createServer(email0, _db);
      await pubPublish(package0, '0.0.1');
      await pubPublish(package0, '0.0.2');
    });

    tearDownAll(() async {
      await _server.close();
    });

    test('existing at local', () async {
      var res = await getVersions(package0);
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(
        DeepCollectionEquality().equals(body, {
          "name": "package_0",
          "latest": {
            "archive_url":
                "$pubHostedUrl/packages/package_0/versions/0.0.2.tar.gz",
            "pubspec": loadYamlAsMap(
                await _readFile('package_0', '0.0.2', 'pubspec.yaml')),
            "version": "0.0.2"
          },
          "versions": [
            {
              "archive_url":
                  "$pubHostedUrl/packages/package_0/versions/0.0.1.tar.gz",
              "pubspec": loadYamlAsMap(
                  await _readFile('package_0', '0.0.1', 'pubspec.yaml')),
              "version": "0.0.1"
            },
            {
              "archive_url":
                  "$pubHostedUrl/packages/package_0/versions/0.0.2.tar.gz",
              "pubspec": loadYamlAsMap(
                  await _readFile('package_0', '0.0.2', 'pubspec.yaml')),
              "version": "0.0.2"
            }
          ]
        }),
        true,
      );
    });

    test('existing at remote', () async {
      var name = 'http';
      var res = await getVersions(name);
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(body['name'], name);
    });

    test('not existing', () async {
      var res = await getVersions(notExistingPackage);
      expect(res.statusCode, HttpStatus.notFound);
    });
  });

  group('get specific version', () {
    setUpAll(() async {
      await _cleanUpDb();
      _server = await createServer(email0, _db);
      await pubPublish(package0, '0.0.1');
      await pubPublish(package0, '0.0.3+1');
    });

    tearDownAll(() async {
      await _server.close();
    });

    test('existing at local', () async {
      var res = await getSpecificVersion(package0, '0.0.1');
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(
        DeepCollectionEquality().equals(body, {
          "archive_url":
              "$pubHostedUrl/packages/package_0/versions/0.0.1.tar.gz",
          "pubspec": loadYamlAsMap(
              await _readFile('package_0', '0.0.1', 'pubspec.yaml')),
          "version": '0.0.1'
        }),
        true,
      );
    });

    test('decode version correctly', () async {
      var res = await getSpecificVersion(package0, '0.0.3+1');
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(
        DeepCollectionEquality().equals(body, {
          "archive_url":
              "$pubHostedUrl/packages/package_0/versions/0.0.3+1.tar.gz",
          "pubspec": loadYamlAsMap(
              await _readFile('package_0', '0.0.3+1', 'pubspec.yaml')),
          "version": '0.0.3+1'
        }),
        true,
      );
    });

    test('not existing version at local', () async {
      var res = await getSpecificVersion(package0, '0.0.2');
      expect(res.statusCode, HttpStatus.notFound);
    });

    test('existing at remote', () async {
      var res = await getSpecificVersion('http', '0.12.0+2');
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(body['version'], '0.12.0+2');
    });

    test('not existing', () async {
      var res = await getSpecificVersion(notExistingPackage, '0.0.1');
      expect(res.statusCode, HttpStatus.notFound);
    });
  });

  group('uploader', () {
    setUpAll(() async {
      await _cleanUpDb();
      _server = await createServer(email0, _db);
      await pubPublish(package0, '0.0.1');
    });

    tearDownAll(() async {
      await _server.close();
    });

    group('add', () {
      test('already exists', () async {
        var res = await addUploader(package0, email0);
        expect(res.statusCode, HttpStatus.badRequest);
        expect(json.decode(res.body)['error']['message'],
            contains('email already exists'));

        var meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0]));
      });

      test('success', () async {
        var res = await addUploader(package0, email1);
        expect(res.statusCode, HttpStatus.ok);

        var meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1]));

        res = await addUploader(package0, email2);
        expect(res.statusCode, HttpStatus.ok);

        meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1, email2]));
      });

      test('a name typed where an address belongs is refused', () async {
        // An uploader entry is an identity. `alice` could never publish —
        // `TokenService` refuses to issue a credential carrying anything
        // that is not an address — and having written it, the server then
        // declined to issue a *service* token for `alice` either, on the
        // grounds that it already publishes packages here. One typed word
        // locked the name out on both sides, and `dart pub uploader add`
        // printed success.
        for (var bad in const ['alice', 'alice@localhost', 'alice@ example']) {
          var res = await addUploader(package0, bad);
          expect(res.statusCode, HttpStatus.badRequest, reason: bad);
          expect(json.decode(res.body)['error']['message'],
              contains('not an email address'),
              reason: bad);
        }

        expect((await _readMeta(package0))['uploaders'],
            unorderedEquals([email0, email1, email2]));
      });
    });

    group('remove', () {
      test('not in uploader', () async {
        var res = await removeUploader(package0, email3);
        expect(res.statusCode, HttpStatus.badRequest);
        expect(json.decode(res.body)['error']['message'],
            contains('email not uploader'));

        var meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1, email2]));
      });

      test('success', () async {
        var res = await removeUploader(package0, email2);
        expect(res.statusCode, HttpStatus.ok);

        var meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1]));

        res = await removeUploader(package0, email1);
        expect(res.statusCode, HttpStatus.ok);

        meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0]));
      });

      test('takes every spelling of the address, not just the first', () async {
        // `addVersion` adds the uploader with `addToSet`, which compares
        // literally, so before the write path recorded the spelling already on
        // file a publish as `Email0@Example.com` appended a second entry for
        // the same person. Removal resolved one variant and `$pull`ed that
        // exact string: the other entry survived, the person kept publishing,
        // and `dart pub uploader remove` printed success.
        await _db.collection(packageCollection).updateOne(
            where.eq('name', package0),
            modify.addToSet('uploaders', 'Email0@Example.COM'));
        expect((await _readMeta(package0))['uploaders'],
            unorderedEquals([email0, 'Email0@Example.COM']));

        var res = await removeUploader(package0, email0);
        expect(res.statusCode, HttpStatus.ok);

        expect((await _readMeta(package0))['uploaders'], isEmpty,
            reason: 'a permission reported as withdrawn has to be withdrawn');
      });
    });

    group('permission', () {
      setUpAll(() async {
        await _server.close();
        _server = await createServer(email1, _db);
      });

      tearDownAll(() async {
        await _server.close();
      });

      test('add', () async {
        var res = await addUploader(package0, email0);
        expect(res.statusCode, HttpStatus.forbidden);
        expect(json.decode(res.body)['error']['message'],
            contains('no permission'));
      });

      test('remove', () async {
        var res = await removeUploader(package0, email0);
        expect(res.statusCode, HttpStatus.forbidden);
        expect(json.decode(res.body)['error']['message'],
            contains('no permission'));
      });
    });
  });

  group('badge', () {
    setUpAll(() async {
      await _cleanUpDb();
      _server = await createServer(email0, _db);
      await pubPublish(package0, '0.0.1');
    });

    tearDownAll(() async {
      await _server.close();
    });

    group('v', () {
      test('<1.0.0', () async {
        var res = await http.Client().send(
            http.Request('GET', baseUri.resolve('/badge/v/$package0'))
              ..followRedirects = false);
        expect(res.statusCode, HttpStatus.found);
        expect(res.headers[HttpHeaders.locationHeader],
            'https://img.shields.io/static/v1?label=in_pub&message=0.0.1&color=orange');
      });

      test('>=1.0.0', () async {
        await pubPublish(package0, '1.0.0');

        var res = await http.Client().send(
            http.Request('GET', baseUri.resolve('/badge/v/$package0'))
              ..followRedirects = false);
        expect(res.statusCode, HttpStatus.found);
        expect(res.headers[HttpHeaders.locationHeader],
            'https://img.shields.io/static/v1?label=in_pub&message=1.0.0&color=blue');
      });

      test('package not exists', () async {
        var res =
            await http.get(baseUri.resolve('/badge/v/$notExistingPackage'));
        expect(res.statusCode, HttpStatus.notFound);
      });
    });

    group('d', () {
      test('correct download count', () async {
        var res = await http.Client().send(
            http.Request('GET', baseUri.resolve('/badge/d/$package0'))
              ..followRedirects = false);
        expect(res.statusCode, HttpStatus.found);
        expect(res.headers[HttpHeaders.locationHeader],
            'https://img.shields.io/static/v1?label=downloads&message=0&color=blue');
      });

      test('package not exists', () async {
        var res =
            await http.get(baseUri.resolve('/badge/d/$notExistingPackage'));
        expect(res.statusCode, HttpStatus.notFound);
      });
    });
  });
}

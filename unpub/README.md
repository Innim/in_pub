# in_pub

Fork of [unpub](https://github.com/pd4d10/unpub) by Innim.

[![pub](https://img.shields.io/pub/v/in_pub.svg)](https://pub.dev/packages/in_pub)

`in_pub` is a self-hosted private Dart Pub server for Enterprise, with a simple web interface to search and view packages information.

## Screenshots

![Screenshot](https://raw.githubusercontent.com/Innim/in_pub/master/assets/screenshot.png)

## Usage

### Command Line

```sh
pub global activate in_pub
in_pub --database mongodb://localhost:27017/dart_pub # Replace this with production database uri
```

in_pub use mongodb as meta information store and file system as package(tarball) store by default.

Dart API is also available for further customization.

### Dart API

```dart
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
```

### Options

| Option | Description | Default |
| --- | --- | --- |
| `metaStore` (Required) | Meta information store | - |
| `packageStore` (Required) | Package(tarball) store | - |
| `upstream` | Upstream url | https://pub.dev |
| `googleapisProxy` | Http(s) proxy to call googleapis (to get uploader email) | - |
| `uploadValidator` | See [Package validator](#package-validator) | - |


### Usage behind reverse-proxy

Using in_pub behind reverse proxy(nginx or another), ensure you have necessary headers
```sh
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Server $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# Workaround for: 
# Asynchronous error HttpException: 
# Trying to set 'Transfer-Encoding: Chunked' on HTTP 1.0 headers
proxy_http_version 1.1;
```

### Package validator

Naming conflicts is a common issue for private registry. A reasonable solution is to add prefix to reduce conflict probability.

With `uploadValidator` you could check if uploaded package is valid.

```dart
var app = in_pub.App(
  // ...
  uploadValidator: (Map<String, dynamic> pubspec, String uploaderEmail) {
    // Only allow packages with some specified prefixes to be uploaded
    var prefix = 'my_awesome_prefix_';
    var name = pubspec['name'] as String;
    if (!name.startsWith(prefix)) {
      throw 'Package name should starts with $prefix';
    }

    // Also, you can check if uploader email is valid
    if (!uploaderEmail.endsWith('@your-company.com')) {
      throw 'Uploader email invalid';
    }
  }
);
```

### Customize meta and package store

in_pub is designed to be extensible. It is quite easy to customize your own meta store and package store.

```dart
import 'package:in_pub/in_pub.dart' as in_pub;

class MyAwesomeMetaStore extends in_pub.MetaStore {
  // Implement methods of MetaStore abstract class
  // ...
}

class MyAwesomePackageStore extends in_pub.PackageStore {
  // Implement methods of PackageStore abstract class
  // ...
}

// Then use it
var app = in_pub.App(
  metaStore: MyAwesomeMetaStore(),
  packageStore: MyAwesomePackageStore(),
);
```

## Badges

| URL | Badge |
| --- | --- |
| `/badge/v/{package_name}` | ![badge example](https://img.shields.io/static/v1?label=in_pub&message=0.1.0&color=orange) ![badge example](https://img.shields.io/static/v1?label=in_pub&message=1.0.0&color=blue) |
| `/badge/d/{package_name}` | ![badge example](https://img.shields.io/static/v1?label=downloads&message=123&color=blue) |

## Alternatives

- [pub-dev](https://github.com/dart-lang/pub-dev): Source code of [pub.dev](https://pub.dev), which should be deployed at Google Cloud Platform.
- [pub_server](https://github.com/dart-lang/pub_server): An alpha version of pub server provided by Dart team.

## Credits

- [pub-dev](https://github.com/dart-lang/pub-dev): Web page styles are mostly imported from https://pub.dev directly.
- [shields](https://shields.io): Badges generation.

## License

MIT

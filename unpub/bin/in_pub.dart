import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:args/args.dart';
import 'package:logging/logging.dart';
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
  parser.addFlag('verbose',
      abbr: 'v',
      negatable: false,
      help: 'Log the details of every sign-in exchange with the identity\n'
          'provider: discovery, endpoints, request parameters and provider\n'
          'error responses. Secrets and tokens are never printed.');

  _addAuthOptions(parser);

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

  // Checked before anything is opened or started: a misconfigured server
  // should say so immediately rather than after connecting to the database.
  final authConfig = _authConfigFrom(results);
  final authErrors = authConfig.validate();
  if (authErrors.isNotEmpty) {
    print('Authentication is enabled but misconfigured:');
    for (final error in authErrors) {
      print('  - $error');
    }
    exit(1);
  }

  final verbose = results['verbose'] as bool;
  Logger.root.level = verbose ? Level.FINE : Level.INFO;
  Logger.root.onRecord.listen((record) {
    final time = record.time.toIso8601String().substring(11, 19);
    print('$time [${record.level.name}] ${record.loggerName}: '
        '${record.message}');
    if (record.error != null) print('        ${record.error}');
  });
  if (verbose) print('Verbose logging is on.');

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

  final auth = authConfig.enabled
      ? in_pub.AuthService(
          config: authConfig,
          store: in_pub.MongoAuthStore(db),
        )
      : null;

  final app = in_pub.App(
      metaStore: in_pub.MongoStore(db),
      packageStore: in_pub.FileStore(baseDir),
      docStore: docsEnabled
          ? in_pub.DocStore(path.absolute('unpub-docs'),
              dartExecutable: dartExecutable)
          : null,
      auth: auth,
      version: version,
      proxy_origin:
          proxy_origin.trim().isEmpty ? null : Uri.parse(proxy_origin));

  final server = await app.serve(host, port);
  print('Serving at http://${server.address.host}:${server.port}');
}

void _addAuthOptions(ArgParser parser) {
  parser.addFlag('auth',
      help: 'Require a signed-in user to browse the repository.',
      defaultsTo: false);
  parser.addOption('auth-issuer',
      help: 'OpenID Connect issuer, e.g. https://id.example.org. Everything\n'
          'else is read from its discovery document.');
  parser.addOption('auth-client-id', help: 'OIDC client id.');
  parser.addOption('auth-client-secret',
      help: 'OIDC client secret. Prefer the INPUB_AUTH_CLIENT_SECRET\n'
          'environment variable: command line arguments are visible to\n'
          'every process on the host.');
  parser.addOption('auth-public-url',
      help: 'Public base url of this server. The OIDC redirect uri is\n'
          'derived from it and must match the provider registration exactly.');
  parser.addOption('auth-allowed-groups',
      help: 'Comma-separated provider groups allowed in. Empty means any\n'
          'account on the issuer.',
      defaultsTo: '');
  parser.addOption('auth-admin-groups',
      help: 'Comma-separated groups whose members may manage other users\n'
          "sessions at /auth/admin.",
      defaultsTo: '');
  parser.addOption('auth-scopes',
      help: 'Extra OIDC scopes to request, comma separated.', defaultsTo: '');
  parser.addOption('auth-session-secret',
      help: 'Signing key for auth cookies and stored refresh tokens. Prefer\n'
          'INPUB_AUTH_SESSION_SECRET. Without it a random key is generated\n'
          'at startup and every session ends on restart.');
  parser.addOption('auth-session-ttl',
      help: 'Maximum session lifetime, e.g. 24h.', defaultsTo: '24h');
  parser.addOption('auth-session-idle',
      help: 'End a session after this long without requests.',
      defaultsTo: '8h');
  parser.addOption('auth-session-rotate',
      help: 'How often the session secret is re-issued. Also the widest\n'
          'window in which a stolen cookie goes unnoticed.',
      defaultsTo: '5m');
  parser.addOption('auth-rotation-grace',
      help: 'How long a superseded session secret stays usable for a client\n'
          'that missed the update.',
      defaultsTo: '10m');
  parser.addFlag('auth-reuse-kills-all',
      help: 'When a cloned session is detected, end every session of that\n'
          'user rather than only the offending one.',
      defaultsTo: false);
  parser.addFlag('auth-bind-ip',
      help: 'Bind sessions to the client address. Off by default: mobile\n'
          'networks and VPNs change addresses and would log people out.',
      defaultsTo: false);
  parser.addOption('auth-trusted-proxies',
      help: 'Comma-separated addresses allowed to set X-Forwarded-For.\n'
          'Required when running behind a reverse proxy, otherwise the\n'
          'recorded client address is the proxy.',
      defaultsTo: '');
  parser.addOption('auth-revalidate-interval',
      help: 'How often users are re-checked against the provider. Also the\n'
          'delay between disabling an account there and it losing access here.',
      defaultsTo: '5m');
  parser.addOption('auth-revalidate-hard',
      help: 'Refuse requests from a user who could not be re-checked for\n'
          'this long. Bounds how long a provider outage can keep a revoked\n'
          'account alive.',
      defaultsTo: '30m');
  parser.addOption('auth-revalidate-max-failures',
      help: 'Consecutive failed re-checks after which a user is refused,\n'
          'whichever comes first with --auth-revalidate-hard.',
      defaultsTo: '3');
  parser.addFlag('auth-rp-logout',
      help: 'On sign-out, also sign the user out of the identity provider.',
      defaultsTo: false);
  parser.addFlag('auth-insecure-cookie',
      help: 'Drop the Secure attribute on cookies so the flow works over\n'
          'plain http. Local development only.',
      defaultsTo: false);
  parser.addFlag('auth-public-badges',
      help: 'Keep /badge and /logo reachable without signing in.',
      defaultsTo: true);
}

in_pub.AuthConfig _authConfigFrom(ArgResults results) {
  if (results['auth'] != true) return in_pub.AuthConfig.disabled();

  final env = Platform.environment;
  final secretValue = (results['auth-session-secret'] as String?) ??
      env['INPUB_AUTH_SESSION_SECRET'];
  if (secretValue == null || secretValue.trim().isEmpty) {
    print('Warning: no session secret configured. A random one is generated '
        'for this run, so every session ends when the server restarts. Set '
        'INPUB_AUTH_SESSION_SECRET to keep sessions across restarts.');
  }

  final publicUrl = (results['auth-public-url'] as String?) ?? '';

  return in_pub.AuthConfig(
    enabled: true,
    issuer:
        ((results['auth-issuer'] as String?) ?? env['INPUB_AUTH_ISSUER'] ?? '')
            .trim(),
    clientId: ((results['auth-client-id'] as String?) ??
            env['INPUB_AUTH_CLIENT_ID'] ??
            '')
        .trim(),
    clientSecret: ((results['auth-client-secret'] as String?) ??
            env['INPUB_AUTH_CLIENT_SECRET'] ??
            '')
        .trim(),
    publicUrl: Uri.parse(
        (publicUrl.isEmpty ? env['INPUB_AUTH_PUBLIC_URL'] ?? '' : publicUrl)
            .trim()),
    secret: in_pub.AuthConfig.resolveSecret(secretValue),
    allowedGroups: _csv(results['auth-allowed-groups'] as String?),
    adminGroups: _csv(results['auth-admin-groups'] as String?),
    extraScopes: _csv(results['auth-scopes'] as String?),
    sessionTtl:
        _duration(results['auth-session-ttl'] as String?, 'auth-session-ttl'),
    sessionIdle:
        _duration(results['auth-session-idle'] as String?, 'auth-session-idle'),
    sessionRotate: _duration(
        results['auth-session-rotate'] as String?, 'auth-session-rotate'),
    rotationGrace: _duration(
        results['auth-rotation-grace'] as String?, 'auth-rotation-grace'),
    reuseKillsAllSessions: results['auth-reuse-kills-all'] as bool,
    bindIp: results['auth-bind-ip'] as bool,
    trustedProxies: _csv(results['auth-trusted-proxies'] as String?),
    revalidateInterval: _duration(
        results['auth-revalidate-interval'] as String?,
        'auth-revalidate-interval'),
    revalidateHard: _duration(
        results['auth-revalidate-hard'] as String?, 'auth-revalidate-hard'),
    revalidateMaxFailures: int.tryParse(
            (results['auth-revalidate-max-failures'] as String?) ?? '') ??
        3,
    rpInitiatedLogout: results['auth-rp-logout'] as bool,
    insecureCookie: results['auth-insecure-cookie'] as bool,
    publicBadges: results['auth-public-badges'] as bool,
  );
}

List<String> _csv(String? value) => (value ?? '')
    .split(',')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

/// Parses a duration written as `30s`, `10m`, `24h` or `7d`. A bare number is
/// read as seconds.
Duration _duration(String? value, String flag) {
  final text = (value ?? '').trim();
  if (text.isEmpty) {
    print('Invalid --$flag: a duration is required.');
    exit(1);
  }
  final match = RegExp(r'^(\d+)\s*([smhd]?)$').firstMatch(text);
  if (match == null) {
    print('Invalid --$flag "$text": expected something like 30s, 10m, 24h.');
    exit(1);
  }
  final amount = int.parse(match.group(1)!);
  switch (match.group(2)) {
    case 'd':
      return Duration(days: amount);
    case 'h':
      return Duration(hours: amount);
    case 'm':
      return Duration(minutes: amount);
    default:
      return Duration(seconds: amount);
  }
}

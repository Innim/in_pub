import 'package:in_pub/in_pub.dart';
import 'package:test/test.dart';

/// Pure unit tests for [HostedUrlCompat] — the rewrite that lets a package
/// published against `http://pub.example.org` resolve for an application that
/// asks for `https://pub.example.org`, without republishing it.
///
/// Nothing here touches MongoDB, the network or an archive: the rewrite takes
/// a stored pubspec map and the address the server is answering on, and
/// returns what should go out.
void main() {
  final canonical = Uri.parse('https://pub.example.org');
  final compat = HostedUrlCompat();

  /// The `dependencies` section of [pubspec] after the rewrite.
  Map<String, dynamic> deps(Map<String, dynamic> pubspec,
      {HostedUrlCompat? using, Uri? self, String section = 'dependencies'}) {
    var result = (using ?? compat)
        .rewrite(pubspec, canonical: self ?? canonical, package: 'p');
    return (result[section] as Map).cast<String, dynamic>();
  }

  /// A pubspec with one dependency, which is what every case below is.
  Map<String, dynamic> one(String name, dynamic spec,
          {String section = 'dependencies'}) =>
      {
        'name': 'p',
        'version': '1.0.0',
        section: {name: spec},
      };

  group('the short hosted syntax', () {
    test('an old http url becomes the https one', () {
      var result = deps(one('innim_lib', {
        'hosted': 'http://pub.example.org',
        'version': '^1.0.0',
      }));

      expect(result['innim_lib'], {
        'hosted': 'https://pub.example.org',
        'version': '^1.0.0',
      });
    });

    test('a url already on https is left alone', () {
      var pubspec = one('innim_lib', {
        'hosted': 'https://pub.example.org',
        'version': '^1.0.0',
      });

      // Identical *and* the same instance: a pubspec with nothing to change
      // must not be copied on every request.
      expect(compat.rewrite(pubspec, canonical: canonical), same(pubspec));
    });

    test('another repository is left alone', () {
      var result = deps(one('other_lib', {
        'hosted': 'https://some-other-repository.example.com',
        'version': '^1.0.0',
      }));

      expect(result['other_lib']['hosted'],
          'https://some-other-repository.example.com');
    });

    test('another repository on plain http is left alone too', () {
      var result = deps(one('other_lib', {
        'hosted': 'http://some-other-repository.example.com',
        'version': '^1.0.0',
      }));

      expect(result['other_lib']['hosted'],
          'http://some-other-repository.example.com');
    });

    test('the rest of the entry survives, in the order it was published in',
        () {
      var result = deps(one('innim_lib', {
        'version': '^1.0.0',
        'hosted': 'http://pub.example.org',
      }));

      expect(result['innim_lib'].keys.toList(), ['version', 'hosted']);
      expect(result['innim_lib']['version'], '^1.0.0');
    });
  });

  group('the structured hosted syntax', () {
    test('the url is rewritten and the name kept', () {
      var result = deps(one('innim_lib', {
        'hosted': {'name': 'innim_lib', 'url': 'http://pub.example.org'},
        'version': '^1.0.0',
      }));

      expect(result['innim_lib'], {
        'hosted': {'name': 'innim_lib', 'url': 'https://pub.example.org'},
        'version': '^1.0.0',
      });
    });

    test('a structured url on another repository is left alone', () {
      var result = deps(one('other_lib', {
        'hosted': {
          'name': 'other_lib',
          'url': 'http://some-other-repository.example.com'
        },
      }));

      expect(result['other_lib']['hosted']['url'],
          'http://some-other-repository.example.com');
    });

    test('a hosted map without a url is left alone', () {
      var pubspec = one('innim_lib', {
        'hosted': {'name': 'innim_lib'},
      });

      expect(compat.rewrite(pubspec, canonical: canonical), same(pubspec));
    });
  });

  group('sources that are not hosted', () {
    test('a path dependency is untouched', () {
      var pubspec = one('local_lib', {'path': '../local_lib'});
      expect(compat.rewrite(pubspec, canonical: canonical), same(pubspec));
    });

    test('a git dependency is untouched, url and all', () {
      // Same host, same scheme: still a git url, and changing it would break
      // the clone rather than fix a resolution.
      var pubspec = one('git_lib', {
        'git': {'url': 'http://pub.example.org/git_lib.git', 'ref': 'main'},
      });
      expect(compat.rewrite(pubspec, canonical: canonical), same(pubspec));
    });

    test('an sdk dependency is untouched', () {
      var pubspec = one('flutter', {'sdk': 'flutter'});
      expect(compat.rewrite(pubspec, canonical: canonical), same(pubspec));
    });

    test('a plain version constraint is untouched', () {
      var pubspec = one('collection', '^1.15.0');
      expect(compat.rewrite(pubspec, canonical: canonical), same(pubspec));
    });
  });

  group('matching an address', () {
    test('a hostname that merely starts with ours does not match', () {
      var result = deps(one('evil', {
        'hosted': 'http://pub.example.org.attacker.test',
      }));

      expect(result['evil']['hosted'], 'http://pub.example.org.attacker.test');
    });

    test('a hostname that merely contains ours does not match', () {
      var result = deps(one('evil', {
        'hosted': 'http://mirror.of.pub.example.org.attacker.test',
      }));

      expect(result['evil']['hosted'],
          'http://mirror.of.pub.example.org.attacker.test');
    });

    test('a trailing slash is matched, and kept', () {
      var result = deps(one('innim_lib', {
        'hosted': 'http://pub.example.org/',
      }));

      expect(result['innim_lib']['hosted'], 'https://pub.example.org/');
    });

    test('the default port is the same address', () {
      var result = deps(one('innim_lib', {
        'hosted': 'http://pub.example.org:80',
      }));

      expect(result['innim_lib']['hosted'], 'https://pub.example.org');
    });

    test('another port on the same host is another repository', () {
      var result = deps(one('innim_lib', {
        'hosted': 'http://pub.example.org:8080',
      }));

      expect(result['innim_lib']['hosted'], 'http://pub.example.org:8080');
    });

    test('a path prefix is part of the address', () {
      var result = deps(
          one('innim_lib', {'hosted': 'http://pub.example.org/repo'}),
          self: Uri.parse('https://pub.example.org/repo'));

      expect(result['innim_lib']['hosted'], 'https://pub.example.org/repo');
    });

    test('a different path prefix is a different repository', () {
      var result = deps(
          one('innim_lib', {'hosted': 'http://pub.example.org/other'}),
          self: Uri.parse('https://pub.example.org/repo'));

      expect(result['innim_lib']['hosted'], 'http://pub.example.org/other');
    });

    test('a url with a query is not a repository address', () {
      var result = deps(one('innim_lib', {
        'hosted': 'http://pub.example.org?redirect=1',
      }));

      expect(
          result['innim_lib']['hosted'], 'http://pub.example.org?redirect=1');
    });

    test('a value that is not a url at all is left alone', () {
      var result = deps(one('innim_lib', {'hosted': 'pub.example.org'}));

      expect(result['innim_lib']['hosted'], 'pub.example.org');
    });

    test('an https address written with its default port still matches', () {
      var result = deps(one('innim_lib', {'hosted': 'http://pub.example.org'}),
          self: Uri.parse('https://pub.example.org:443'));

      expect(result['innim_lib']['hosted'], 'https://pub.example.org');
    });

    test('a non-default port is carried over to the old address', () {
      var result = deps(
          one('innim_lib', {'hosted': 'http://pub.example.org:8443'}),
          self: Uri.parse('https://pub.example.org:8443'));

      expect(result['innim_lib']['hosted'], 'https://pub.example.org:8443');
    });

    test('the same host on http without that port is a different repository',
        () {
      var result = deps(one('innim_lib', {'hosted': 'http://pub.example.org'}),
          self: Uri.parse('https://pub.example.org:8443'));

      expect(result['innim_lib']['hosted'], 'http://pub.example.org');
    });

    test('an ipv6 literal keeps its brackets', () {
      var result = deps(one('innim_lib', {'hosted': 'http://[::1]:4000'}),
          self: Uri.parse('https://[::1]:4000'));

      expect(result['innim_lib']['hosted'], 'https://[::1]:4000');
    });

    test('nothing is rewritten when this server answers over http', () {
      // No https counterpart to move away from, so an unconfigured
      // http deployment leaves every pubspec exactly as published.
      var pubspec = one('innim_lib', {'hosted': 'http://pub.example.org'});

      expect(
          compat.rewrite(pubspec,
              canonical: Uri.parse('http://pub.example.org')),
          same(pubspec));
    });
  });

  group('additional legacy addresses', () {
    final retired =
        HostedUrlCompat(legacyUrls: [Uri.parse('http://pub.old.example.org')]);

    test('a retired hostname is rewritten to the current address', () {
      var result = deps(
          one('innim_lib', {'hosted': 'http://pub.old.example.org'}),
          using: retired);

      expect(result['innim_lib']['hosted'], 'https://pub.example.org');
    });

    test('the derived http counterpart still applies alongside it', () {
      var result = deps(one('innim_lib', {'hosted': 'http://pub.example.org'}),
          using: retired);

      expect(result['innim_lib']['hosted'], 'https://pub.example.org');
    });

    test('a hostname that was not listed is left alone', () {
      var result = deps(
          one('innim_lib', {'hosted': 'http://pub.older.example.org'}),
          using: retired);

      expect(result['innim_lib']['hosted'], 'http://pub.older.example.org');
    });

    test('listing the current address rewrites nothing', () {
      var self = HostedUrlCompat(legacyUrls: [canonical]);
      var pubspec = one('innim_lib', {'hosted': 'https://pub.example.org'});

      expect(self.rewrite(pubspec, canonical: canonical), same(pubspec));
    });
  });

  group('other sections', () {
    test('dev_dependencies are rewritten', () {
      var result = deps(
          one('innim_lint', {'hosted': 'http://pub.example.org'},
              section: 'dev_dependencies'),
          section: 'dev_dependencies');

      expect(result['innim_lint']['hosted'], 'https://pub.example.org');
    });

    test('dependency_overrides are rewritten', () {
      var result = deps(
          one('innim_lib', {'hosted': 'http://pub.example.org'},
              section: 'dependency_overrides'),
          section: 'dependency_overrides');

      expect(result['innim_lib']['hosted'], 'https://pub.example.org');
    });

    test('every section of one pubspec is covered at once', () {
      var pubspec = {
        'name': 'p',
        'version': '1.0.0',
        'dependencies': {
          'a': {'hosted': 'http://pub.example.org', 'version': '^1.0.0'},
        },
        'dev_dependencies': {
          'b': {'hosted': 'http://pub.example.org'},
        },
        'dependency_overrides': {
          'c': {'hosted': 'http://pub.example.org'},
        },
      };

      var result = compat.rewrite(pubspec, canonical: canonical);

      expect(result['dependencies']['a']['hosted'], 'https://pub.example.org');
      expect(
          result['dev_dependencies']['b']['hosted'], 'https://pub.example.org');
      expect(result['dependency_overrides']['c']['hosted'],
          'https://pub.example.org');
    });

    test('a section that is not a map is left alone', () {
      var pubspec = {'name': 'p', 'dependencies': 'nonsense'};
      expect(compat.rewrite(pubspec, canonical: canonical), same(pubspec));
    });
  });

  group('the layer as a whole', () {
    test('applying it twice changes nothing the second time', () {
      var pubspec = one('innim_lib', {
        'hosted': 'http://pub.example.org',
        'version': '^1.0.0',
      });

      var once = compat.rewrite(pubspec, canonical: canonical);
      var twice = compat.rewrite(once, canonical: canonical);

      expect(twice, same(once));
    });

    test('the stored pubspec is never written through', () {
      var stored = one('innim_lib', {
        'hosted': {'name': 'innim_lib', 'url': 'http://pub.example.org'},
      });
      var storedHosted = stored['dependencies']['innim_lib']['hosted'];

      compat.rewrite(stored, canonical: canonical);

      expect(stored['dependencies']['innim_lib']['hosted']['url'],
          'http://pub.example.org',
          reason: 'the map belongs to the metadata this request loaded');
      expect(storedHosted['url'], 'http://pub.example.org');
    });

    test('switched off, it serves exactly what was published', () {
      var off = HostedUrlCompat.disabled();
      var pubspec = one('innim_lib', {'hosted': 'http://pub.example.org'});

      expect(off.rewrite(pubspec, canonical: canonical), same(pubspec));
    });

    test('untouched keys of the pubspec are carried through', () {
      var pubspec = {
        'name': 'innim_iap_google_apple',
        'version': '1.0.0',
        'environment': {'sdk': '>=3.0.0 <4.0.0'},
        'dependencies': {
          'innim_lib': {'hosted': 'http://pub.example.org'},
          'collection': '^1.15.0',
        },
      };

      var result = compat.rewrite(pubspec, canonical: canonical);

      expect(result['name'], 'innim_iap_google_apple');
      expect(result['version'], '1.0.0');
      expect(result['environment'], {'sdk': '>=3.0.0 <4.0.0'});
      expect(result['dependencies']['collection'], '^1.15.0');
      expect(result.keys.toList(),
          ['name', 'version', 'environment', 'dependencies']);
    });
  });
}

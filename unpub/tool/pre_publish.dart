import 'dart:io';
import 'package:path/path.dart' as path;

var files = ['index.html', 'main.dart.js'];

main(List<String> args) {
  for (var file in files) {
    var content =
        File(path.absolute('unpub_web/build', file)).readAsStringSync();
    // Escape backslashes and dollar signs for Dart triple-quoted strings.
    content = content.replaceAll('\\', '\\\\').replaceAll('\$', '\\\$');
    // After escaping, {{$VAR_NAME}} became {{\$VAR_NAME}}.
    // Replace those with actual Dart string interpolation expressions.
    content = content.replaceAllMapped(
      RegExp(r'\{\{\\\$([A-Z][A-Z0-9_]*)\}\}'),
      (m) => "\${vars['${m.group(1)}'] ?? ''}",
    );
    File(path.absolute('unpub/lib/src/static', '$file.dart'))
        .writeAsStringSync(
      'String content(Map<String, String> vars) => """$content""";\n',
    );
  }
}

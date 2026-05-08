# CLAUDE.md

## Project overview

Private Dart pub server (`in_pub`). Two main packages:

- `unpub/` — Dart server (Shelf). Entry point: `unpub/bin/in_pub.dart`
- `unpub_web/` — AngularDart web UI (ngdart 8.x dev)

## Commands

```
make build      # build web UI and embed it into the server package
make dev-web    # serve web UI with hot reload (webdev)
make dev-api    # watch and rebuild server code
```

All Makefile targets use `fvm dart`. Never use bare `dart` commands here.

## Build pipeline

`make build` does three things in sequence:

1. `dart run build_runner build --release` — compiles Angular app to `unpub_web/build/`
2. `dart unpub/tool/pre_publish.dart` — reads `build/index.html` and `build/main.dart.js`,
   generates `unpub/lib/src/static/index.html.dart` and `main.dart.js.dart` as Dart source files
3. `dart format` — formats Dart files

The generated static files are committed to the repo so the server has no build-time dependency.

## HTML template variables

`index.html` supports server-side template substitution using the syntax `{{$VAR_NAME}}` where
`VAR_NAME` is UPPER_SNAKE_CASE.

`pre_publish.dart` replaces these at **build time** with Dart string interpolation expressions
(`${vars['VAR_NAME'] ?? ''}`), producing a `content(Map<String, String> vars)` function.
The server calls `index_html.content({'APP_VERSION': version})` — no runtime regex.

To add a new template variable:
1. Add `{{$YOUR_VAR}}` to `unpub_web/web/index.html`
2. Run `make build`
3. Pass the value in the map in `unpub/lib/src/app.dart`

## Dependencies

- Web UI uses `ngdart 8.0.0-dev.4` (and matching dev versions of ngforms/ngrouter).
  Stable ngdart 7.x is incompatible with Dart 3.x due to a bug in ngcompiler.
- `build_web_compilers 4.x` and `frontend_server_client 4.x` are required.
  Do **not** downgrade these — older versions fail with fvm's Dart SDK (missing
  `frontend_server.dart.snapshot`).

## Rules

- **Never modify files in `~/.pub-cache/`**. Not an option under any circumstances.
- Use `fvm dart` / `fvm flutter`, not bare `dart`.
- Do not use `dependency_overrides` or dev package versions unless there is truly no
  stable alternative (ngdart 8.x dev is the documented exception).

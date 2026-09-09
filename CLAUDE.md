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

## Before handing work over

Mandatory, every time — not "when the change looks risky". Run all four from
`unpub/` and report what they said:

```
fvm dart pub get
fvm dart analyze
fvm dart format --output=none --set-exit-if-changed .
fvm dart test
```

These are exactly what CI runs (`.github/workflows/analyze-and-test.yml`). A
change is not done until they are green locally; reporting it done on anything
less is how a red CI gets handed over.

`dart test` needs MongoDB on `localhost:27017`. CI runs the suite against
**both** versions of its matrix, and they disagree: MongoDB removed the legacy
OP_QUERY opcode in 5.1, so a mongo_dart call implemented over it passes on
5.0.6 (what the deployment runs) and is refused on 7 (what it would be upgraded
to). `.dev/docker-compose.yml` starts 5.0.6 only, so testing against it alone
is not testing the matrix — run the suite a second time against `mongo:7`.

## Changelog and commit messages

Keep both compact. Length is not evidence of care.

- `CHANGELOG.md` records only what a user of the server needs to know: what changed
  and, where it matters, what they have to do about it. One short entry per change.
  Reasoning, alternatives weighed and implementation detail do not go here.
- A commit subject follows Conventional Commits and stands on its own. Write a body
  only when it carries something the subject cannot — a non-obvious cause, a decision
  that needed a choice, a consequence for whoever upgrades. If it can be left out,
  leave it out and ship the one line.

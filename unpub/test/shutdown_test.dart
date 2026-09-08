import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:in_pub/src/shutdown.dart';
import 'package:test/test.dart';

/// Shutting down is the one path where a hang costs more than a crash: the
/// process is on its way out, an orchestrator is counting seconds, and there
/// is nobody left to serve. What made it hang was `db.close()` — mongo_dart
/// 0.7.4 opens it with a synchronous loop that spins when the master
/// connection has gone — awaited with no bound, behind a signal handler that
/// answered a second Ctrl-C by returning silently.
///
/// The last of those is the only one that can be checked in-process; the spin
/// itself takes a child process, because reproducing it here would take the
/// test runner down with it.
void main() {
  group('in-process', () {
    late StreamController<ProcessSignal> signals;
    late Completer<int> exited;
    late List<String> steps;

    setUp(() {
      signals = StreamController<ProcessSignal>();
      exited = Completer<int>();
      steps = [];
    });

    ShutdownHandler handlerWith({
      Future<void> Function()? drain,
      void Function()? release,
      Future<void> Function()? closeDatabase,
    }) {
      final handler = ShutdownHandler(
        drain: drain ?? () async => steps.add('drain'),
        release: release ?? () => steps.add('release'),
        closeDatabase: closeDatabase ?? () async => steps.add('close'),
        databaseTimeout: const Duration(milliseconds: 50),
        signals: [signals.stream],
        log: (_) {},
        exitProcess: (code) {
          if (!exited.isCompleted) exited.complete(code);
        },
      );
      handler.install();
      addTearDown(() => signals.close());
      return handler;
    }

    test('a database that never closes does not hold the process', () async {
      handlerWith(closeDatabase: () {
        steps.add('close');
        return Completer<void>().future;
      });

      signals.add(ProcessSignal.sigterm);

      // Non-zero: the close was abandoned with the socket still open, which
      // is a step that did not finish however tidily the rest went. Exit 0
      // would tell the supervisor a shutdown had completed that had not.
      expect(await exited.future.timeout(const Duration(seconds: 5)), 1);
      expect(steps, ['drain', 'release', 'close']);
    });

    test('a shutdown where every step finishes exits 0', () async {
      handlerWith();

      signals.add(ProcessSignal.sigterm);

      expect(await exited.future.timeout(const Duration(seconds: 5)), 0);
      expect(steps, ['drain', 'release', 'close']);
    });

    test('the signals are handed back before the database close begins',
        () async {
      // The close is where the isolate stops being able to steer itself, so
      // the default disposition has to be back in place before it is entered
      // — after it, nothing runs to put it back.
      bool? listeningDuringClose;
      handlerWith(closeDatabase: () async {
        listeningDuringClose = signals.hasListener;
      });

      signals.add(ProcessSignal.sigint);

      await exited.future.timeout(const Duration(seconds: 5));
      expect(listeningDuringClose, isFalse);
    });

    test('a drain that fails still releases, and does not report success',
        () async {
      // The catch used to end in `_exit(0)`, and the throw skipped every step
      // after the drain: Mongo left open, the timer and http clients still
      // held, the signal handlers still installed — and systemd or Kubernetes
      // told the shutdown had gone cleanly.
      handlerWith(drain: () async {
        steps.add('drain');
        throw StateError('the server would not let go');
      });

      signals.add(ProcessSignal.sigterm);

      expect(await exited.future.timeout(const Duration(seconds: 5)), 1,
          reason: 'plain 1, so an operator can tell a failed shutdown from a '
              'crash (255) and from a kill (128 + the signal)');
      expect(steps, ['drain', 'release', 'close']);
      expect(signals.hasListener, isFalse);
    });

    test('one release step failing does not skip the others', () async {
      handlerWith(release: () {
        steps.add('release');
        throw StateError('a client was already closed');
      });

      signals.add(ProcessSignal.sigterm);

      expect(await exited.future.timeout(const Duration(seconds: 5)), 1);
      expect(steps, ['drain', 'release', 'close'],
          reason: 'the database still has to be closed after a release that '
              'threw');
    });

    test('a second signal ends the process instead of being swallowed',
        () async {
      final draining = Completer<void>();
      handlerWith(drain: () {
        steps.add('drain');
        draining.complete();
        return Completer<void>().future;
      });

      signals.add(ProcessSignal.sigint);
      await draining.future.timeout(const Duration(seconds: 5));
      signals.add(ProcessSignal.sigint);

      expect(await exited.future.timeout(const Duration(seconds: 5)), 130);
      expect(steps, ['drain'],
          reason: 'the second signal must not start a second shutdown');
    });
  });

  test('a database close that never yields still leaves a killable process',
      () async {
    final child = await Process.start(Platform.resolvedExecutable,
        [File('test/fixtures/wedged_shutdown.dart').absolute.path]);
    addTearDown(() => child.kill(ProcessSignal.sigkill));

    var running = true;
    final exitCode = child.exitCode..then((_) => running = false).ignore();

    final ready = Completer<void>();
    child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line == 'ready' && !ready.isCompleted) ready.complete();
    });
    await ready.future.timeout(const Duration(seconds: 60));

    child.kill(ProcessSignal.sigint);
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(running, isTrue,
        reason: 'the first signal should have carried the child into the '
            'spinning close, which is where it used to become unkillable');

    child.kill(ProcessSignal.sigint);
    expect(await exitCode.timeout(const Duration(seconds: 10)), lessThan(0),
        reason: 'a child terminated by a signal reports -signalNumber; an '
            'exit code of 130 would mean the handler was still installed '
            'and the spin was never reached');
  }, testOn: '!windows', timeout: const Timeout(Duration(minutes: 2)));
}

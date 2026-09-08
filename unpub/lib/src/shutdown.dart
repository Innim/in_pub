import 'dart:async';
import 'dart:io';

/// The one-way trip out of `main`: drain the server, release what the process
/// holds open, close the database, exit.
///
/// This lives in `lib` rather than beside `main` because the part of a
/// shutdown worth getting right is what happens when it does *not* finish,
/// and that is only observable by driving the sequence from a test.
class ShutdownHandler {
  ShutdownHandler({
    required Future<void> Function() drain,
    required void Function() release,
    required Future<void> Function() closeDatabase,
    Duration databaseTimeout = const Duration(seconds: 5),
    List<Stream<ProcessSignal>>? signals,
    void Function(Object?) log = print,
    void Function(int) exitProcess = exit,
  })  : _drain = drain,
        _release = release,
        _closeDatabase = closeDatabase,
        _databaseTimeout = databaseTimeout,
        _signals = signals,
        _log = log,
        _exit = exitProcess;

  /// The shell's convention for a process that ended on SIGINT.
  static const _interruptedExitCode = 130;

  /// A shutdown that did not finish. Plain `1` on purpose: an uncaught Dart
  /// error leaves 255 and a process killed outright reports 128 + the signal
  /// number, so an operator reading `systemctl status` can tell a drain or a
  /// release that failed from a crash and from a kill. The one code that must
  /// not be used here is 0, which is what this method used to report however
  /// badly the shutdown had gone.
  static const _failedExitCode = 1;

  final Future<void> Function() _drain;
  final void Function() _release;
  final Future<void> Function() _closeDatabase;
  final Duration _databaseTimeout;
  final List<Stream<ProcessSignal>>? _signals;
  final void Function(Object?) _log;
  final void Function(int) _exit;

  final _subscriptions = <StreamSubscription<ProcessSignal>>[];
  var _shuttingDown = false;

  /// Takes over SIGINT — and SIGTERM, which Windows cannot watch — until the
  /// shutdown reaches the point where it can no longer be steered from inside
  /// this isolate, at which point both are handed back to the operating
  /// system. See [_shutDown].
  void install() {
    final streams = _signals ??
        [
          ProcessSignal.sigint.watch(),
          if (!Platform.isWindows) ProcessSignal.sigterm.watch(),
        ];
    for (final stream in streams) {
      _subscriptions.add(stream.listen((s) => unawaited(_shutDown(s))));
    }
  }

  Future<void> _shutDown(ProcessSignal signal) async {
    // A second signal must not start a second shutdown on top of the first —
    // but refusing to start one is not the same as ignoring the operator.
    // Someone pressing Ctrl-C again has decided the graceful path has had
    // long enough, and the guard used to answer that by returning silently,
    // leaving SIGKILL as the only way out of a shutdown that had stalled.
    if (_shuttingDown) {
      _log('Received $signal again; exiting now.');
      _exit(_interruptedExitCode);
      return;
    }
    _shuttingDown = true;
    _log('Received $signal, shutting down.');

    var code = 0;
    try {
      // Drain first, then release. Closing the auth layer and the app up
      // front shut the OIDC and googleapis http clients out from under the
      // very requests this grace window exists to protect: a publish still
      // resolving its credential got `Client is already closed` instead of
      // finishing.
      await _drain();
    } catch (e) {
      // Exiting is the point; a failure on the way out must not become an
      // unhandled async error that leaves the process up. Reporting success
      // is not the way to achieve that, though, which is what this used to
      // do: the drain that never finished ended in `_exit(0)`, and the
      // supervisor was told the grace period had run its course.
      _log('Error during shutdown: the drain failed: $e');
      code = _failedExitCode;
    } finally {
      // Whether or not the drain got through. A throw out of `drain()` used
      // to skip everything below it: Mongo left open, the timer and the http
      // clients still held, and the signal handlers still installed on a
      // process that had just announced it was leaving.
      //
      // One `try` per step, for the reason `UserValidator.sweep` keeps one
      // per purge: these are independent cleanups, and the first one to fail
      // must not be what stops the rest from running.
      var released =
          await _step('releasing what the process holds open', _release);

      // Everything past this line runs with the signal handlers uninstalled,
      // because closing the database is the one step this isolate cannot be
      // talked out of. mongo_dart 0.7.4's `_ConnectionManager.close()` opens
      // with `while (sendQueue.isNotEmpty) { masterConnection?._sendBuffer(); }`
      // — and when the master connection has been dropped, which is precisely
      // what a wedged or vanished Mongo leaves behind, the body is a no-op
      // and the loop spins without ever yielding. It is synchronous and it
      // runs before the first `await` inside `close()`, so merely calling it
      // is enough: no timer fires afterwards, no queued signal is delivered,
      // and the `.timeout` below can never trigger. Cancelling the
      // subscriptions restores the default disposition of SIGINT and SIGTERM,
      // which the operating system applies without the Dart event loop having
      // to turn again — so the next signal ends the process instead of
      // needing SIGKILL.
      var handedBack = await _step('handing the signals back', _releaseSignals);

      // The timeout still earns its place for the half of the close that is
      // genuinely asynchronous: it ends in `await socket.close()`, which
      // stalls for as long as a peer that has stopped reading keeps the
      // connection half-open.
      var closedInTime = true;
      var closed = await _step(
          'closing the database',
          () => _closeDatabase().timeout(_databaseTimeout, onTimeout: () {
                // Abandoned, not tolerated. `onTimeout` returning normally
                // makes the step look like it succeeded, but the socket is
                // still open and the cleanup was given up on — which is a
                // step that did not finish, and exactly what
                // [_failedExitCode] promises an operator can tell apart. The
                // log line is what says *which* step; the code is what makes
                // anything notice.
                //
                // So a stop where the database socket would not close leaves
                // the unit `failed` in `systemctl status` rather than
                // `inactive (dead)`. That is deliberate: it is the only trace
                // an operator gets that the process left a connection behind,
                // and a shutdown that routinely trips it is a deployment
                // worth looking at, not a message worth suppressing. Raise
                // `databaseTimeout` if a slow peer makes it noise.
                _log('Database did not close within $_databaseTimeout; '
                    'exiting anyway.');
                closedInTime = false;
              }));

      if (!released || !handedBack || !closed || !closedInTime) {
        code = _failedExitCode;
      }
    }
    _exit(code);
  }

  /// Runs one step of the shutdown, saying whether it got through rather than
  /// letting it end the rest. See [_shutDown].
  Future<bool> _step(String what, FutureOr<void> Function() work) async {
    try {
      await work();
      return true;
    } catch (e) {
      _log('Error during shutdown: $what failed: $e');
      return false;
    }
  }

  Future<void> _releaseSignals() async {
    final cancelled = [for (final s in _subscriptions) s.cancel()];
    _subscriptions.clear();
    await Future.wait(cancelled);
  }
}

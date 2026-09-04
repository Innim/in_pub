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
    try {
      // Drain first, then release. Closing the auth layer and the app up
      // front shut the OIDC and googleapis http clients out from under the
      // very requests this grace window exists to protect: a publish still
      // resolving its credential got `Client is already closed` instead of
      // finishing.
      await _drain();
      _release();

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
      await _releaseSignals();

      // The timeout still earns its place for the half of the close that is
      // genuinely asynchronous: it ends in `await socket.close()`, which
      // stalls for as long as a peer that has stopped reading keeps the
      // connection half-open.
      await _closeDatabase().timeout(_databaseTimeout, onTimeout: () {
        _log('Database did not close within $_databaseTimeout; '
            'exiting anyway.');
      });
    } catch (e) {
      // Exiting is the point; a failure on the way out must not become an
      // unhandled async error that leaves the process up.
      _log('Error during shutdown: $e');
    }
    _exit(0);
  }

  Future<void> _releaseSignals() async {
    final cancelled = [for (final s in _subscriptions) s.cancel()];
    _subscriptions.clear();
    await Future.wait(cancelled);
  }
}

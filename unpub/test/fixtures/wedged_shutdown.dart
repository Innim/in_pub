// Not a test: the child process driven by `test/shutdown_test.dart`.
//
// It installs the real [ShutdownHandler] behind a database close that
// reproduces the shape of mongo_dart's `_ConnectionManager.close()` — a
// synchronous loop entered before the first `await`, whose condition nothing
// arriving later can change. Once the shutdown reaches it this isolate never
// runs another line, so the only thing that can still end this process is a
// signal the operating system disposes of itself.
import 'package:in_pub/src/shutdown.dart';

final _never = DateTime.utc(9999);

void main() {
  ShutdownHandler(
    drain: () async {},
    release: () {},
    closeDatabase: () async {
      while (DateTime.now().isBefore(_never)) {}
    },
  ).install();
  print('ready');
}

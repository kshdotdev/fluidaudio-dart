import 'dart:async';

/// Backstop that releases native resources (CoreML models are hundreds of MB)
/// when an instance is garbage-collected without an explicit `dispose()`.
///
/// Every instance attaches itself on creation and detaches in `dispose()`;
/// the attached closure must capture the host API and id as locals — never
/// the instance itself, or it would never become unreachable.
final Finalizer<void Function()> nativeDisposeFinalizer =
    Finalizer((dispose) => dispose());

/// Wraps an async native dispose call for use from the finalizer, where
/// errors have nowhere to go.
void Function() finalizerDispose(Future<void> Function() dispose) {
  return () {
    unawaited(dispose().catchError((Object _) {}));
  };
}

import 'dart:async';

/// Emits ticks aligned to the wall-clock second.
/// The first tick waits for the remaining milliseconds of the current second,
/// then emits every 1000 ms thereafter.
Stream<DateTime> alignedSecondTicks() async* {
  final now = DateTime.now();
  final initialDelay = Duration(milliseconds: (1000 - now.millisecond) % 1000);
  if (initialDelay > Duration.zero) {
    await Future<void>.delayed(initialDelay);
  }
  yield DateTime.now();
  yield* Stream<DateTime>.periodic(const Duration(seconds: 1), (_) => DateTime.now());
}

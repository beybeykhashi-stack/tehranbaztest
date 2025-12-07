import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

import 'schedule.dart';

class PlayerController extends ChangeNotifier {
  PlayerController(this.schedule) {
    _player = Player(configuration: const PlayerConfiguration());
    _positionSubscription = _player.stream.position.listen((position) {
      audioPosition = position;
      notifyListeners();
    });
    _player.stream.duration.listen((duration) {
      if (duration != Duration.zero) {
        currentTrackDuration = duration;
        notifyListeners();
      }
    });
    _player.stream.completed.listen((_) {
      _handleCompletion();
    });
    _player.stream.error.listen((error) {
      _setError('Playback error: $error');
    });
  }

  DaySchedule schedule;
  late final Player _player;
  late final StreamSubscription<Duration> _positionSubscription;

  int currentIndex = 0;
  Duration currentTrackDuration = Duration.zero;
  Duration audioPosition = Duration.zero;
  bool playing = false;
  double volume = 1.0;
  String? errorMessage;

  bool _disposed = false;

  bool get hasError => errorMessage != null;

  void clearError() {
    if (errorMessage != null) {
      errorMessage = null;
      notifyListeners();
    }
  }

  Future<void> disposeAsync() async {
    if (_disposed) return;
    _disposed = true;
    await _positionSubscription.cancel();
    await _player.dispose();
  }

  @override
  void dispose() {
    if (_disposed) {
      super.dispose();
      return;
    }
    _disposed = true;
    unawaited(_positionSubscription.cancel());
    _player.dispose();
    super.dispose();
  }

  Future<void> setVolume(double value) async {
    volume = value.clamp(0.0, 1.0);
    await _player.setVolume(volume);
    notifyListeners();
  }

  Future<void> playForNow(DateTime now) async {
    final nowSec = nowSecondsOfDay(now);
    final index = schedule.indexForSecond(nowSec);
    await _playIndex(index, nowSec: nowSec);
  }

  Future<void> updateSchedule(DaySchedule newSchedule) async {
    schedule = newSchedule;
    final nowSec = nowSecondsOfDay(DateTime.now());
    currentIndex = schedule.indexForSecond(nowSec);
    await _playIndex(currentIndex, nowSec: nowSec);
  }

  Future<void> resyncIfDrifted(DateTime now) async {
    if (!playing) {
      return;
    }
    final nowSec = nowSecondsOfDay(now);
    final expectedIndex = schedule.indexForSecond(nowSec);
    if (expectedIndex != currentIndex) {
      await _playIndex(expectedIndex, nowSec: nowSec);
      return;
    }
    final entry = schedule.entries[currentIndex];
    final expectedOffset = schedule.offsetSinceStart(nowSec);
    final seekDuration = _offsetToSeek(expectedOffset, entry, currentTrackDuration);
    final diffMs = (_player.state.position - seekDuration).inMilliseconds.abs();
    if (diffMs > 250) {
      await _player.seek(seekDuration);
    }
  }

  Future<void> toggle() async {
    if (playing) {
      await _player.pause();
      playing = false;
    } else {
      await _player.play();
      playing = true;
    }
    notifyListeners();
  }

  Future<void> next() async {
    final nextIndex = schedule.nextIndex(currentIndex);
    await _playIndex(nextIndex, nowSec: schedule.entries[nextIndex].startSec, explicitSeek: Duration.zero);
  }

  String get currentFile => schedule.entries[currentIndex].file;

  Future<void> _playIndex(
    int index, {
    required int nowSec,
    Duration? explicitSeek,
    int attempts = 0,
  }) async {
    if (attempts >= schedule.entries.length) {
      _setError('No playable tracks in schedule.');
      return;
    }
    clearError();
    currentIndex = index;
    final entry = schedule.entries[index];
    final media = await _resolveMedia(entry.file);
    if (media == null) {
      _setError('Missing audio file: ${entry.file}');
      await _skipToNextAvailable(attempts: attempts + 1);
      return;
    }
    try {
      await _player.open(media, play: false);
    } catch (err) {
      _setError('Unable to open ${entry.file}: $err');
      await _skipToNextAvailable(attempts: attempts + 1);
      return;
    }
    final duration = await _player.stream.duration.firstWhere(
      (d) => d != Duration.zero,
      orElse: () => Duration.zero,
    );
    currentTrackDuration = duration;
    final seekDuration = explicitSeek ?? _offsetToSeek(schedule.offsetSinceStart(nowSec), entry, duration);
    await _player.seek(seekDuration);
    await _player.setVolume(volume);
    await _player.play();
    playing = true;
    audioPosition = seekDuration;
    notifyListeners();
  }

  Duration _offsetToSeek(int offsetSeconds, ScheduleEntry entry, Duration duration) {
    if (duration == Duration.zero) {
      return Duration(seconds: offsetSeconds);
    }
    final durationMs = duration.inMilliseconds;
    if (durationMs <= 0) {
      return Duration(seconds: offsetSeconds);
    }
    final offsetMs = offsetSeconds * 1000;
    if (entry.loopWithinSlot) {
      final seekMs = offsetMs % durationMs;
      return Duration(milliseconds: seekMs);
    }
    final clamped = offsetMs.clamp(0, durationMs) as int;
    return Duration(milliseconds: clamped);
  }

  Future<void> _skipToNextAvailable({int attempts = 0}) async {
    final nextIndex = schedule.nextIndex(currentIndex);
    await _playIndex(
      nextIndex,
      nowSec: schedule.entries[nextIndex].startSec,
      explicitSeek: Duration.zero,
      attempts: attempts,
    );
  }

  Future<Media?> _resolveMedia(String filePath) async {
    if (filePath.startsWith('http://') || filePath.startsWith('https://')) {
      return Media(filePath);
    }
    if (filePath.startsWith('asset://')) {
      return Media(filePath);
    }
    try {
      await rootBundle.load(filePath);
      final normalized = filePath.startsWith('/') ? filePath.substring(1) : filePath;
      return Media('asset:///$normalized');
    } catch (_) {
      final file = File(filePath);
      if (file.existsSync()) {
        return Media(p.toUri(file.absolute.path).toString());
      }
    }
    return null;
  }

  void _handleCompletion() {
    final entry = schedule.entries[currentIndex];
    if (entry.loopWithinSlot && currentTrackDuration > Duration.zero) {
      _player.seek(Duration.zero);
      _player.play();
    } else {
      unawaited(next());
    }
  }

  void _setError(String message) {
    errorMessage = message;
    notifyListeners();
  }
}

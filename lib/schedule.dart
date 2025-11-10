import 'dart:convert';
import 'dart:developer';

import 'package:flutter/services.dart' show rootBundle;

class ScheduleEntry {
  ScheduleEntry({
    required this.startSec,
    required this.file,
    required this.loopWithinSlot,
  });

  final int startSec; // seconds from midnight
  final String file;
  final bool loopWithinSlot;

  String get startLabel => _formatTime(startSec);

  static String _formatTime(int sec) {
    final h = (sec ~/ 3600).toString().padLeft(2, '0');
    final m = ((sec % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  @override
  String toString() => 'ScheduleEntry(start: ${startLabel}, file: $file, loop: $loopWithinSlot)';
}

class DaySchedule {
  DaySchedule(this.entries);

  final List<ScheduleEntry> entries;

  /// Returns the index of the entry that should be active for [nowSec].
  /// Slots are [start_i, start_{i+1}) with wrap at 24h.
  int indexForSecond(int nowSec) {
    if (entries.isEmpty) {
      throw StateError('Schedule is empty.');
    }
    nowSec = nowSec % secondsPerDay;
    if (entries.length == 1) {
      return 0;
    }
    // Fast path for wrap-around and extremes.
    if (nowSec < entries.first.startSec || nowSec >= entries.last.startSec) {
      return entries.length - 1;
    }
    var lo = 0;
    var hi = entries.length - 2; // ensure mid + 1 valid
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final cur = entries[mid].startSec;
      final next = entries[mid + 1].startSec;
      if (nowSec >= cur && nowSec < next) {
        return mid;
      }
      if (nowSec < cur) {
        hi = mid - 1;
      } else {
        lo = mid + 1;
      }
    }
    return entries.length - 1;
  }

  int nextIndex(int index) => (index + 1) % entries.length;

  /// Seconds since the start of the slot that contains [nowSec].
  int offsetSinceStart(int nowSec) {
    nowSec = nowSec % secondsPerDay;
    final index = indexForSecond(nowSec);
    final start = entries[index].startSec;
    if (nowSec >= start) {
      return nowSec - start;
    }
    // Wrap-around case: slot started before midnight
    return (secondsPerDay - start) + nowSec;
  }

  /// Seconds remaining until the next slot boundary.
  int secondsUntilNextBoundary(int nowSec) {
    nowSec = nowSec % secondsPerDay;
    final index = indexForSecond(nowSec);
    final current = entries[index];
    final next = entries[nextIndex(index)];
    if (next.startSec > current.startSec) {
      return next.startSec - nowSec;
    }
    // Wrap to midnight.
    return (secondsPerDay - nowSec) + next.startSec;
  }

  ScheduleEntry operator [](int index) => entries[index];

  static const secondsPerDay = 24 * 60 * 60;
}

Future<DaySchedule> loadScheduleFromAssets(String path) async {
  try {
    final raw = await rootBundle.loadString(path);
    final List<dynamic> jsonList = json.decode(raw) as List<dynamic>;
    final entries = <ScheduleEntry>[];
    for (final item in jsonList) {
      if (item is! Map<String, dynamic>) {
        throw FormatException('Schedule entries must be JSON objects.');
      }
      final start = (item['start'] as String?)?.trim();
      final file = (item['file'] as String?)?.trim();
      final loop = item['loopWithinSlot'] as bool? ?? true;
      if (start == null || file == null) {
        throw FormatException('Schedule entry requires both "start" and "file".');
      }
      final parts = start.split(':');
      if (parts.length != 3) {
        throw FormatException('Invalid time "$start". Use HH:mm:ss.');
      }
      final h = int.parse(parts[0]);
      final m = int.parse(parts[1]);
      final s = int.parse(parts[2]);
      if (h < 0 || h > 23 || m < 0 || m > 59 || s < 0 || s > 59) {
        throw FormatException('Time "$start" is out of range.');
      }
      final startSec = h * 3600 + m * 60 + s;
      entries.add(ScheduleEntry(startSec: startSec, file: file, loopWithinSlot: loop));
    }
    if (entries.isEmpty) {
      throw StateError('Schedule has no entries.');
    }
    entries.sort((a, b) => a.startSec.compareTo(b.startSec));
    if (entries.first.startSec != 0) {
      throw StateError('Schedule must begin at 00:00:00.');
    }
    for (var i = 0; i < entries.length - 1; i++) {
      if (entries[i + 1].startSec == entries[i].startSec) {
        throw StateError('Duplicate start time at ${entries[i].startLabel}.');
      }
      if (entries[i + 1].startSec < entries[i].startSec) {
        throw StateError('Schedule times must be strictly increasing.');
      }
    }
    if (entries.last.startSec >= DaySchedule.secondsPerDay) {
      throw StateError('Start times must be within 24-hour day.');
    }
    log('Loaded schedule with ${entries.length} entries.');
    return DaySchedule(entries);
  } catch (e, st) {
    log('Failed to load schedule from $path: $e', stackTrace: st);
    rethrow;
  }
}

int nowSecondsOfDay(DateTime now) => now.hour * 3600 + now.minute * 60 + now.second;

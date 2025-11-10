import 'package:chronoplayer/schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DaySchedule', () {
    final schedule = DaySchedule([
      ScheduleEntry(startSec: 0, file: 'a.mp3', loopWithinSlot: true),
      ScheduleEntry(startSec: 3600, file: 'b.mp3', loopWithinSlot: true),
      ScheduleEntry(startSec: 7200, file: 'c.mp3', loopWithinSlot: true),
    ]);

    test('indexForSecond respects boundaries', () {
      expect(schedule.indexForSecond(0), 0);
      expect(schedule.indexForSecond(3599), 0);
      expect(schedule.indexForSecond(3600), 1);
      expect(schedule.indexForSecond(7199), 1);
      expect(schedule.indexForSecond(7200), 2);
      expect(schedule.indexForSecond(86399), 2);
      expect(schedule.indexForSecond(10), 0);
    });

    test('offsetSinceStart handles wrap-around', () {
      final lateNight = 23 * 3600 + 59 * 60 + 50;
      expect(schedule.indexForSecond(lateNight), 2);
      expect(schedule.offsetSinceStart(lateNight), lateNight - schedule.entries[2].startSec);
      // Early-morning time belongs to first slot.
      expect(schedule.offsetSinceStart(10), 10);
    });

    test('secondsUntilNextBoundary covers wrap', () {
      expect(schedule.secondsUntilNextBoundary(0), 3600);
      expect(schedule.secondsUntilNextBoundary(3599), 1);
      expect(schedule.secondsUntilNextBoundary(3600), 3600);
      expect(schedule.secondsUntilNextBoundary(86399), 1);
    });
  });
}

import 'package:Kelivo/core/agency/cycle_log.dart';
import 'package:flutter_test/flutter_test.dart';

CyclePeriod _p(DateTime start, int days) => CyclePeriod(
  start: start,
  end: start.add(Duration(days: days - 1)),
);

void main() {
  final jan1 = DateTime(2026, 1, 1);

  test('nothing logged says nothing', () {
    const log = CycleLog();
    expect(log.statusOn(jan1), isNull);
    expect(log.companionContext(jan1), isNull);
  });

  test('averages come from recent cycles', () {
    final log = const CycleLog().copyWith(
      periods: [
        _p(DateTime(2026, 1, 1), 5),
        _p(DateTime(2025, 12, 2), 6),
        _p(DateTime(2025, 11, 2), 4),
      ],
    );
    expect(log.averageCycleLength, 30);
    expect(log.averagePeriodLength, 5);
  });

  test('phases across a 28-day cycle', () {
    final log = const CycleLog().copyWith(
      periods: [_p(jan1, 5), _p(DateTime(2025, 12, 4), 5)],
    );
    CyclePhase on(int cycleDay) =>
        log.statusOn(jan1.add(Duration(days: cycleDay - 1)))!.phase;

    expect(on(3), CyclePhase.period);
    expect(on(8), CyclePhase.follicular);
    expect(on(14), CyclePhase.ovulation);
    expect(on(20), CyclePhase.luteal);
    expect(on(26), CyclePhase.premenstrual);
    expect(on(29), CyclePhase.premenstrual); // the predicted day itself
    expect(on(31), CyclePhase.late);
  });

  test('start and end today', () {
    var log = const CycleLog().startOn(jan1);
    expect(log.latest!.ongoing, isTrue);
    expect(log.statusOn(jan1.add(const Duration(days: 1)))!.cycleDay, 2);
    log = log.endOn(jan1.add(const Duration(days: 4)));
    expect(log.latest!.length, 5);
  });

  test('a forgotten end is closed when the next one starts', () {
    final log = const CycleLog().startOn(jan1).startOn(DateTime(2026, 1, 30));
    expect(log.periods, hasLength(2));
    expect(log.periods[1].length, CycleLog.defaultPeriodLength);
  });

  test('context respects the switch', () {
    final log = const CycleLog().startOn(jan1);
    expect(log.companionContext(jan1), contains('经期第 1 天'));
    expect(
      log.copyWith(shareWithCompanion: false).companionContext(jan1),
      isNull,
    );
  });

  test('survives a round trip', () {
    final log = const CycleLog().startOn(jan1).endOn(DateTime(2026, 1, 5));
    final back = CycleLog.fromJson(log.toJson());
    expect(back.latest!.start, jan1);
    expect(back.latest!.length, 5);
  });
}

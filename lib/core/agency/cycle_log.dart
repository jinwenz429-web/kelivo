import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';

/// One logged period: the day it started and, once over, the day it ended.
/// Dates are calendar days (local midnight).
@immutable
class CyclePeriod {
  const CyclePeriod({required this.start, this.end});

  final DateTime start;
  final DateTime? end;

  bool get ongoing => end == null;

  /// Length in days, counting both ends.
  int? get length => end == null ? null : _daysBetween(start, end!) + 1;

  CyclePeriod copyWith({
    DateTime? start,
    DateTime? end,
    bool clearEnd = false,
  }) => CyclePeriod(
    start: start ?? this.start,
    end: clearEnd ? null : end ?? this.end,
  );

  Map<String, Object?> toJson() => {
    'start': _dayKey(start),
    if (end != null) 'end': _dayKey(end!),
  };

  static CyclePeriod? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final start = DateTime.tryParse(raw['start']?.toString() ?? '');
    if (start == null) return null;
    final end = DateTime.tryParse(raw['end']?.toString() ?? '');
    return CyclePeriod(
      start: calendarDay(start),
      end: end == null ? null : calendarDay(end),
    );
  }
}

enum CyclePhase {
  /// Bleeding days.
  period,

  /// After the period, before the fertile window.
  follicular,

  /// A few days around the estimated ovulation day.
  ovulation,

  /// After ovulation, more than a few days before the next period.
  luteal,

  /// The last days of the luteal phase, right before the next period.
  premenstrual,

  /// Past the expected start with nothing logged yet.
  late,
}

/// Where today sits in the cycle, estimated from the log.
@immutable
class CycleStatus {
  const CycleStatus({
    required this.phase,
    required this.cycleDay,
    required this.cycleLength,
    required this.periodLength,
    required this.nextStart,
    required this.basedOnCycles,
  });

  final CyclePhase phase;

  /// 1-based day of the current cycle (day 1 = the last logged start).
  final int cycleDay;

  /// Average cycle length used for the estimate.
  final int cycleLength;

  /// Average period length used for the estimate.
  final int periodLength;

  final DateTime nextStart;

  /// How many full cycles the averages come from; 0 means defaults.
  final int basedOnCycles;

  int daysUntilNext(DateTime today) =>
      _daysBetween(calendarDay(today), nextStart);
}

/// The local period log. Only the latest periods matter for the estimate.
@immutable
class CycleLog {
  const CycleLog({this.periods = const [], this.shareWithCompanion = true});

  static const defaultCycleLength = 28;
  static const defaultPeriodLength = 5;

  /// Newest first.
  final List<CyclePeriod> periods;

  /// Whether the companion gets the one-line status with each request.
  final bool shareWithCompanion;

  CyclePeriod? get latest => periods.isEmpty ? null : periods.first;

  CycleLog copyWith({List<CyclePeriod>? periods, bool? shareWithCompanion}) =>
      CycleLog(
        periods: periods == null ? this.periods : _sorted(periods),
        shareWithCompanion: shareWithCompanion ?? this.shareWithCompanion,
      );

  /// Starts a period on [day], unless one is already going. A start left
  /// open for weeks (the end was never tapped) is closed at the usual length.
  CycleLog startOn(DateTime day) {
    final start = calendarDay(day);
    if (periods.any((p) => _sameDay(p.start, start))) return this;
    var rest = periods;
    if (latest case final p? when p.ongoing) {
      if (_daysBetween(p.start, start) < 15) return this;
      final end = _addDays(p.start, averagePeriodLength - 1);
      rest = [p.copyWith(end: end), ...periods.skip(1)];
    }
    return copyWith(
      periods: [
        CyclePeriod(start: start),
        ...rest,
      ],
    );
  }

  /// Ends the ongoing period on [day].
  CycleLog endOn(DateTime day) {
    final current = latest;
    if (current == null || !current.ongoing) return this;
    final end = calendarDay(day);
    final safeEnd = end.isBefore(current.start) ? current.start : end;
    return copyWith(
      periods: [
        current.copyWith(end: safeEnd),
        ...periods.skip(1),
      ],
    );
  }

  /// Adds a period logged after the fact.
  CycleLog add(CyclePeriod period) => copyWith(periods: [period, ...periods]);

  CycleLog replace(CyclePeriod old, CyclePeriod next) => copyWith(
    periods: [for (final p in periods) identical(p, old) ? next : p],
  );

  CycleLog remove(CyclePeriod period) => copyWith(
    periods: [
      for (final p in periods)
        if (!identical(p, period)) p,
    ],
  );

  /// Gaps between consecutive starts, newest first, skipping implausible
  /// ones (a missed log or a duplicate) so they don't skew the average.
  List<int> get _recentCycleLengths {
    final lengths = <int>[];
    for (var i = 0; i + 1 < periods.length && lengths.length < 6; i++) {
      final gap = _daysBetween(periods[i + 1].start, periods[i].start);
      if (gap >= 15 && gap <= 60) lengths.add(gap);
    }
    return lengths;
  }

  int get averageCycleLength {
    final lengths = _recentCycleLengths;
    if (lengths.isEmpty) return defaultCycleLength;
    final mean = lengths.reduce((a, b) => a + b) / lengths.length;
    return mean.round().clamp(21, 45);
  }

  int get averagePeriodLength {
    final lengths = periods
        .map((p) => p.length)
        .whereType<int>()
        .where((l) => l >= 1 && l <= 12)
        .take(6)
        .toList(growable: false);
    if (lengths.isEmpty) return defaultPeriodLength;
    final mean = lengths.reduce((a, b) => a + b) / lengths.length;
    return mean.round().clamp(2, 10);
  }

  /// Null when nothing is logged or the last log is too old to say anything.
  CycleStatus? statusOn(DateTime now) {
    final last = latest;
    if (last == null) return null;
    final today = calendarDay(now);
    final cycleDay = _daysBetween(last.start, today) + 1;
    if (cycleDay < 1 || cycleDay > 75) return null;

    final cycleLength = averageCycleLength;
    final periodLength = averagePeriodLength;
    final nextStart = _addDays(last.start, cycleLength);

    final bleeding = last.ongoing
        // A start with no end: still going unless it's clearly been forgotten.
        ? cycleDay <= 10
        : !today.isAfter(last.end!);

    // Ovulation sits about 14 days before the next period.
    final ovulationDay = cycleLength - 14;
    final CyclePhase phase;
    if (bleeding) {
      phase = CyclePhase.period;
    } else if (today.isAfter(nextStart)) {
      phase = CyclePhase.late;
    } else if (cycleDay >= ovulationDay - 2 && cycleDay <= ovulationDay + 1) {
      phase = CyclePhase.ovulation;
    } else if (cycleDay < ovulationDay - 2) {
      phase = CyclePhase.follicular;
    } else if (_daysBetween(today, nextStart) <= 4) {
      phase = CyclePhase.premenstrual;
    } else {
      phase = CyclePhase.luteal;
    }

    return CycleStatus(
      phase: phase,
      cycleDay: cycleDay,
      cycleLength: cycleLength,
      periodLength: periodLength,
      nextStart: nextStart,
      basedOnCycles: _recentCycleLengths.length,
    );
  }

  /// Short status for the UI, e.g. 「经期第 2 天」「黄体期 · 大约 6 天后来」.
  static String describe(CycleStatus status, DateTime now) {
    final days = status.daysUntilNext(now);
    return switch (status.phase) {
      CyclePhase.period => '经期第 ${status.cycleDay} 天',
      CyclePhase.late => '比预计晚了 ${-days} 天',
      CyclePhase.follicular => '卵泡期 · 大约 $days 天后来',
      CyclePhase.ovulation => '排卵期前后 · 大约 $days 天后来',
      CyclePhase.luteal => '黄体期 · 大约 $days 天后来',
      CyclePhase.premenstrual =>
        days == 0 ? '经前 · 预计就是今天' : '经前 · 大约 $days 天后来',
    };
  }

  /// The block the companion sees with each request, or null to send nothing.
  String? companionContext(DateTime now) {
    if (!shareWithCompanion) return null;
    final status = statusOn(now);
    if (status == null) return null;
    final days = status.daysUntilNext(now);
    final phaseLine = switch (status.phase) {
      CyclePhase.period =>
        '经期第 ${status.cycleDay} 天（她的经期一般 ${status.periodLength} 天左右）',
      CyclePhase.late => '月经比预计晚了 ${-days} 天，还没记到这次开始',
      CyclePhase.follicular => '卵泡期（这个周期第 ${status.cycleDay} 天，预计 $days 天后来月经）',
      CyclePhase.ovulation =>
        '排卵期前后（这个周期第 ${status.cycleDay} 天，预计 $days 天后来月经）',
      CyclePhase.luteal => '黄体期（这个周期第 ${status.cycleDay} 天，预计 $days 天后来月经）',
      CyclePhase.premenstrual =>
        days == 0 ? '经前，按平时的周期预计就是今天来' : '经前，黄体期后段（预计 $days 天后来月经）',
    };
    final basis = status.basedOnCycles == 0
        ? '还没攒够记录，周期先按 ${status.cycleLength} 天估，不太准'
        : '她的周期大约 ${status.cycleLength} 天（按最近 ${status.basedOnCycles} 次记录算）';
    return [
      '[她的生理周期]',
      '这是她在手机上记的经期推算出来的，不是她刚说的话。',
      '- 现在：$phaseLine',
      '- $basis',
      '心里有数就好：不用特意提起，不用每个周期提醒她，也别说你是看了记录才知道的。'
          '她说起身体不舒服、累、情绪起伏、想吃什么，或者自己聊到这件事时，'
          '自然地把它考虑进去。',
    ].join('\n');
  }

  Map<String, Object?> toJson() => {
    'periods': [for (final p in periods) p.toJson()],
    'shareWithCompanion': shareWithCompanion,
  };

  static CycleLog fromJson(Map<String, dynamic> json) {
    final raw = json['periods'];
    return CycleLog(
      periods: _sorted([
        if (raw is List)
          for (final item in raw)
            if (CyclePeriod.fromJson(item) case final p?) p,
      ]),
      shareWithCompanion: json['shareWithCompanion'] != false,
    );
  }

  /// Newest first, capped at about four years of monthly logs.
  static List<CyclePeriod> _sorted(List<CyclePeriod> periods) =>
      ([...periods]..sort((a, b) => b.start.compareTo(a.start)))
          .take(48)
          .toList(growable: false);
}

/// Process-wide holder; persisted in [BusinessPreferences] on this phone only.
class CycleLogStore extends ChangeNotifier {
  CycleLogStore._();

  static final CycleLogStore instance = CycleLogStore._();
  static const _key = 'cycle_log_v1';

  BusinessPreferences? _preferences;
  CycleLog _value = const CycleLog();

  CycleLog get value => _value;

  void attach(BusinessPreferences preferences) {
    _preferences = preferences;
    final raw = preferences.getString(_key);
    if (raw == null) return;
    try {
      _value = CycleLog.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      _value = const CycleLog();
    }
  }

  Future<void> update(CycleLog next) async {
    _value = next;
    notifyListeners();
    await _preferences?.setString(_key, jsonEncode(next.toJson()));
  }
}

DateTime calendarDay(DateTime value) =>
    DateTime(value.year, value.month, value.day);

DateTime _addDays(DateTime day, int days) =>
    DateTime(day.year, day.month, day.day + days);

int _daysBetween(DateTime a, DateTime b) =>
    // UTC dates so daylight-saving shifts can't turn a day into 23 hours.
    DateTime.utc(
      b.year,
      b.month,
      b.day,
    ).difference(DateTime.utc(a.year, a.month, a.day)).inDays;

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dayKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

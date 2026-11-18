import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/agency/agency_follow_ups.dart';
import 'package:Kelivo/core/agency/agency_settings.dart';
import 'package:Kelivo/core/agency/agency_wake_check.dart';
import 'package:Kelivo/core/agency/companion_wake.dart';

class _FixedRandom implements math.Random {
  _FixedRandom(this.value, [this.intValue = 0]);

  final double value;
  final int intValue;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => intValue.clamp(0, max - 1);

  @override
  bool nextBool() => value < 0.5;
}

void main() {
  final now = DateTime(2026, 11, 18, 15, 0);
  const settings = AgencySettings();

  AgencyWakeDecision run(
    AgencySnapshot snapshot, {
    AgencySettings settings = settings,
    AgencyWakeMemory memory = const AgencyWakeMemory(),
    AgencyPacing pacing = const AgencyPacing(),
    double roll = 0.0,
  }) => evaluateAgencyWake(
    snapshot: snapshot,
    settings: settings,
    memory: memory,
    pacing: pacing,
    random: _FixedRandom(roll),
  );

  group('pacing', () {
    test('never interrupts an unanswered user message', () {
      final d = run(AgencySnapshot(now: now, lastMessageIsUser: true));
      expect(d.wakes, isFalse);
      expect(d.skipReason, 'user_waiting');
    });

    test('respects the daily cap, cooldown and a recent user message', () {
      final quiet = now.subtract(const Duration(hours: 8));
      expect(
        run(
          AgencySnapshot(now: now, lastMessageAt: quiet),
          pacing: const AgencyPacing(proactiveToday: 4),
        ).skipReason,
        'daily_cap',
      );
      expect(
        run(
          AgencySnapshot(now: now, lastMessageAt: quiet),
          pacing: AgencyPacing(
            lastProactiveAt: now.subtract(const Duration(minutes: 20)),
          ),
        ).skipReason,
        'cooldown',
      );
      expect(
        run(
          AgencySnapshot(
            now: now,
            lastMessageAt: now.subtract(const Duration(minutes: 3)),
            lastUserMessageAt: now.subtract(const Duration(minutes: 3)),
          ),
        ).skipReason,
        'recent_user',
      );
    });
  });

  group('occasions', () {
    test('longing grows with silence and is absent right after chatting', () {
      expect(longingChance(const Duration(hours: 1)), 0);
      expect(longingChance(const Duration(hours: 7)), closeTo(0.5, 1e-9));
      expect(longingChance(const Duration(days: 2)), 0.7);
      final d = run(
        AgencySnapshot(
          now: now,
          lastMessageAt: now.subtract(const Duration(hours: 9)),
        ),
      );
      expect(d.occasions.single.trigger, AgencyTrigger.longing);
      expect(d.occasions.single.fact, contains('9 小时'));
    });

    test('a due follow-up wins at medium unless the roll is high', () {
      final f = AgencyFollowUp(
        what: '你下午的考试',
        askAfter: now.subtract(const Duration(minutes: 30)),
        conversationId: 'c',
      );
      final snapshot = AgencySnapshot(now: now, dueFollowUps: [f]);
      expect(run(snapshot, roll: 0.79).occasions.single.fact, contains('考试'));
      final lost = run(snapshot, roll: 0.81);
      expect(lost.wakes, isFalse);
      expect(lost.skipReason, 'dice');
    });

    test('a disabled trigger is never offered', () {
      final off = settings.withTrigger(
        AgencyTrigger.headphones,
        const AgencyTriggerSetting(enabled: false),
      );
      final d = run(AgencySnapshot(now: now, headphones: true), settings: off);
      expect(d.skipReason, 'nothing_new');
    });

    test('new place needs a kilometre from the last known spot', () {
      const memory = AgencyWakeMemory(latitude: 25.0330, longitude: 121.5654);
      final near = run(
        AgencySnapshot(now: now, latitude: 25.0335, longitude: 121.5654),
        memory: memory,
      );
      expect(near.wakes, isFalse);
      final far = run(
        AgencySnapshot(now: now, latitude: 25.0478, longitude: 121.5170),
        memory: memory,
      );
      expect(far.occasions.single.trigger, AgencyTrigger.newPlace);
      expect(far.memory.latitude, 25.0478);
    });

    test('headphones and charging only count when they just changed', () {
      final evening = DateTime(2026, 11, 18, 22, 10);
      final fresh = run(
        AgencySnapshot(now: evening, headphones: true, charging: true),
      );
      expect(fresh.occasions.map((o) => o.trigger), [
        AgencyTrigger.headphones,
        AgencyTrigger.bedtimeCharging,
      ]);
      final again = run(
        AgencySnapshot(now: evening, headphones: true, charging: true),
        memory: fresh.memory,
      );
      expect(again.wakes, isFalse);
    });

    test('late night needs the screen on', () {
      final late = DateTime(2026, 11, 19, 0, 40);
      expect(run(AgencySnapshot(now: late)).wakes, isFalse);
      expect(
        run(AgencySnapshot(now: late, screenOn: true)).occasions.single.trigger,
        AgencyTrigger.lateNight,
      );
    });

    test('one-shot occasions are spent even when the roll loses', () {
      final snapshot = AgencySnapshot(
        now: now,
        batteryLevel: 12,
        charging: false,
        upcomingEvents: const [(key: 'e1', title: '组会', minutesUntil: 30)],
      );
      final lost = run(snapshot, roll: 0.99);
      expect(lost.wakes, isFalse);
      expect(lost.memory.batteryNotified, isTrue);
      expect(lost.memory.calendarKeys, contains('e1'));
      expect(run(snapshot, memory: lost.memory).wakes, isFalse);
    });

    test('levels scale the chance', () {
      final eager = settings.withTrigger(
        AgencyTrigger.headphones,
        const AgencyTriggerSetting(level: AgencyLevel.high),
      );
      final snapshot = AgencySnapshot(now: now, headphones: true);
      // medium 0.35, high 0.525
      expect(run(snapshot, roll: 0.4).wakes, isFalse);
      expect(run(snapshot, settings: eager, roll: 0.4).wakes, isTrue);
    });
  });

  test('instruction carries the facts, the note and the silence marker', () {
    final text = agencyWakeInstruction(
      snapshot: AgencySnapshot(now: now),
      occasions: const [AgencyOccasion(AgencyTrigger.headphones, '对方刚戴上了耳机。')],
      note: '我上课时别找我',
    );
    expect(text, contains('对方刚戴上了耳机。'));
    expect(text, contains('我上课时别找我'));
    expect(text, contains(companionSilenceMarker));
  });

  group('nextAgencyWake', () {
    test('lands inside the configured range', () {
      final next = nextAgencyWake(
        now: now,
        settings: settings,
        random: _FixedRandom(0, 60),
      );
      expect(next, now.add(const Duration(minutes: 150)));
    });

    test('skips the small hours', () {
      final next = nextAgencyWake(
        now: DateTime(2026, 11, 18, 23, 30),
        settings: settings,
        random: _FixedRandom(0, 150),
      );
      expect(next.hour, 8);
      final lateOk = nextAgencyWake(
        now: DateTime(2026, 11, 18, 23, 0),
        settings: settings,
        random: _FixedRandom(0, 0),
      );
      expect(lateOk, DateTime(2026, 11, 19, 0, 30));
    });
  });

  test('settings round-trip and clamp bad values', () {
    final s = settings
        .copyWith(
          model: (providerKey: 'p', modelId: 'm'),
          note: 'hi',
          wakeMinMinutes: 60,
          wakeMaxMinutes: 120,
        )
        .withTrigger(
          AgencyTrigger.lateNight,
          const AgencyTriggerSetting(enabled: false, level: AgencyLevel.low),
        );
    final back = AgencySettings.fromJson(s.toJson());
    expect(back.modelOverride, (providerKey: 'p', modelId: 'm'));
    expect(back.note, 'hi');
    expect(back.wakeMaxMinutes, 120);
    expect(back.enabled(AgencyTrigger.lateNight), isFalse);
    expect(back.trigger(AgencyTrigger.lateNight).level, AgencyLevel.low);
    expect(back.enabled(AgencyTrigger.followUp), isTrue);
    expect(
      AgencySettings.fromJson({
        'wakeMinMinutes': 5,
        'wakeMaxMinutes': 1,
      }).wakeMaxMinutes,
      30,
    );
  });

  group('parseFollowUps', () {
    test('keeps well-formed items and drops stale or far ones', () {
      final raw =
          '好的：[{"what":"你下午三点的考试","askAfter":"2026-11-18T17:00:00"},'
          '{"what":"上周的事","askAfter":"2026-11-10T10:00:00"},'
          '{"what":"下个月体检","askAfter":"2026-12-20T10:00:00"},'
          '{"what":"","askAfter":"2026-11-18T18:00:00"}]';
      final items = parseFollowUps(raw, now: now, conversationId: 'c');
      expect(items.single.what, '你下午三点的考试');
      expect(items.single.conversationId, 'c');
    });

    test('tolerates junk', () {
      expect(parseFollowUps('没有', now: now, conversationId: 'c'), isEmpty);
      expect(parseFollowUps('[oops', now: now, conversationId: 'c'), isEmpty);
    });
  });
}

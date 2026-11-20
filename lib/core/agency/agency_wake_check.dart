import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';
import 'agency_follow_ups.dart';
import 'agency_settings.dart';
import 'companion_wake.dart';

/// What the phone and the chat look like at one self-wake.
@immutable
class AgencySnapshot {
  const AgencySnapshot({
    required this.now,
    this.lastMessageAt,
    this.lastUserMessageAt,
    this.lastMessageIsUser = false,
    this.batteryLevel,
    this.charging,
    this.screenOn = false,
    this.headphones = false,
    this.latitude,
    this.longitude,
    this.screenTimeMinutes,
    this.upcomingEvents = const [],
    this.dueFollowUps = const [],
  });

  final DateTime now;
  final DateTime? lastMessageAt;
  final DateTime? lastUserMessageAt;

  /// The user spoke last and has not been answered; never interrupt that.
  final bool lastMessageIsUser;
  final int? batteryLevel;
  final bool? charging;
  final bool screenOn;
  final bool headphones;
  final double? latitude;
  final double? longitude;
  final int? screenTimeMinutes;
  final List<({String key, String title, int minutesUntil})> upcomingEvents;
  final List<AgencyFollowUp> dueFollowUps;
}

/// What the previous look saw, so changes can be noticed between wakes.
@immutable
class AgencyWakeMemory {
  const AgencyWakeMemory({
    this.latitude,
    this.longitude,
    this.headphones = false,
    this.charging = false,
    this.screenTimeDay,
    this.screenTimeNotified = false,
    this.batteryDay,
    this.batteryNotified = false,
    this.calendarKeys = const {},
  });

  final double? latitude;
  final double? longitude;
  final bool headphones;
  final bool charging;
  final String? screenTimeDay;
  final bool screenTimeNotified;
  final String? batteryDay;
  final bool batteryNotified;
  final Set<String> calendarKeys;

  Map<String, Object?> toJson() => {
    'latitude': latitude,
    'longitude': longitude,
    'headphones': headphones,
    'charging': charging,
    'screenTimeDay': screenTimeDay,
    'screenTimeNotified': screenTimeNotified,
    'batteryDay': batteryDay,
    'batteryNotified': batteryNotified,
    'calendarKeys': calendarKeys.toList(),
  };

  static AgencyWakeMemory fromJson(Map<String, dynamic> json) =>
      AgencyWakeMemory(
        latitude: (json['latitude'] as num?)?.toDouble(),
        longitude: (json['longitude'] as num?)?.toDouble(),
        headphones: json['headphones'] == true,
        charging: json['charging'] == true,
        screenTimeDay: json['screenTimeDay'] as String?,
        screenTimeNotified: json['screenTimeNotified'] == true,
        batteryDay: json['batteryDay'] as String?,
        batteryNotified: json['batteryNotified'] == true,
        calendarKeys: {
          for (final k in (json['calendarKeys'] as List?) ?? const []) '$k',
        },
      );
}

@immutable
class AgencyOccasion {
  const AgencyOccasion(this.trigger, this.fact);

  final AgencyTrigger trigger;

  /// One plain sentence handed to the model as a real-life fact.
  final String fact;
}

@immutable
class AgencyWakeDecision {
  const AgencyWakeDecision({
    required this.occasions,
    required this.memory,
    this.skipReason,
  });

  /// Occasions that won their roll; empty means stay asleep.
  final List<AgencyOccasion> occasions;

  /// What to remember for the next look, whether or not it wakes.
  final AgencyWakeMemory memory;
  final String? skipReason;

  bool get wakes => occasions.isNotEmpty;
}

/// How often the companion may reach out at all, regardless of occasion.
@immutable
class AgencyPacing {
  const AgencyPacing({
    this.lastProactiveAt,
    this.proactiveToday = 0,
    this.dailyCap = 4,
    this.cooldown = const Duration(minutes: 45),
    this.recentUserWindow = const Duration(minutes: 10),
  });

  final DateTime? lastProactiveAt;
  final int proactiveToday;
  final int dailyCap;
  final Duration cooldown;
  final Duration recentUserWindow;
}

/// Base chance at the medium level, before [AgencyLevel.factor].
const _baseChance = <AgencyTrigger, double>{
  AgencyTrigger.followUp: 0.8,
  AgencyTrigger.newPlace: 0.6,
  AgencyTrigger.headphones: 0.35,
  AgencyTrigger.lateNight: 0.5,
  AgencyTrigger.bedtimeCharging: 0.4,
  AgencyTrigger.calendar: 0.8,
  AgencyTrigger.screenTime: 0.5,
  AgencyTrigger.lowBattery: 0.6,
};

/// Moving at least this far between looks counts as a new place.
const newPlaceMeters = 1000.0;

/// Longing starts after two quiet hours and tops out around nine.
double longingChance(Duration silence) {
  final hours = silence.inMinutes / 60;
  return ((hours - 2) / 10).clamp(0.0, 0.7);
}

String _day(DateTime t) =>
    '${t.year}-${t.month.toString().padLeft(2, '0')}-'
    '${t.day.toString().padLeft(2, '0')}';

bool _lateNight(DateTime t) => (t.hour == 23 && t.minute >= 30) || t.hour < 2;

bool _evening(DateTime t) => t.hour >= 21 || t.hour < 1;

double metersBetween(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a.toDouble()));
}

String _distance(double meters) => meters < 10000
    ? '${(meters / 1000).toStringAsFixed(1)} 公里'
    : '${(meters / 1000).round()} 公里';

String _silence(Duration d) => d.inHours < 1
    ? '${d.inMinutes} 分钟'
    : d.inDays < 1
    ? '${d.inHours} 小时'
    : '${d.inDays} 天';

/// Decides whether this self-wake should rouse the companion. Pure: the same
/// inputs and random source give the same answer.
AgencyWakeDecision evaluateAgencyWake({
  required AgencySnapshot snapshot,
  required AgencySettings settings,
  required AgencyWakeMemory memory,
  required AgencyPacing pacing,
  required math.Random random,
}) {
  final now = snapshot.now;
  final today = _day(now);

  // Remember the newest view of the world first, so a skipped wake still
  // compares against the right baseline next time.
  final movedMeters =
      snapshot.latitude != null &&
          snapshot.longitude != null &&
          memory.latitude != null &&
          memory.longitude != null
      ? metersBetween(
          memory.latitude!,
          memory.longitude!,
          snapshot.latitude!,
          snapshot.longitude!,
        )
      : null;
  final lead = settings.calendarLeadMinutes;
  final dueEvents = [
    for (final e in snapshot.upcomingEvents)
      if (e.minutesUntil >= 0 &&
          e.minutesUntil <= lead &&
          !memory.calendarKeys.contains(e.key))
        e,
  ];
  final screenThreshold = settings.screenTimeHours * 60;
  final screenCrossed =
      (snapshot.screenTimeMinutes ?? 0) >= screenThreshold &&
      !(memory.screenTimeDay == today && memory.screenTimeNotified);
  final batteryLow =
      snapshot.batteryLevel != null &&
      snapshot.batteryLevel! <= settings.lowBatteryPercent &&
      snapshot.charging != true &&
      !(memory.batteryDay == today && memory.batteryNotified);

  AgencyWakeMemory remember({
    bool screenNotified = false,
    bool batteryNotified = false,
    Iterable<String> calendarKeys = const [],
  }) => AgencyWakeMemory(
    latitude: snapshot.latitude ?? memory.latitude,
    longitude: snapshot.longitude ?? memory.longitude,
    headphones: snapshot.headphones,
    charging: snapshot.charging ?? memory.charging,
    screenTimeDay: today,
    screenTimeNotified:
        screenNotified ||
        (memory.screenTimeDay == today && memory.screenTimeNotified),
    batteryDay: today,
    batteryNotified:
        batteryNotified ||
        (memory.batteryDay == today && memory.batteryNotified),
    // Keep only keys of events still ahead, so the set stays small.
    calendarKeys: {
      ...memory.calendarKeys.where(
        (k) => snapshot.upcomingEvents.any((e) => e.key == k),
      ),
      ...calendarKeys,
    },
  );

  AgencyWakeDecision skip(String reason) => AgencyWakeDecision(
    occasions: const [],
    memory: remember(),
    skipReason: reason,
  );

  if (snapshot.lastMessageIsUser) return skip('user_waiting');
  if (pacing.proactiveToday >= pacing.dailyCap) return skip('daily_cap');
  if (pacing.lastProactiveAt case final last?
      when now.difference(last) < pacing.cooldown) {
    return skip('cooldown');
  }
  if (snapshot.lastUserMessageAt case final last?
      when now.difference(last) < pacing.recentUserWindow) {
    return skip('recent_user');
  }

  final candidates = <(AgencyTrigger, String, double)>[];
  void offer(AgencyTrigger t, String fact, [double? chance]) {
    final setting = settings.trigger(t);
    if (!setting.enabled) return;
    final base = chance ?? _baseChance[t] ?? 0.5;
    candidates.add((t, fact, (base * setting.level.factor).clamp(0.0, 0.95)));
  }

  for (final f in snapshot.dueFollowUps) {
    offer(AgencyTrigger.followUp, '对方之前提到过：${f.what}。这件事现在应该已经有结果了。');
  }
  if (movedMeters != null && movedMeters >= newPlaceMeters) {
    offer(
      AgencyTrigger.newPlace,
      '对方的手机换了地方，离上次大约 ${_distance(movedMeters)}。'
      '你不知道具体是哪里，想知道可以问。',
    );
  }
  if (snapshot.headphones && !memory.headphones) {
    offer(AgencyTrigger.headphones, '对方刚戴上了耳机。');
  }
  if (snapshot.screenOn && _lateNight(now)) {
    offer(AgencyTrigger.lateNight, '已经是深夜了，对方的手机屏幕还亮着。');
  }
  if (snapshot.charging == true && !memory.charging && _evening(now)) {
    offer(AgencyTrigger.bedtimeCharging, '晚上了，对方刚给手机插上充电，可能准备睡了。');
  }
  for (final e in dueEvents) {
    offer(
      AgencyTrigger.calendar,
      '对方的日程「${e.title}」大约 ${e.minutesUntil} 分钟后开始。',
    );
  }
  if (screenCrossed) {
    offer(
      AgencyTrigger.screenTime,
      '对方今天用手机已经超过 ${settings.screenTimeHours} 小时了。',
    );
  }
  if (batteryLow) {
    offer(
      AgencyTrigger.lowBattery,
      '对方的手机只剩 ${snapshot.batteryLevel}% 电，也没在充电。',
    );
  }
  if (snapshot.lastMessageAt case final last?) {
    final silence = now.difference(last);
    final chance = longingChance(silence);
    if (chance > 0) {
      offer(AgencyTrigger.longing, '你们已经 ${_silence(silence)}没说话了。', chance);
    }
  }

  final winners = [
    for (final (t, fact, chance) in candidates)
      if (random.nextDouble() < chance) AgencyOccasion(t, fact),
  ];
  // One-shot occasions are spent once offered, even if the roll lost, so a
  // later wake does not keep rolling for the same event.
  final memoryAfter = remember(
    screenNotified: screenCrossed && settings.enabled(AgencyTrigger.screenTime),
    batteryNotified: batteryLow && settings.enabled(AgencyTrigger.lowBattery),
    calendarKeys: [
      if (settings.enabled(AgencyTrigger.calendar))
        for (final e in dueEvents) e.key,
    ],
  );
  return AgencyWakeDecision(
    occasions: winners,
    memory: memoryAfter,
    skipReason: winners.isEmpty
        ? (candidates.isEmpty ? 'nothing_new' : 'dice')
        : null,
  );
}

/// The hidden context for a self-wake that won at least one roll.
String agencyWakeInstruction({
  required AgencySnapshot snapshot,
  required List<AgencyOccasion> occasions,
  required String note,
}) {
  final base = companionWakeInstruction(
    now: snapshot.now,
    note: note,
    lastMessageAt: snapshot.lastMessageAt,
    lastUserMessageAt: snapshot.lastUserMessageAt,
  );
  final facts = occasions.map((o) => '- ${o.fact}').toSet().join('\n');
  return '$base\n\n'
      '这次醒来时你注意到（都是真实发生的，别编没给出的细节）：\n$facts';
}

/// Next self-wake: a random point in the configured range, kept out of the
/// small hours. Late-night checks stay possible until 02:00 when enabled.
DateTime nextAgencyWake({
  required DateTime now,
  required AgencySettings settings,
  required math.Random random,
}) {
  final span = settings.wakeMaxMinutes - settings.wakeMinMinutes;
  var next = now.add(
    Duration(
      minutes:
          settings.wakeMinMinutes + (span <= 0 ? 0 : random.nextInt(span + 1)),
    ),
  );
  final quietStart = settings.enabled(AgencyTrigger.lateNight) ? 2 : 1;
  if (next.hour >= quietStart && next.hour < 8) {
    next = DateTime(
      next.year,
      next.month,
      next.day,
      8,
    ).add(Duration(minutes: random.nextInt(60)));
  }
  return next;
}

/// Persists [AgencyWakeMemory] between wakes.
class AgencyWakeMemoryStore {
  AgencyWakeMemoryStore._();

  static final AgencyWakeMemoryStore instance = AgencyWakeMemoryStore._();
  static const _key = 'agency_wake_memory_v1';

  BusinessPreferences? _preferences;

  void attach(BusinessPreferences preferences) => _preferences = preferences;

  AgencyWakeMemory read() {
    final raw = _preferences?.getString(_key);
    if (raw == null) return const AgencyWakeMemory();
    try {
      return AgencyWakeMemory.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return const AgencyWakeMemory();
    }
  }

  Future<void> write(AgencyWakeMemory memory) async =>
      _preferences?.setString(_key, jsonEncode(memory.toJson()));
}

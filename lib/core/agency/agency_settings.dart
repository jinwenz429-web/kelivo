import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';

/// Occasions that may wake the companion. Each is only a chance: a passing
/// occasion still rolls against its level, and the model may stay silent.
enum AgencyTrigger {
  /// Self-wake grows more likely the longer the user has been quiet.
  longing,

  /// Something the user mentioned (an exam, a doctor visit) is now past.
  followUp,

  /// The phone is somewhere new compared to the last look.
  newPlace,

  /// Headphones were connected since the last look.
  headphones,

  /// Late at night and the screen is on.
  lateNight,

  /// Charging started in the evening, as if going to bed.
  bedtimeCharging,

  /// A calendar event is about to start.
  calendar,

  /// Today's screen time crossed a threshold.
  screenTime,

  /// Battery is low and not charging.
  lowBattery,
}

enum AgencyLevel { low, medium, high }

extension AgencyLevelChance on AgencyLevel {
  /// Scales an occasion's base chance.
  double get factor => switch (this) {
    AgencyLevel.low => 0.5,
    AgencyLevel.medium => 1.0,
    AgencyLevel.high => 1.5,
  };
}

@immutable
class AgencyTriggerSetting {
  const AgencyTriggerSetting({
    this.enabled = true,
    this.level = AgencyLevel.medium,
  });

  final bool enabled;
  final AgencyLevel level;

  AgencyTriggerSetting copyWith({bool? enabled, AgencyLevel? level}) =>
      AgencyTriggerSetting(
        enabled: enabled ?? this.enabled,
        level: level ?? this.level,
      );

  Map<String, Object?> toJson() => {'enabled': enabled, 'level': level.name};

  static AgencyTriggerSetting fromJson(Object? raw) {
    if (raw is! Map) return const AgencyTriggerSetting();
    return AgencyTriggerSetting(
      enabled: raw['enabled'] != false,
      level: AgencyLevel.values.asNameMap()[raw['level']] ?? AgencyLevel.medium,
    );
  }
}

/// User-tunable companion agency behaviour, shared by every assistant that
/// has Companion Agency turned on.
@immutable
class AgencySettings {
  const AgencySettings({
    this.modelProvider,
    this.modelId,
    this.note = '',
    this.triggers = const {},
    this.wakeMinMinutes = 90,
    this.wakeMaxMinutes = 240,
    this.calendarLeadMinutes = 45,
    this.screenTimeHours = 5,
    this.lowBatteryPercent = 20,
    this.regenerateOnDrift = false,
  });

  /// Model for proactive turns and follow-up extraction; null follows chat.
  final String? modelProvider;
  final String? modelId;

  /// Free text the companion sees whenever it wakes.
  final String note;
  final Map<AgencyTrigger, AgencyTriggerSetting> triggers;
  final int wakeMinMinutes;
  final int wakeMaxMinutes;
  final int calendarLeadMinutes;
  final int screenTimeHours;
  final int lowBatteryPercent;

  /// With a Pawwake gateway: ask after each reply whether it broke character
  /// and, if so, have it say that line again once.
  final bool regenerateOnDrift;

  AgencyTriggerSetting trigger(AgencyTrigger t) =>
      triggers[t] ?? const AgencyTriggerSetting();

  bool enabled(AgencyTrigger t) => trigger(t).enabled;

  ({String providerKey, String modelId})? get modelOverride =>
      modelProvider != null && modelId != null
      ? (providerKey: modelProvider!, modelId: modelId!)
      : null;

  /// Self-wake only matters when something it checks is turned on.
  bool get wantsBackgroundWake => const [
    AgencyTrigger.longing,
    AgencyTrigger.followUp,
    AgencyTrigger.newPlace,
    AgencyTrigger.headphones,
    AgencyTrigger.lateNight,
    AgencyTrigger.bedtimeCharging,
    AgencyTrigger.calendar,
    AgencyTrigger.screenTime,
    AgencyTrigger.lowBattery,
  ].any(enabled);

  AgencySettings copyWith({
    ({String providerKey, String modelId})? model,
    bool clearModel = false,
    String? note,
    Map<AgencyTrigger, AgencyTriggerSetting>? triggers,
    int? wakeMinMinutes,
    int? wakeMaxMinutes,
    int? calendarLeadMinutes,
    int? screenTimeHours,
    int? lowBatteryPercent,
    bool? regenerateOnDrift,
  }) => AgencySettings(
    modelProvider: clearModel ? null : model?.providerKey ?? modelProvider,
    modelId: clearModel ? null : model?.modelId ?? modelId,
    note: note ?? this.note,
    triggers: triggers ?? this.triggers,
    wakeMinMinutes: wakeMinMinutes ?? this.wakeMinMinutes,
    wakeMaxMinutes: wakeMaxMinutes ?? this.wakeMaxMinutes,
    calendarLeadMinutes: calendarLeadMinutes ?? this.calendarLeadMinutes,
    screenTimeHours: screenTimeHours ?? this.screenTimeHours,
    lowBatteryPercent: lowBatteryPercent ?? this.lowBatteryPercent,
    regenerateOnDrift: regenerateOnDrift ?? this.regenerateOnDrift,
  );

  AgencySettings withTrigger(AgencyTrigger t, AgencyTriggerSetting value) =>
      copyWith(triggers: {...triggers, t: value});

  Map<String, Object?> toJson() => {
    'modelProvider': modelProvider,
    'modelId': modelId,
    'note': note,
    'triggers': {
      for (final e in triggers.entries) e.key.name: e.value.toJson(),
    },
    'wakeMinMinutes': wakeMinMinutes,
    'wakeMaxMinutes': wakeMaxMinutes,
    'calendarLeadMinutes': calendarLeadMinutes,
    'screenTimeHours': screenTimeHours,
    'lowBatteryPercent': lowBatteryPercent,
    'regenerateOnDrift': regenerateOnDrift,
  };

  static AgencySettings fromJson(Map<String, dynamic> json) {
    int read(String key, int fallback, int min, int max) {
      final raw = json[key];
      return raw is num ? raw.round().clamp(min, max) : fallback;
    }

    final rawTriggers = json['triggers'];
    final byName = AgencyTrigger.values.asNameMap();
    final wakeMin = read('wakeMinMinutes', 90, 30, 720);
    return AgencySettings(
      modelProvider: json['modelProvider'] as String?,
      modelId: json['modelId'] as String?,
      note: json['note'] as String? ?? '',
      triggers: {
        if (rawTriggers is Map)
          for (final e in rawTriggers.entries)
            if (byName[e.key] case final t?)
              t: AgencyTriggerSetting.fromJson(e.value),
      },
      wakeMinMinutes: wakeMin,
      wakeMaxMinutes: read('wakeMaxMinutes', 240, wakeMin, 1440),
      calendarLeadMinutes: read('calendarLeadMinutes', 45, 5, 180),
      screenTimeHours: read('screenTimeHours', 5, 1, 12),
      lowBatteryPercent: read('lowBatteryPercent', 20, 5, 50),
      regenerateOnDrift: json['regenerateOnDrift'] == true,
    );
  }
}

/// Process-wide holder; persisted in [BusinessPreferences].
class AgencySettingsStore extends ChangeNotifier {
  AgencySettingsStore._();

  static final AgencySettingsStore instance = AgencySettingsStore._();
  static const _key = 'agency_settings_v1';

  BusinessPreferences? _preferences;
  AgencySettings _value = const AgencySettings();

  AgencySettings get value => _value;

  void attach(BusinessPreferences preferences) {
    _preferences = preferences;
    final raw = preferences.getString(_key);
    if (raw == null) return;
    try {
      _value = AgencySettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      _value = const AgencySettings();
    }
  }

  Future<void> update(AgencySettings next) async {
    _value = next;
    notifyListeners();
    await _preferences?.setString(_key, jsonEncode(next.toJson()));
  }
}

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/database/business_preferences.dart';

/// Which ElevenLabs model reads the companion's lines during a call.
enum CallVoiceModel {
  /// Whatever the selected TTS service is configured with.
  service,

  /// Eleven v3: richest emotion and the only one that reads audio tags.
  v3,

  /// Flash v2.5: starts speaking fastest, no audio tags.
  flash,
}

extension CallVoiceModelId on CallVoiceModel {
  String? get elevenLabsModelId => switch (this) {
    CallVoiceModel.service => null,
    CallVoiceModel.v3 => 'eleven_v3',
    CallVoiceModel.flash => 'eleven_flash_v2_5',
  };
}

enum CallSensitivity { low, medium, high }

extension CallSensitivityLevels on CallSensitivity {
  /// Normalized mic level (0–1) that counts as speech while listening.
  double get speechLevel => switch (this) {
    CallSensitivity.low => 0.26,
    CallSensitivity.medium => 0.18,
    CallSensitivity.high => 0.12,
  };

  /// Higher bar while the companion is talking, so its own voice leaking
  /// from the speaker is less likely to count as an interruption.
  double get bargeInLevel => speechLevel + 0.14;
}

@immutable
class CallSettings {
  const CallSettings({
    this.companionSpeaksFirst = true,
    this.silenceNudge = false,
    this.silenceNudgeSeconds = 25,
    this.voiceModel = CallVoiceModel.service,
    this.sensitivity = CallSensitivity.medium,
    this.endOfTurnMillis = 900,
    this.lowReasoning = true,
    this.companionMayCall = false,
    this.doNotDisturb = false,
    this.lastCompanionCallAt,
  });

  /// After pickup, the companion says the first words ("喂？").
  final bool companionSpeaksFirst;

  /// After a long silence the companion picks the conversation back up,
  /// at most twice in a row.
  final bool silenceNudge;
  final int silenceNudgeSeconds;
  final CallVoiceModel voiceModel;
  final CallSensitivity sensitivity;

  /// Pause after speech that ends the user's turn.
  final int endOfTurnMillis;

  /// Ask for low reasoning effort during calls so replies start sooner.
  final bool lowReasoning;

  /// Companion Agency may phone instead of texting.
  final bool companionMayCall;

  /// Set by voice ("我要出门了，开勿扰") or in settings: no calls from it.
  final bool doNotDisturb;

  /// When the companion last rang, for the once-a-day limit.
  final DateTime? lastCompanionCallAt;

  /// Whether a self-wake may phone right now: allowed, not on do-not-disturb,
  /// daytime, and not already today.
  bool mayCallAt(DateTime now) {
    if (!companionMayCall || doNotDisturb) return false;
    if (now.hour < 10 || now.hour >= 23) return false;
    final last = lastCompanionCallAt;
    return last == null ||
        last.year != now.year ||
        last.month != now.month ||
        last.day != now.day;
  }

  CallSettings copyWith({
    bool? companionSpeaksFirst,
    bool? silenceNudge,
    int? silenceNudgeSeconds,
    CallVoiceModel? voiceModel,
    CallSensitivity? sensitivity,
    int? endOfTurnMillis,
    bool? lowReasoning,
    bool? companionMayCall,
    bool? doNotDisturb,
    DateTime? lastCompanionCallAt,
  }) => CallSettings(
    companionSpeaksFirst: companionSpeaksFirst ?? this.companionSpeaksFirst,
    silenceNudge: silenceNudge ?? this.silenceNudge,
    silenceNudgeSeconds: silenceNudgeSeconds ?? this.silenceNudgeSeconds,
    voiceModel: voiceModel ?? this.voiceModel,
    sensitivity: sensitivity ?? this.sensitivity,
    endOfTurnMillis: endOfTurnMillis ?? this.endOfTurnMillis,
    lowReasoning: lowReasoning ?? this.lowReasoning,
    companionMayCall: companionMayCall ?? this.companionMayCall,
    doNotDisturb: doNotDisturb ?? this.doNotDisturb,
    lastCompanionCallAt: lastCompanionCallAt ?? this.lastCompanionCallAt,
  );

  Map<String, dynamic> toJson() => {
    'companionSpeaksFirst': companionSpeaksFirst,
    'silenceNudge': silenceNudge,
    'silenceNudgeSeconds': silenceNudgeSeconds,
    'voiceModel': voiceModel.name,
    'sensitivity': sensitivity.name,
    'endOfTurnMillis': endOfTurnMillis,
    'lowReasoning': lowReasoning,
    'companionMayCall': companionMayCall,
    'doNotDisturb': doNotDisturb,
    if (lastCompanionCallAt != null)
      'lastCompanionCallAt': lastCompanionCallAt!.toUtc().toIso8601String(),
  };

  static CallSettings fromJson(Map<String, dynamic> json) {
    int read(String key, int fallback, int min, int max) {
      final raw = json[key];
      return raw is num ? raw.toInt().clamp(min, max) : fallback;
    }

    const d = CallSettings();
    return CallSettings(
      companionSpeaksFirst:
          json['companionSpeaksFirst'] as bool? ?? d.companionSpeaksFirst,
      silenceNudge: json['silenceNudge'] as bool? ?? d.silenceNudge,
      silenceNudgeSeconds: read('silenceNudgeSeconds', 25, 10, 120),
      voiceModel:
          CallVoiceModel.values.asNameMap()[json['voiceModel']] ?? d.voiceModel,
      sensitivity:
          CallSensitivity.values.asNameMap()[json['sensitivity']] ??
          d.sensitivity,
      endOfTurnMillis: read('endOfTurnMillis', 900, 500, 2500),
      lowReasoning: json['lowReasoning'] as bool? ?? d.lowReasoning,
      companionMayCall: json['companionMayCall'] as bool? ?? d.companionMayCall,
      doNotDisturb: json['doNotDisturb'] as bool? ?? d.doNotDisturb,
      lastCompanionCallAt: DateTime.tryParse(
        (json['lastCompanionCallAt'] ?? '').toString(),
      )?.toLocal(),
    );
  }
}

/// Process-wide holder; persisted in [BusinessPreferences].
class CallSettingsStore extends ChangeNotifier {
  CallSettingsStore._();

  static final CallSettingsStore instance = CallSettingsStore._();
  static const _key = 'call_settings_v1';

  BusinessPreferences? _preferences;
  CallSettings _value = const CallSettings();

  CallSettings get value => _value;

  void attach(BusinessPreferences preferences) {
    _preferences = preferences;
    final raw = preferences.getString(_key);
    if (raw == null) return;
    try {
      _value = CallSettings.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      _value = const CallSettings();
    }
  }

  Future<void> update(CallSettings next) async {
    _value = next;
    notifyListeners();
    await _preferences?.setString(_key, jsonEncode(next.toJson()));
  }
}

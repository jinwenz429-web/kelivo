import 'dart:convert';
import 'dart:math' as math;

import '../../../core/agency/agency_coordinator.dart';
import '../../../core/agency/agency_follow_ups.dart';
import '../../../core/agency/agency_settings.dart';
import '../../../core/agency/agency_wake_check.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../chat/utils/thinking_tag_parser.dart';
import '../utils/model_display_helper.dart';
import 'local_tools_service.dart';

/// Runs one self-wake "look around": refresh follow-ups, read the phone,
/// roll for each occasion. Returns the hidden instruction when the companion
/// should wake, or null when it stays asleep this time.
Future<String?> planAgencyWake({
  required SettingsProvider settings,
  required Assistant assistant,
  required Conversation conversation,
  required List<ChatMessage> history,
  math.Random? random,
}) async {
  final config = AgencySettingsStore.instance.value;
  final now = DateTime.now();
  final visible = [
    for (final m in history)
      if (m.role == 'user' || m.role == 'assistant') m,
  ];

  if (config.enabled(AgencyTrigger.followUp)) {
    try {
      await _extractFollowUps(
        settings: settings,
        assistant: assistant,
        conversation: conversation,
        history: visible,
        now: now,
      );
    } catch (error) {
      FlutterLogger.log('follow-up extraction failed: $error', tag: _tag);
    }
  }
  final due = [
    for (final f in AgencyFollowUpStore.instance.pending(now))
      if (f.conversationId == conversation.id && f.isDue(now)) f,
  ];

  final device = await _readJson('deviceSnapshot');
  final location = config.enabled(AgencyTrigger.newPlace)
      ? await _location()
      : null;
  final snapshot = AgencySnapshot(
    now: now,
    lastMessageAt: visible.lastOrNull?.timestamp,
    lastUserMessageAt: visible
        .where((m) => m.role == 'user')
        .lastOrNull
        ?.timestamp,
    lastMessageIsUser: visible.lastOrNull?.role == 'user',
    batteryLevel: (device?['batteryLevel'] as num?)?.toInt(),
    charging: device?['charging'] as bool?,
    screenOn: device?['screenOn'] == true,
    headphones: device?['headphones'] == true,
    latitude: location?.$1,
    longitude: location?.$2,
    screenTimeMinutes: config.enabled(AgencyTrigger.screenTime)
        ? await _screenTimeMinutes()
        : null,
    upcomingEvents: config.enabled(AgencyTrigger.calendar)
        ? await _upcomingEvents(now)
        : const [],
    dueFollowUps: due,
  );

  final decision = evaluateAgencyWake(
    snapshot: snapshot,
    settings: config,
    memory: AgencyWakeMemoryStore.instance.read(),
    pacing: await AgencyCoordinator.instance.pacing(now: now),
    random: random ?? math.Random(),
  );
  await AgencyWakeMemoryStore.instance.write(decision.memory);
  // Follow-ups that were offered are spent, won or lost, so the companion
  // does not keep circling back to the same thing.
  if (decision.wakes || decision.skipReason == 'dice') {
    await AgencyFollowUpStore.instance.consume(due, now);
  }
  FlutterLogger.log(
    decision.wakes
        ? 'wake: ${decision.occasions.map((o) => o.trigger.name).join(",")}'
        : 'stay asleep: ${decision.skipReason}',
    tag: _tag,
  );
  if (!decision.wakes) return null;
  return agencyWakeInstruction(
    snapshot: snapshot,
    occasions: decision.occasions,
    note: config.note,
  );
}

const _tag = 'AgencyWake';

Future<void> _extractFollowUps({
  required SettingsProvider settings,
  required Assistant assistant,
  required Conversation conversation,
  required List<ChatMessage> history,
  required DateTime now,
}) async {
  final store = AgencyFollowUpStore.instance;
  final since = store.readThrough(conversation.id);
  final fresh = [
    for (final m in history)
      if (since == null || m.timestamp.isAfter(since)) m,
  ];
  if (!fresh.any((m) => m.role == 'user')) return;
  final window = fresh.length > 40 ? fresh.sublist(fresh.length - 40) : fresh;
  final transcript = StringBuffer();
  for (final m in window) {
    final text = ThinkingTagParser.parseWithRanges(
      m.content,
    ).visibleContent.trim();
    if (text.isEmpty) continue;
    final t = m.timestamp;
    transcript.writeln(
      '[${t.month}-${t.day} ${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}] '
      '${m.role == 'user' ? '我' : '它'}：$text',
    );
  }
  var text = transcript.toString();
  if (text.length > 6000) text = text.substring(text.length - 6000);

  final override = AgencySettingsStore.instance.value.modelOverride;
  final chatModel = resolveChatModel(
    settings,
    conversation: conversation,
    assistant: assistant,
  );
  final providerKey = override?.providerKey ?? chatModel.providerKey;
  final modelId = override?.modelId ?? chatModel.modelId;
  if (providerKey == null || modelId == null) return;
  final reply = await ChatApiService.generateText(
    config: settings.getProviderConfig(providerKey),
    modelId: modelId,
    prompt: followUpExtractionPrompt(now: now, transcript: text),
    skipImageParsing: true,
  );
  await store.add(
    parseFollowUps(reply, now: now, conversationId: conversation.id),
    conversationId: conversation.id,
    readThrough: history.last.timestamp,
    now: now,
  );
}

Future<Map<String, dynamic>?> _readJson(
  String method, [
  Map<String, dynamic> args = const {},
]) async {
  try {
    final decoded = jsonDecode(
      await DeviceLocalTools.invokeJsonTool(method, args),
    );
    if (decoded is! Map || decoded.containsKey('error')) return null;
    return Map<String, dynamic>.from(decoded);
  } catch (_) {
    return null;
  }
}

Future<int?> _screenTimeMinutes() async {
  if (!DeviceLocalTools.screenTimeSupported ||
      !await DeviceLocalTools.hasUsageStatsPermission()) {
    return null;
  }
  final json = await _readJson('getScreenTime', {'range': 'today', 'top': 1});
  return (json?['total_minutes'] as num?)?.toInt();
}

Future<List<({String key, String title, int minutesUntil})>> _upcomingEvents(
  DateTime now,
) async {
  if (!DeviceLocalTools.calendarSupported ||
      !await DeviceLocalTools.hasCalendarPermission()) {
    return const [];
  }
  final json = await _readJson('queryCalendar', {
    'begin': now.toIso8601String(),
    'end': now.add(const Duration(hours: 3)).toIso8601String(),
    'limit': 10,
  });
  final events = json?['events'];
  if (events is! List) return const [];
  return [
    for (final raw in events)
      if (raw is Map && raw['all_day'] != true)
        if (DateTime.tryParse(
              raw['start']?.toString().replaceFirst(
                    RegExp(r'\[[^\]]+\]$'),
                    '',
                  ) ??
                  '',
            )
            case final start? when !start.isBefore(now))
          (
            key: '${raw['id'] ?? raw['title'] ?? ''}|${raw['start'] ?? ''}',
            title: raw['title']?.toString() ?? '',
            minutesUntil: start.difference(now).inMinutes,
          ),
  ];
}

Future<(double, double)?> _location() async {
  if (!DeviceLocalTools.locationSupported ||
      !await DeviceLocalTools.hasLocationPermission()) {
    return null;
  }
  final json = await _readJson('getCurrentLocation');
  final lat = (json?['latitude'] as num?)?.toDouble();
  final lon = (json?['longitude'] as num?)?.toDouble();
  return lat == null || lon == null ? null : (lat, lon);
}

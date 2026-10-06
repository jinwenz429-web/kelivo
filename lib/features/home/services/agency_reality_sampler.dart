import 'dart:convert';

import '../../../core/agency/agency_event.dart';
import '../../../core/agency/agency_event_bus.dart';
import '../../../core/models/assistant.dart';
import 'local_tools_service.dart';

typedef AgencyPermissionCheck = Future<bool> Function();
typedef AgencyCapabilityCheck = bool Function();
typedef AgencyDeviceInvoker =
    Future<String> Function(String method, Map<String, dynamic> args);

/// Reads reality signals through Kelivo's existing device tools.
///
/// This class intentionally does not implement calendar or UsageStats access.
/// It reuses [DeviceLocalTools], checks already-granted permissions, and only
/// emits local agency events. No permission UI, network call, or model call is
/// triggered by sampling.
class AgencyRealitySampler {
  AgencyRealitySampler({
    AgencyEventBus? bus,
    AgencyPermissionCheck? hasUsageStatsPermission,
    AgencyPermissionCheck? hasCalendarPermission,
    AgencyPermissionCheck? hasLocationPermission,
    AgencyCapabilityCheck? screenTimeSupported,
    AgencyCapabilityCheck? calendarSupported,
    AgencyCapabilityCheck? locationSupported,
    AgencyDeviceInvoker? invokeDeviceTool,
    this.minimumInterval = const Duration(minutes: 15),
  }) : _bus = bus ?? AgencyEventBus.instance,
       _hasUsageStatsPermission =
           hasUsageStatsPermission ?? DeviceLocalTools.hasUsageStatsPermission,
       _hasCalendarPermission =
           hasCalendarPermission ?? DeviceLocalTools.hasCalendarPermission,
       _hasLocationPermission =
           hasLocationPermission ?? DeviceLocalTools.hasLocationPermission,
       _screenTimeSupported =
           screenTimeSupported ?? (() => DeviceLocalTools.screenTimeSupported),
       _calendarSupported =
           calendarSupported ?? (() => DeviceLocalTools.calendarSupported),
       _locationSupported =
           locationSupported ?? (() => DeviceLocalTools.locationSupported),
       _invokeDeviceTool =
           invokeDeviceTool ?? DeviceLocalTools.invokeJsonTool;

  final AgencyEventBus _bus;
  final AgencyPermissionCheck _hasUsageStatsPermission;
  final AgencyPermissionCheck _hasCalendarPermission;
  final AgencyPermissionCheck _hasLocationPermission;
  final AgencyCapabilityCheck _screenTimeSupported;
  final AgencyCapabilityCheck _calendarSupported;
  final AgencyCapabilityCheck _locationSupported;
  final AgencyDeviceInvoker _invokeDeviceTool;
  final Duration minimumInterval;

  final Map<String, DateTime> _lastSampleAtByOrigin =
      <String, DateTime>{};
  final Set<String> _samplingOrigins = <String>{};

  Future<void> sample({
    required Assistant? assistant,
    required String? conversationId,
    DateTime? now,
  }) async {
    final boundConversationId = conversationId?.trim();
    if (assistant == null ||
        !assistant.companionAgencyEnabled ||
        boundConversationId == null ||
        boundConversationId.isEmpty) {
      return;
    }

    final wantsCalendar =
        assistant.localToolIds.contains(LocalToolNames.calendarQuery);
    final wantsScreenTime =
        assistant.localToolIds.contains(LocalToolNames.screenTime);
    final wantsLocation =
        assistant.localToolIds.contains(LocalToolNames.currentLocation);
    if (!wantsCalendar && !wantsScreenTime && !wantsLocation) return;

    final clock = now ?? DateTime.now();
    final originKey = '${assistant.id}|$boundConversationId';
    if (_samplingOrigins.contains(originKey)) return;
    final last = _lastSampleAtByOrigin[originKey];
    if (last != null && clock.difference(last) < minimumInterval) return;

    _samplingOrigins.add(originKey);
    var didReadDeviceData = false;
    try {
      if (wantsCalendar) {
        didReadDeviceData =
            await _sampleCalendar(
              clock,
              assistantId: assistant.id,
              conversationId: boundConversationId,
            ) ||
            didReadDeviceData;
      }
      if (wantsScreenTime) {
        didReadDeviceData =
            await _sampleScreenTime(
              clock,
              assistantId: assistant.id,
              conversationId: boundConversationId,
            ) ||
            didReadDeviceData;
      }
      if (wantsLocation) {
        didReadDeviceData =
            await _sampleLocation(
              clock,
              assistantId: assistant.id,
              conversationId: boundConversationId,
            ) ||
            didReadDeviceData;
      }
      if (didReadDeviceData) {
        _lastSampleAtByOrigin[originKey] = clock;
      }
    } finally {
      _samplingOrigins.remove(originKey);
    }
  }

  Future<bool> _sampleScreenTime(
    DateTime now, {
    required String assistantId,
    required String conversationId,
  }) async {
    if (!_screenTimeSupported()) return false;
    if (!await _hasUsageStatsPermission()) return false;

    final raw = await _invokeDeviceTool('getScreenTime', <String, dynamic>{
      'range': 'today',
      'top': 5,
    });
    final json = _decodeObject(raw);
    if (json == null || json.containsKey('error')) return true;

    final totalMinutes = _asInt(json['total_minutes']);
    if (totalMinutes == null) return true;

    final dayKey =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
    const thresholds = <int>[180, 300, 420];
    int? crossed;
    for (final threshold in thresholds) {
      if (totalMinutes >= threshold) crossed = threshold;
    }
    if (crossed == null) return true;

    _bus.post(
      AgencyEvent(
        kind: AgencyEventKind.screenTimeThreshold,
        source: 'kelivo_screen_time',
        dedupeKey:
            'screen:$assistantId:$conversationId:$dayKey:$crossed',
        urgency: switch (crossed) {
          >= 420 => 0.82,
          >= 300 => 0.72,
          _ => 0.64,
        },
        payload: <String, Object?>{
          'originAssistantId': assistantId,
          'originConversationId': conversationId,
          'date': dayKey,
          'totalMinutes': totalMinutes,
          'thresholdMinutes': crossed,
          'apps': _jsonList(json['apps']),
        },
      ),
    );
    return true;
  }

  Future<bool> _sampleCalendar(
    DateTime now, {
    required String assistantId,
    required String conversationId,
  }) async {
    if (!_calendarSupported()) return false;
    if (!await _hasCalendarPermission()) return false;

    final end = now.add(const Duration(hours: 2));
    final raw = await _invokeDeviceTool('queryCalendar', <String, dynamic>{
      'begin': now.toIso8601String(),
      'end': end.toIso8601String(),
      'limit': 10,
    });
    final json = _decodeObject(raw);
    if (json == null || json.containsKey('error')) return true;

    for (final item in _jsonList(json['events'])) {
      if (item is! Map) continue;
      final event = Map<String, dynamic>.from(item);
      if (event['all_day'] == true) continue;
      final start = _parseDeviceDate(event['start']);
      if (start == null || start.isBefore(now)) continue;
      final until = start.difference(now);
      if (until > const Duration(minutes: 90)) continue;

      final key =
          '${event['id'] ?? event['title'] ?? ''}|'
          '${event['start'] ?? ''}';

      final minutesUntil = until.inMinutes;
      _bus.post(
        AgencyEvent(
          kind: AgencyEventKind.calendarUpcoming,
          source: 'kelivo_calendar',
          dedupeKey:
              'calendar:$assistantId:$conversationId:$key',
          urgency: minutesUntil <= 30 ? 0.86 : 0.74,
          payload: <String, Object?>{
            'originAssistantId': assistantId,
            'originConversationId': conversationId,
            'id': event['id'],
            'title': event['title']?.toString() ?? '',
            'location': event['location']?.toString() ?? '',
            'start': event['start']?.toString() ?? '',
            'end': event['end']?.toString() ?? '',
            'calendar': event['calendar']?.toString() ?? '',
            'minutesUntil': minutesUntil,
          },
        ),
      );
    }
    return true;
  }

  Future<bool> _sampleLocation(
    DateTime now, {
    required String assistantId,
    required String conversationId,
  }) async {
    if (!_locationSupported()) return false;
    if (!await _hasLocationPermission()) return false;

    final raw = await _invokeDeviceTool(
      'getCurrentLocation',
      const <String, dynamic>{},
    );
    final json = _decodeObject(raw);
    if (json == null || json.containsKey('error')) return true;

    final latitude = _asDouble(json['latitude']);
    final longitude = _asDouble(json['longitude']);
    if (latitude == null || longitude == null) return true;

    _bus.post(
      AgencyEvent(
        kind: AgencyEventKind.locationChanged,
        source: 'kelivo_location',
        urgency: 0.20,
        payload: <String, Object?>{
          'originAssistantId': assistantId,
          'originConversationId': conversationId,
          'latitude': latitude,
          'longitude': longitude,
          'accuracyM': _asDouble(json['accuracy_m']),
          'timestamp': json['timestamp']?.toString() ?? '',
        },
      ),
    );
    return true;
  }

  static Map<String, dynamic>? _decodeObject(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static List<dynamic> _jsonList(Object? value) =>
      value is List ? List<dynamic>.from(value) : const <dynamic>[];

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }

  static double? _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  static DateTime? _parseDeviceDate(Object? value) {
    final raw = value?.toString().trim();
    if (raw == null || raw.isEmpty) return null;
    final withoutZoneName = raw.replaceFirst(RegExp(r'\[[^\]]+\]$'), '');
    return DateTime.tryParse(withoutZoneName);
  }
}

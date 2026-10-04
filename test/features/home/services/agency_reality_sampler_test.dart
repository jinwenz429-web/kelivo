import 'dart:convert';

import 'package:Kelivo/core/agency/agency_event.dart';
import 'package:Kelivo/core/agency/agency_event_bus.dart';
import 'package:Kelivo/core/models/assistant.dart';
import 'package:Kelivo/features/home/services/agency_reality_sampler.dart';
import 'package:Kelivo/features/home/services/local_tools_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reuses existing calendar and screen-time device tools as agency signals',
      () async {
    final bus = AgencyEventBus();
    addTearDown(bus.dispose);
    final events = <AgencyEvent>[];
    final subscription = bus.events.listen(events.add);
    addTearDown(subscription.cancel);

    final calls = <String>[];
    final now = DateTime.parse('2026-10-04T20:00:00+08:00');
    final sampler = AgencyRealitySampler(
      bus: bus,
      minimumInterval: Duration.zero,
      screenTimeSupported: () => true,
      calendarSupported: () => true,
      hasUsageStatsPermission: () async => true,
      hasCalendarPermission: () async => true,
      invokeDeviceTool: (method, args) async {
        calls.add(method);
        if (method == 'queryCalendar') {
          return jsonEncode({
            'events': [
              {
                'id': 7,
                'title': '晚课',
                'location': '教学楼',
                'start': '2026-10-04T20:20:00+08:00[Asia/Shanghai]',
                'end': '2026-10-04T21:20:00+08:00[Asia/Shanghai]',
                'all_day': false,
                'calendar': '课程',
              },
            ],
          });
        }
        if (method == 'getScreenTime') {
          return jsonEncode({
            'total_minutes': 305,
            'apps': [
              {'app_name': 'Example', 'total_minutes': 100},
            ],
          });
        }
        fail('unexpected method: $method');
      },
    );

    const assistant = Assistant(
      id: 'assistant',
      name: 'Companion',
      localToolIds: [
        LocalToolNames.calendarQuery,
        LocalToolNames.screenTime,
      ],
    );

    await sampler.sample(
      assistant: assistant,
      conversationId: 'conversation-1',
      now: now,
    );

    expect(calls, ['queryCalendar', 'getScreenTime']);
    expect(
      events.map((event) => event.kind),
      [
        AgencyEventKind.calendarUpcoming,
        AgencyEventKind.screenTimeThreshold,
      ],
    );
    expect(events.first.payload['minutesUntil'], 20);
    expect(events.last.payload['thresholdMinutes'], 300);

    final firstKeys = events.map((event) => event.dedupeKey).toList();
    expect(firstKeys.every((key) => key != null && key!.isNotEmpty), isTrue);
    expect(
      events.every(
        (event) =>
            event.payload['originAssistantId'] == 'assistant' &&
            event.payload['originConversationId'] == 'conversation-1',
      ),
      isTrue,
    );

    // Sampling may retry the same reality facts until an actual proactive
    // message is successfully delivered; the coordinator owns success-only
    // deduplication.
    await sampler.sample(
      assistant: assistant,
      conversationId: 'conversation-1',
      now: now,
    );
    expect(events, hasLength(4));
    expect(
      events.skip(2).map((event) => event.dedupeKey).toList(),
      firstKeys,
    );
  });

  test('does not sample capabilities the assistant did not enable', () async {
    final calls = <String>[];
    final sampler = AgencyRealitySampler(
      minimumInterval: Duration.zero,
      screenTimeSupported: () => true,
      calendarSupported: () => true,
      hasUsageStatsPermission: () async => true,
      hasCalendarPermission: () async => true,
      invokeDeviceTool: (method, args) async {
        calls.add(method);
        return '{}';
      },
    );

    await sampler.sample(
      assistant: const Assistant(id: 'a', name: 'No device tools'),
      conversationId: 'conversation-1',
      now: DateTime(2026, 10, 4, 20),
    );

    expect(calls, isEmpty);
  });

  test('never opens permission flows while passively sampling', () async {
    final calls = <String>[];
    final sampler = AgencyRealitySampler(
      minimumInterval: Duration.zero,
      screenTimeSupported: () => true,
      calendarSupported: () => true,
      hasUsageStatsPermission: () async => false,
      hasCalendarPermission: () async => false,
      invokeDeviceTool: (method, args) async {
        calls.add(method);
        return '{}';
      },
    );

    await sampler.sample(
      assistant: const Assistant(
        id: 'a',
        name: 'Companion',
        localToolIds: [
          LocalToolNames.calendarQuery,
          LocalToolNames.screenTime,
        ],
      ),
      conversationId: 'conversation-1',
      now: DateTime(2026, 10, 4, 20),
    );

    expect(calls, isEmpty);
  });

  test('throttles each assistant and conversation independently', () async {
    final calls = <String>[];
    final sampler = AgencyRealitySampler(
      minimumInterval: const Duration(minutes: 15),
      screenTimeSupported: () => true,
      calendarSupported: () => false,
      hasUsageStatsPermission: () async => true,
      hasCalendarPermission: () async => false,
      invokeDeviceTool: (method, args) async {
        calls.add(method);
        return jsonEncode({'total_minutes': 10, 'apps': const []});
      },
    );
    const assistant = Assistant(
      id: 'a',
      name: 'Companion',
      localToolIds: [LocalToolNames.screenTime],
    );
    final now = DateTime(2026, 10, 5, 0, 0);

    await sampler.sample(
      assistant: assistant,
      conversationId: 'conversation-1',
      now: now,
    );
    await sampler.sample(
      assistant: assistant,
      conversationId: 'conversation-1',
      now: now.add(const Duration(minutes: 1)),
    );
    await sampler.sample(
      assistant: assistant,
      conversationId: 'conversation-2',
      now: now.add(const Duration(minutes: 1)),
    );

    expect(calls, ['getScreenTime', 'getScreenTime']);
  });

  test('a permission miss does not consume the sampling interval', () async {
    var permitted = false;
    final calls = <String>[];
    final sampler = AgencyRealitySampler(
      minimumInterval: const Duration(minutes: 15),
      screenTimeSupported: () => true,
      calendarSupported: () => false,
      hasUsageStatsPermission: () async => permitted,
      hasCalendarPermission: () async => false,
      invokeDeviceTool: (method, args) async {
        calls.add(method);
        return jsonEncode({'total_minutes': 10, 'apps': const []});
      },
    );
    const assistant = Assistant(
      id: 'a',
      name: 'Companion',
      localToolIds: [LocalToolNames.screenTime],
    );
    final now = DateTime(2026, 10, 5, 0, 0);

    await sampler.sample(
      assistant: assistant,
      conversationId: 'conversation-1',
      now: now,
    );
    permitted = true;
    await sampler.sample(
      assistant: assistant,
      conversationId: 'conversation-1',
      now: now.add(const Duration(minutes: 1)),
    );

    expect(calls, ['getScreenTime']);
  });
}

import 'package:Kelivo/core/agency/agency_event.dart';
import 'package:Kelivo/core/agency/agency_event_bus.dart';
import 'package:Kelivo/core/agency/agency_world_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device-global reality is available across conversations', () async {
    final bus = AgencyEventBus();
    final world = AgencyWorldState(bus: bus)..start();
    addTearDown(() async {
      await world.stop();
      await bus.dispose();
    });
    final now = DateTime(2026, 10, 5, 1);

    bus.post(
      AgencyEvent(
        kind: AgencyEventKind.batteryChanged,
        occurredAt: now,
        payload: const <String, Object?>{
          'level': 42,
          'charging': true,
          'originAssistantId': 'a',
          'originConversationId': 'c1',
        },
      ),
    );
    bus.post(
      AgencyEvent(
        kind: AgencyEventKind.networkChanged,
        occurredAt: now,
        payload: const <String, Object?>{
          'online': true,
          'transport': 'wifi',
          'metered': false,
          'originAssistantId': 'a',
          'originConversationId': 'c1',
        },
      ),
    );

    final prompt = world.buildSystemContext(
      assistantId: 'b',
      conversationId: 'c2',
      now: now,
    );

    expect(prompt, contains('level=42%'));
    expect(prompt, contains('transport=wifi'));
  });

  test('calendar and screen time remain scoped to their origin', () async {
    final bus = AgencyEventBus();
    final world = AgencyWorldState(bus: bus)..start();
    addTearDown(() async {
      await world.stop();
      await bus.dispose();
    });
    final now = DateTime.parse('2026-10-05T10:00:00+08:00');

    bus.post(
      AgencyEvent(
        kind: AgencyEventKind.screenTimeThreshold,
        occurredAt: now,
        dedupeKey: 'screen:a:c1:2026-10-05:300',
        payload: const <String, Object?>{
          'originAssistantId': 'a',
          'originConversationId': 'c1',
          'date': '2026-10-05',
          'totalMinutes': 315,
          'thresholdMinutes': 300,
        },
      ),
    );
    bus.post(
      AgencyEvent(
        kind: AgencyEventKind.calendarUpcoming,
        occurredAt: now,
        dedupeKey: 'calendar:a:c1:7',
        payload: const <String, Object?>{
          'originAssistantId': 'a',
          'originConversationId': 'c1',
          'title': 'Meeting',
          'location': 'Room 2',
          'start': '2026-10-05T10:30:00+08:00[Asia/Shanghai]',
        },
      ),
    );

    final sameOrigin = world.buildSystemContext(
      assistantId: 'a',
      conversationId: 'c1',
      now: now,
    );
    final otherOrigin = world.buildSystemContext(
      assistantId: 'b',
      conversationId: 'c2',
      now: now,
    );

    expect(sameOrigin, contains('315 minutes'));
    expect(sameOrigin, contains('Meeting'));
    expect(otherOrigin, isNull);
  });

  test('bluetooth audio connection is removed on disconnect', () async {
    final bus = AgencyEventBus();
    final world = AgencyWorldState(bus: bus)..start();
    addTearDown(() async {
      await world.stop();
      await bus.dispose();
    });
    final now = DateTime(2026, 10, 5, 1);

    AgencyEvent bluetooth(bool connected) => AgencyEvent(
      kind: AgencyEventKind.bluetoothDeviceSeen,
      occurredAt: now,
      payload: <String, Object?>{
        'connected': connected,
        'deviceKey': 'a2dp:My Buds',
        'deviceType': 'a2dp',
        'deviceName': 'My Buds',
      },
    );

    bus.post(bluetooth(true));
    expect(
      world.buildSystemContext(
        assistantId: 'a',
        conversationId: 'c',
        now: now,
      ),
      contains('My Buds'),
    );

    bus.post(bluetooth(false));
    expect(
      world.buildSystemContext(
        assistantId: 'a',
        conversationId: 'c',
        now: now,
      ),
      isNull,
    );
  });
}

import 'package:Kelivo/core/agency/agency_appraiser.dart';
import 'package:Kelivo/core/agency/agency_coordinator.dart';
import 'package:Kelivo/core/agency/agency_event.dart';
import 'package:Kelivo/core/agency/agency_event_bus.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AgencyAppraiser', () {
    final now = DateTime(2026, 10, 4, 20);

    test('rests for low-salience heartbeat', () {
      const appraiser = AgencyAppraiser();
      final result = appraiser.appraise(
        AgencyEvent(kind: AgencyEventKind.heartbeat, occurredAt: now),
        const AgencyAppraisalContext(),
        now: now,
      );

      expect(result.action, AgencyAppraisalAction.rest);
      expect(result.score, lessThan(0.55));
    });

    test('considers a calendar event without an LLM gate', () {
      const appraiser = AgencyAppraiser();
      final result = appraiser.appraise(
        AgencyEvent(kind: AgencyEventKind.calendarUpcoming, occurredAt: now),
        const AgencyAppraisalContext(),
        now: now,
      );

      expect(result.action, AgencyAppraisalAction.consider);
      expect(result.score, greaterThanOrEqualTo(0.55));
    });

    test('cooldown suppresses non-urgent proactive contact', () {
      const appraiser = AgencyAppraiser();
      final result = appraiser.appraise(
        AgencyEvent(
          kind: AgencyEventKind.notificationReceived,
          occurredAt: now,
        ),
        AgencyAppraisalContext(
          lastProactiveMessageAt: now.subtract(const Duration(minutes: 5)),
        ),
        now: now,
      );

      expect(result.action, AgencyAppraisalAction.rest);
      expect(result.reasons, contains('proactive_cooldown'));
    });

    test('urgent event may pass the daily cap', () {
      const appraiser = AgencyAppraiser();
      final result = appraiser.appraise(
        AgencyEvent(
          kind: AgencyEventKind.calendarUpcoming,
          occurredAt: now,
          urgency: 0.95,
        ),
        const AgencyAppraisalContext(proactiveMessagesToday: 99),
        now: now,
      );

      expect(result.action, AgencyAppraisalAction.consider);
      expect(result.score, 0.95);
    });
  });

  test('AgencyEventBus keeps only a bounded local history', () async {
    final bus = AgencyEventBus(maxRecentEvents: 2);
    addTearDown(bus.dispose);

    bus.post(AgencyEvent(kind: AgencyEventKind.heartbeat));
    bus.post(AgencyEvent(kind: AgencyEventKind.appResumed));
    bus.post(AgencyEvent(kind: AgencyEventKind.calendarUpcoming));

    expect(bus.recent, hasLength(2));
    expect(bus.recent.first.kind, AgencyEventKind.appResumed);
    expect(bus.recent.last.kind, AgencyEventKind.calendarUpcoming);
  });

  test('AgencyCoordinator emits only events that pass the cheap gate', () async {
    final bus = AgencyEventBus();
    final coordinator = AgencyCoordinator(bus: bus);
    addTearDown(() async {
      await coordinator.stop();
      await bus.dispose();
    });
    coordinator.start();

    final candidates = <AgencyConsideration>[];
    final subscription = coordinator.considerations.listen(candidates.add);
    addTearDown(subscription.cancel);

    bus.post(AgencyEvent(kind: AgencyEventKind.heartbeat));
    bus.post(AgencyEvent(kind: AgencyEventKind.calendarUpcoming));

    expect(candidates, hasLength(1));
    expect(candidates.single.event.kind, AgencyEventKind.calendarUpcoming);
  });
}

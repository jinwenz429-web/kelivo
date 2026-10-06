import 'package:Kelivo/core/agency/agency_appraiser.dart';
import 'package:Kelivo/core/agency/agency_coordinator.dart';
import 'package:Kelivo/core/agency/agency_event.dart';
import 'package:Kelivo/core/agency/agency_event_bus.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/business_preferences_test_harness.dart';

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
    await coordinator.start();

    final candidates = <AgencyConsideration>[];
    final subscription = coordinator.considerations.listen(candidates.add);
    addTearDown(subscription.cancel);

    bus.post(AgencyEvent(kind: AgencyEventKind.heartbeat));
    bus.post(AgencyEvent(kind: AgencyEventKind.calendarUpcoming));

    expect(candidates, hasLength(1));
    expect(candidates.single.event.kind, AgencyEventKind.calendarUpcoming);
  });

  test('AgencyCoordinator deduplicates only after successful delivery', () async {
    final bus = AgencyEventBus();
    final coordinator = AgencyCoordinator(
      bus: bus,
      appraiser: const AgencyAppraiser(
        policy: AgencyAppraisalPolicy(
          proactiveCooldown: Duration.zero,
          dailyProactiveCap: 99,
        ),
      ),
    );
    addTearDown(() async {
      await coordinator.stop();
      await bus.dispose();
    });
    await coordinator.start();

    final candidates = <AgencyConsideration>[];
    final subscription = coordinator.considerations.listen(candidates.add);
    addTearDown(subscription.cancel);

    final now = DateTime(2026, 10, 4, 20);
    AgencyEvent eventAt(DateTime at) => AgencyEvent(
      kind: AgencyEventKind.calendarUpcoming,
      occurredAt: at,
      dedupeKey: 'calendar:a:c:7|2026-10-04T20:20:00+08:00',
    );

    bus.post(eventAt(now));
    bus.post(eventAt(now.add(const Duration(minutes: 1))));
    expect(candidates, hasLength(2));

    await coordinator.recordProactiveMessage(
      at: now.add(const Duration(minutes: 2)),
      eventKey: candidates.last.event.dedupeKey,
    );
    bus.post(eventAt(now.add(const Duration(minutes: 3))));

    expect(candidates, hasLength(2));
  });

  test('AgencyCoordinator restores delivered-event dedupe across restart and day rollover', () async {
    final harness = await BusinessPreferencesTestHarness.create();
    addTearDown(harness.dispose);

    final now = DateTime.now();
    final deliveredAt = now.subtract(const Duration(days: 1));
    const eventKey = 'calendar:a:c:restart-test';
    const policy = AgencyAppraisalPolicy(
      proactiveCooldown: Duration.zero,
      dailyProactiveCap: 99,
    );

    final firstSession = await harness.open();
    final firstBus = AgencyEventBus();
    final first = AgencyCoordinator(
      bus: firstBus,
      appraiser: const AgencyAppraiser(policy: policy),
      preferences: firstSession.preferences,
    );
    await first.start();
    await first.recordProactiveMessage(
      at: deliveredAt,
      eventKey: eventKey,
    );
    final stored =
        firstSession.preferences.getString('agency_delivery_state_v1') ?? '';
    expect(stored, isNot(contains(eventKey)));
    await first.stop();
    await firstBus.dispose();
    await firstSession.close();

    final secondSession = await harness.open();
    final secondBus = AgencyEventBus();
    final second = AgencyCoordinator(
      bus: secondBus,
      appraiser: const AgencyAppraiser(policy: policy),
      preferences: secondSession.preferences,
    );
    addTearDown(() async {
      await second.stop();
      await secondBus.dispose();
    });
    await second.start();

    final candidates = <AgencyConsideration>[];
    final subscription = second.considerations.listen(candidates.add);
    addTearDown(subscription.cancel);

    secondBus.post(
      AgencyEvent(
        kind: AgencyEventKind.calendarUpcoming,
        occurredAt: now.add(const Duration(minutes: 1)),
        dedupeKey: eventKey,
      ),
    );

    expect(candidates, isEmpty);
  });

  test('AgencyCoordinator restores proactive cooldown after restart', () async {
    final harness = await BusinessPreferencesTestHarness.create();
    addTearDown(harness.dispose);

    final now = DateTime.now();
    final firstSession = await harness.open();
    final firstBus = AgencyEventBus();
    final first = AgencyCoordinator(
      bus: firstBus,
      preferences: firstSession.preferences,
    );
    await first.start();
    await first.recordProactiveMessage(at: now);
    await first.stop();
    await firstBus.dispose();
    await firstSession.close();

    final secondSession = await harness.open();
    final secondBus = AgencyEventBus();
    final second = AgencyCoordinator(
      bus: secondBus,
      preferences: secondSession.preferences,
    );
    addTearDown(() async {
      await second.stop();
      await secondBus.dispose();
    });
    await second.start();

    final candidates = <AgencyConsideration>[];
    final subscription = second.considerations.listen(candidates.add);
    addTearDown(subscription.cancel);

    secondBus.post(
      AgencyEvent(
        kind: AgencyEventKind.calendarUpcoming,
        occurredAt: now.add(const Duration(minutes: 1)),
      ),
    );

    expect(candidates, isEmpty);
  });
}

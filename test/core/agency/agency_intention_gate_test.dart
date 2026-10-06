import 'package:Kelivo/core/agency/agency_appraiser.dart';
import 'package:Kelivo/core/agency/agency_coordinator.dart';
import 'package:Kelivo/core/agency/agency_event.dart';
import 'package:Kelivo/core/agency/agency_intention_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const gate = AgencyIntentionGate();

  AgencyConsideration consideration(
    AgencyEvent event, {
    double score = 0.8,
  }) => AgencyConsideration(
    event: event,
    appraisal: AgencyAppraisal(
      action: AgencyAppraisalAction.consider,
      score: score,
      reasons: const <String>['test'],
    ),
  );

  test('calendar waits until the event is close enough', () {
    final early = gate.decide(
      consideration(
        AgencyEvent(
          kind: AgencyEventKind.calendarUpcoming,
          payload: const <String, Object?>{'minutesUntil': 70},
        ),
      ),
    );
    final near = gate.decide(
      consideration(
        AgencyEvent(
          kind: AgencyEventKind.calendarUpcoming,
          payload: const <String, Object?>{'minutesUntil': 30},
        ),
      ),
    );

    expect(early.action, AgencyIntentionAction.retain);
    expect(near.action, AgencyIntentionAction.message);
  });

  test('screen time observes 180 minutes but interrupts at 300', () {
    final observed = gate.decide(
      consideration(
        AgencyEvent(
          kind: AgencyEventKind.screenTimeThreshold,
          payload: const <String, Object?>{'thresholdMinutes': 180},
        ),
      ),
    );
    final high = gate.decide(
      consideration(
        AgencyEvent(
          kind: AgencyEventKind.screenTimeThreshold,
          payload: const <String, Object?>{'thresholdMinutes': 300},
        ),
      ),
    );

    expect(observed.action, AgencyIntentionAction.retain);
    expect(high.action, AgencyIntentionAction.message);
  });

  test('battery only interrupts when low and not charging', () {
    final charging = gate.decide(
      consideration(
        AgencyEvent(
          kind: AgencyEventKind.batteryChanged,
          payload: const <String, Object?>{
            'level': 10,
            'charging': true,
          },
        ),
      ),
    );
    final low = gate.decide(
      consideration(
        AgencyEvent(
          kind: AgencyEventKind.batteryChanged,
          payload: const <String, Object?>{
            'level': 18,
            'charging': false,
          },
        ),
      ),
    );

    expect(charging.action, AgencyIntentionAction.retain);
    expect(low.action, AgencyIntentionAction.message);
  });

  test('network and bluetooth stay ambient by default', () {
    final network = gate.decide(
      consideration(AgencyEvent(kind: AgencyEventKind.networkChanged)),
    );
    final bluetooth = gate.decide(
      consideration(AgencyEvent(kind: AgencyEventKind.bluetoothDeviceSeen)),
    );

    expect(network.action, AgencyIntentionAction.retain);
    expect(bluetooth.action, AgencyIntentionAction.retain);
  });
}

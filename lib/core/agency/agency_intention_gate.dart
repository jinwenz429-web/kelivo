import 'agency_appraiser.dart';
import 'agency_coordinator.dart';
import 'agency_event.dart';

enum AgencyIntentionAction { rest, retain, message }

class AgencyIntention {
  const AgencyIntention({
    required this.action,
    required this.reason,
  });

  final AgencyIntentionAction action;
  final String reason;

  bool get shouldMessage => action == AgencyIntentionAction.message;
}

/// Second-stage interruption policy.
///
/// [AgencyAppraiser] answers whether a signal is salient enough to consider.
/// This gate answers what to do with that considered signal. Keeping this
/// deterministic means reality sensing itself remains cheap and predictable;
/// a later deliberation model can replace or augment this policy without
/// changing sensor/event plumbing.
class AgencyIntentionGate {
  const AgencyIntentionGate();

  AgencyIntention decide(AgencyConsideration consideration) {
    final event = consideration.event;

    switch (event.kind) {
      case AgencyEventKind.calendarUpcoming:
        final minutesUntil = _asInt(event.payload['minutesUntil']);
        if (minutesUntil == null || minutesUntil < 0) {
          return const AgencyIntention(
            action: AgencyIntentionAction.rest,
            reason: 'invalid_calendar_time',
          );
        }
        if (minutesUntil <= 45 || event.urgency >= 0.9) {
          return const AgencyIntention(
            action: AgencyIntentionAction.message,
            reason: 'calendar_near',
          );
        }
        return const AgencyIntention(
          action: AgencyIntentionAction.retain,
          reason: 'calendar_not_yet_interruptive',
        );

      case AgencyEventKind.screenTimeThreshold:
        final threshold = _asInt(event.payload['thresholdMinutes']) ?? 0;
        if (threshold >= 300) {
          return const AgencyIntention(
            action: AgencyIntentionAction.message,
            reason: 'screen_time_high',
          );
        }
        return const AgencyIntention(
          action: AgencyIntentionAction.retain,
          reason: 'screen_time_observed',
        );

      case AgencyEventKind.batteryChanged:
        final charging = event.payload['charging'] == true;
        final level = _asInt(event.payload['level']) ?? 100;
        if (!charging && level <= 20) {
          return const AgencyIntention(
            action: AgencyIntentionAction.message,
            reason: 'battery_low',
          );
        }
        return const AgencyIntention(
          action: AgencyIntentionAction.retain,
          reason: 'battery_observed',
        );

      case AgencyEventKind.notificationReceived:
        if (event.urgency >= 0.9) {
          return const AgencyIntention(
            action: AgencyIntentionAction.message,
            reason: 'urgent_notification',
          );
        }
        return const AgencyIntention(
          action: AgencyIntentionAction.retain,
          reason: 'notification_observed',
        );

      case AgencyEventKind.bluetoothDeviceSeen:
      case AgencyEventKind.networkChanged:
      case AgencyEventKind.locationChanged:
        return const AgencyIntention(
          action: AgencyIntentionAction.retain,
          reason: 'ambient_context_only',
        );

      case AgencyEventKind.heartbeat:
      case AgencyEventKind.appResumed:
      case AgencyEventKind.appBackgrounded:
      case AgencyEventKind.userMessage:
      case AgencyEventKind.assistantMessage:
        return const AgencyIntention(
          action: AgencyIntentionAction.rest,
          reason: 'no_proactive_action',
        );
    }
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '');
  }
}

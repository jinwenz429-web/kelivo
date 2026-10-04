import 'agency_event.dart';

enum AgencyAppraisalAction { rest, consider }

class AgencyAppraisalContext {
  const AgencyAppraisalContext({
    this.busy = false,
    this.lastUserInteractionAt,
    this.lastProactiveMessageAt,
    this.proactiveMessagesToday = 0,
  });

  final bool busy;
  final DateTime? lastUserInteractionAt;
  final DateTime? lastProactiveMessageAt;
  final int proactiveMessagesToday;
}

class AgencyAppraisalPolicy {
  const AgencyAppraisalPolicy({
    this.considerationThreshold = 0.55,
    this.proactiveCooldown = const Duration(minutes: 45),
    this.recentUserWindow = const Duration(minutes: 10),
    this.dailyProactiveCap = 4,
  });

  final double considerationThreshold;
  final Duration proactiveCooldown;
  final Duration recentUserWindow;
  final int dailyProactiveCap;
}

class AgencyAppraisal {
  const AgencyAppraisal({
    required this.action,
    required this.score,
    required this.reasons,
  });

  final AgencyAppraisalAction action;
  final double score;
  final List<String> reasons;

  bool get shouldConsider => action == AgencyAppraisalAction.consider;
}

/// Cheap, deterministic first gate. It deliberately does not call an LLM.
///
/// The weights are defaults, not personality. They answer only "is this worth
/// spending more thought on?" A later intention/interrupt gate owns the actual
/// companion behavior.
class AgencyAppraiser {
  const AgencyAppraiser({this.policy = const AgencyAppraisalPolicy()});

  final AgencyAppraisalPolicy policy;

  AgencyAppraisal appraise(
    AgencyEvent event,
    AgencyAppraisalContext context, {
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final reasons = <String>[];

    if (context.busy) {
      return const AgencyAppraisal(
        action: AgencyAppraisalAction.rest,
        score: 0,
        reasons: <String>['conversation_busy'],
      );
    }

    var score = _baseWeight(event.kind);
    score = score < event.urgency ? event.urgency : score;
    reasons.add('base:' + event.kind.name);

    final lastProactive = context.lastProactiveMessageAt;
    if (lastProactive != null &&
        clock.difference(lastProactive) < policy.proactiveCooldown) {
      score -= 0.45;
      reasons.add('proactive_cooldown');
    }

    final lastUser = context.lastUserInteractionAt;
    if (lastUser != null &&
        clock.difference(lastUser) < policy.recentUserWindow &&
        (event.kind == AgencyEventKind.heartbeat ||
            event.kind == AgencyEventKind.appResumed)) {
      score -= 0.35;
      reasons.add('user_recently_active');
    }

    if (context.proactiveMessagesToday >= policy.dailyProactiveCap &&
        event.urgency < 0.9) {
      score = 0;
      reasons.add('daily_cap');
    }

    final bounded = score.clamp(0.0, 1.0).toDouble();
    return AgencyAppraisal(
      action: bounded >= policy.considerationThreshold
          ? AgencyAppraisalAction.consider
          : AgencyAppraisalAction.rest,
      score: bounded,
      reasons: List<String>.unmodifiable(reasons),
    );
  }

  static double _baseWeight(AgencyEventKind kind) => switch (kind) {
    AgencyEventKind.heartbeat => 0.15,
    AgencyEventKind.appResumed => 0.25,
    AgencyEventKind.appBackgrounded => 0.05,
    AgencyEventKind.userMessage => 0.0,
    AgencyEventKind.assistantMessage => 0.05,
    AgencyEventKind.calendarUpcoming => 0.72,
    AgencyEventKind.screenTimeThreshold => 0.65,
    AgencyEventKind.batteryChanged => 0.30,
    AgencyEventKind.networkChanged => 0.25,
    AgencyEventKind.bluetoothDeviceSeen => 0.12,
    AgencyEventKind.notificationReceived => 0.62,
  };
}

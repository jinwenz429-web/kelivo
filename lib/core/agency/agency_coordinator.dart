import 'dart:async';

import 'agency_appraiser.dart';
import 'agency_event.dart';
import 'agency_event_bus.dart';

class AgencyConsideration {
  const AgencyConsideration({
    required this.event,
    required this.appraisal,
  });

  final AgencyEvent event;
  final AgencyAppraisal appraisal;
}

/// App-wide cheap gate between raw local signals and expensive agent work.
///
/// This coordinator never calls a model. It turns many noisy device/app events
/// into a much smaller stream of "worth considering" candidates.
class AgencyCoordinator {
  AgencyCoordinator({
    AgencyEventBus? bus,
    AgencyAppraiser appraiser = const AgencyAppraiser(),
  }) : _bus = bus ?? AgencyEventBus.instance,
       _appraiser = appraiser;

  static final AgencyCoordinator instance = AgencyCoordinator();

  final AgencyEventBus _bus;
  final AgencyAppraiser _appraiser;
  final StreamController<AgencyConsideration> _considerations =
      StreamController<AgencyConsideration>.broadcast(sync: true);

  StreamSubscription<AgencyEvent>? _subscription;
  bool Function()? _busy;
  DateTime? _lastUserInteractionAt;
  DateTime? _lastProactiveMessageAt;
  DateTime? _countDate;
  int _proactiveMessagesToday = 0;

  Stream<AgencyConsideration> get considerations => _considerations.stream;

  void start({bool Function()? busy}) {
    _busy = busy ?? _busy;
    _subscription ??= _bus.events.listen(_onEvent);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  void recordProactiveMessage({DateTime? at}) {
    final when = at ?? DateTime.now();
    _rollDay(when);
    _lastProactiveMessageAt = when;
    _proactiveMessagesToday++;
  }

  void _onEvent(AgencyEvent event) {
    _rollDay(event.occurredAt);
    if (event.kind == AgencyEventKind.userMessage) {
      _lastUserInteractionAt = event.occurredAt;
    }

    final appraisal = _appraiser.appraise(
      event,
      AgencyAppraisalContext(
        busy: _busy?.call() ?? false,
        lastUserInteractionAt: _lastUserInteractionAt,
        lastProactiveMessageAt: _lastProactiveMessageAt,
        proactiveMessagesToday: _proactiveMessagesToday,
      ),
      now: event.occurredAt,
    );
    if (!appraisal.shouldConsider) return;
    _considerations.add(
      AgencyConsideration(event: event, appraisal: appraisal),
    );
  }

  void _rollDay(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    if (_countDate == day) return;
    _countDate = day;
    _proactiveMessagesToday = 0;
  }
}

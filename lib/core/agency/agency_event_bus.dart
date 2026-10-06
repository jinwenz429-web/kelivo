import 'dart:async';
import 'dart:collection';

import 'agency_event.dart';

/// Local-only event bus for companion signals.
///
/// Posting an event performs no network request and no database write. The
/// bounded recent buffer exists only for diagnostics and near-term appraisal.
class AgencyEventBus {
  AgencyEventBus({this.maxRecentEvents = 128});

  static final AgencyEventBus instance = AgencyEventBus();

  final int maxRecentEvents;
  final ListQueue<AgencyEvent> _recent = ListQueue<AgencyEvent>();
  final StreamController<AgencyEvent> _controller =
      StreamController<AgencyEvent>.broadcast(sync: true);

  Stream<AgencyEvent> get events => _controller.stream;
  List<AgencyEvent> get recent => List<AgencyEvent>.unmodifiable(_recent);

  void post(AgencyEvent event) {
    if (maxRecentEvents <= 0) {
      _controller.add(event);
      return;
    }
    while (_recent.length >= maxRecentEvents) {
      _recent.removeFirst();
    }
    _recent.addLast(event);
    _controller.add(event);
  }

  void clearRecent() => _recent.clear();

  Future<void> dispose() => _controller.close();
}

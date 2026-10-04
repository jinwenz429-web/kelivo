import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../database/business_preferences.dart';
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
    BusinessPreferences? preferences,
  }) : _bus = bus ?? AgencyEventBus.instance,
       _appraiser = appraiser,
       _preferences = preferences;

  static final AgencyCoordinator instance = AgencyCoordinator();
  static const String _deliveryStateKey = 'agency_delivery_state_v1';

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
  final Set<String> _deliveredEventKeys = <String>{};

  BusinessPreferences? _preferences;
  Future<void>? _restoreFuture;
  bool _stateReady = false;
  final List<AgencyEvent> _pendingEvents = <AgencyEvent>[];

  Stream<AgencyConsideration> get considerations => _considerations.stream;

  /// Starts listening immediately and restores durable delivery bookkeeping.
  ///
  /// Events arriving before the local state is restored are queued, so an app
  /// restart cannot briefly bypass dedupe/cooldown/daily-cap policy.
  Future<void> start({
    bool Function()? busy,
    BusinessPreferences? preferences,
  }) {
    _busy = busy ?? _busy;
    _preferences ??= preferences;
    _subscription ??= _bus.events.listen(_onEvent);
    return _ensureStateReady();
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _pendingEvents.clear();
  }

  /// Records a proactive turn only after its final assistant message has been
  /// durably persisted, then persists the delivery ledger before returning.
  Future<void> recordProactiveMessage({DateTime? at, String? eventKey}) async {
    await _ensureStateReady();
    final when = at ?? DateTime.now();
    _rollDay(when);
    _lastProactiveMessageAt = when;
    _proactiveMessagesToday++;
    final key = eventKey?.trim();
    if (key != null && key.isNotEmpty) {
      _deliveredEventKeys.add(_digestEventKey(key));
      while (_deliveredEventKeys.length > 256) {
        _deliveredEventKeys.remove(_deliveredEventKeys.first);
      }
    }
    await _persistState();
  }

  Future<void> _ensureStateReady() {
    if (_stateReady) return Future<void>.value();
    return _restoreFuture ??= _restoreState();
  }

  Future<void> _restoreState() async {
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      _countDate = today;

      final prefs = _preferences;
      if (prefs == null) return;
      await prefs.load();
      final raw = prefs.getString(_deliveryStateKey);

      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final json = Map<String, dynamic>.from(decoded);
          _lastProactiveMessageAt = DateTime.tryParse(
            json['lastProactiveAt']?.toString() ?? '',
          );

          final savedDay = DateTime.tryParse(json['day']?.toString() ?? '');
          final normalizedSavedDay = savedDay == null
              ? null
              : DateTime(savedDay.year, savedDay.month, savedDay.day);
          if (normalizedSavedDay == today) {
            final count = json['proactiveMessagesToday'];
            _proactiveMessagesToday = count is num
                ? count.toInt().clamp(0, 1000000).toInt()
                : 0;
          }

          final keys = json['deliveredEventKeys'];
          if (keys is List) {
            _deliveredEventKeys
              ..clear()
              ..addAll(
                keys
                    .map((value) => value?.toString().trim() ?? '')
                    .where((value) => value.isNotEmpty),
              );
            while (_deliveredEventKeys.length > 256) {
              _deliveredEventKeys.remove(_deliveredEventKeys.first);
            }
          }
        }
      }
    } catch (_) {
      // Corrupt/missing local bookkeeping should fail open to a clean ledger,
      // never break chat startup.
      final now = DateTime.now();
      _countDate = DateTime(now.year, now.month, now.day);
      _lastProactiveMessageAt = null;
      _proactiveMessagesToday = 0;
      _deliveredEventKeys.clear();
    } finally {
      _stateReady = true;
      _restoreFuture = null;
      final queued = List<AgencyEvent>.of(_pendingEvents);
      _pendingEvents.clear();
      if (_subscription != null) {
        for (final event in queued) {
          _processEvent(event);
        }
      }
    }
  }

  Future<void> _persistState() async {
    final prefs = _preferences;
    if (prefs == null) return;
    await prefs.load();
    final now = DateTime.now();
    final day = _countDate ?? DateTime(now.year, now.month, now.day);
    final saved = await prefs.setString(
      _deliveryStateKey,
      jsonEncode(<String, Object?>{
        'day': _dayKey(day),
        'lastProactiveAt': _lastProactiveMessageAt?.toIso8601String(),
        'proactiveMessagesToday': _proactiveMessagesToday,
        'deliveredEventKeys': _deliveredEventKeys.toList(growable: false),
      }),
    );
    if (!saved) {
      throw StateError('agency_delivery_state_write_failed');
    }
  }

  void _onEvent(AgencyEvent event) {
    if (!_stateReady) {
      if (_pendingEvents.length < 100) {
        _pendingEvents.add(event);
      }
      return;
    }
    _processEvent(event);
  }

  void _processEvent(AgencyEvent event) {
    _rollDay(event.occurredAt);
    final key = event.dedupeKey?.trim();
    if (key != null &&
        key.isNotEmpty &&
        _deliveredEventKeys.contains(_digestEventKey(key))) {
      return;
    }
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

  static String _dayKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static String _digestEventKey(String value) =>
      sha256.convert(utf8.encode(value)).toString();
}

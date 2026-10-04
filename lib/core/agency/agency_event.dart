enum AgencyEventKind {
  heartbeat,
  appResumed,
  appBackgrounded,
  userMessage,
  assistantMessage,
  calendarUpcoming,
  screenTimeThreshold,
  batteryChanged,
  networkChanged,
  bluetoothDeviceSeen,
  notificationReceived,
}

/// A small, local fact about something that happened around the companion.
///
/// Events intentionally carry metadata rather than chat text. The conversation
/// remains the source of truth for message content; the agency layer only needs
/// enough information to decide whether an event deserves attention.
class AgencyEvent {
  AgencyEvent({
    required this.kind,
    DateTime? occurredAt,
    this.source = 'local',
    this.urgency = 0,
    this.dedupeKey,
    this.payload = const <String, Object?>{},
  }) : occurredAt = occurredAt ?? DateTime.now();

  final AgencyEventKind kind;
  final DateTime occurredAt;
  final String source;
  final double urgency;

  /// Stable identity for a real-world fact that should be delivered once.
  ///
  /// It is marked handled only after a proactive assistant turn successfully
  /// persists, so rejected/busy attempts remain retryable.
  final String? dedupeKey;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'occurredAt': occurredAt.toIso8601String(),
    'source': source,
    'urgency': urgency.clamp(0.0, 1.0),
    if (dedupeKey != null) 'dedupeKey': dedupeKey,
    'payload': payload,
  };

  factory AgencyEvent.fromJson(Map<String, Object?> json) {
    final rawKind = json['kind']?.toString();
    final kind = AgencyEventKind.values.firstWhere(
      (value) => value.name == rawKind,
      orElse: () => AgencyEventKind.heartbeat,
    );
    final rawUrgency = json['urgency'];
    return AgencyEvent(
      kind: kind,
      occurredAt:
          DateTime.tryParse(json['occurredAt']?.toString() ?? '') ??
          DateTime.now(),
      source: json['source']?.toString() ?? 'local',
      urgency: rawUrgency is num
          ? rawUrgency.toDouble().clamp(0.0, 1.0).toDouble()
          : 0.0,
      dedupeKey: json['dedupeKey']?.toString(),
      payload: json['payload'] is Map
          ? Map<String, Object?>.from(json['payload']! as Map)
          : const <String, Object?>{},
    );
  }
}

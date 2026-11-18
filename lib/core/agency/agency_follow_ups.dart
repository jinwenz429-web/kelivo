import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../database/business_preferences.dart';

/// Something the user mentioned that is worth asking about later, such as an
/// exam this afternoon or a doctor visit tonight.
@immutable
class AgencyFollowUp {
  const AgencyFollowUp({
    required this.what,
    required this.askAfter,
    required this.conversationId,
  });

  final String what;
  final DateTime askAfter;
  final String conversationId;

  /// A follow-up older than this is stale and dropped unasked.
  static const lifetime = Duration(hours: 36);

  bool isDue(DateTime now) =>
      !now.isBefore(askAfter) && now.difference(askAfter) < lifetime;

  bool isExpired(DateTime now) => now.difference(askAfter) >= lifetime;

  Map<String, Object?> toJson() => {
    'what': what,
    'askAfter': askAfter.toIso8601String(),
    'conversationId': conversationId,
  };

  static AgencyFollowUp? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final what = raw['what']?.toString().trim() ?? '';
    final at = DateTime.tryParse(raw['askAfter']?.toString() ?? '');
    final conversationId = raw['conversationId']?.toString() ?? '';
    if (what.isEmpty || at == null || conversationId.isEmpty) return null;
    return AgencyFollowUp(
      what: what,
      askAfter: at,
      conversationId: conversationId,
    );
  }
}

/// Prompt for a cheap model that picks follow-ups out of recent chat.
String followUpExtractionPrompt({
  required DateTime now,
  required String transcript,
}) =>
    '''
现在是 ${now.toIso8601String()}（本地时间）。下面是一段聊天记录，「我」是用户，「它」是陪伴用户的 AI。

找出用户提到的、过一阵值得回来关心一下结果的具体事情：考试、面试、看病、出门、赶路、截止日期、见朋友、身体不舒服之类。
每件事给出一个「之后可以问」的时间：事情结束后一会儿；没说具体时间的就按常理估。已经在聊天里说完结果的、只是随口一提的、AI 自己的事，都不要。

只输出 JSON 数组，不要别的文字。每项格式：{"what": "用一句话说是什么事，用第二人称，如：你下午三点的考试", "askAfter": "ISO 8601 本地时间"}
没有就输出 []。

聊天记录：
$transcript''';

/// Parses the extractor's reply, keeping only well-formed future-ish items.
List<AgencyFollowUp> parseFollowUps(
  String raw, {
  required DateTime now,
  required String conversationId,
}) {
  final start = raw.indexOf('[');
  final end = raw.lastIndexOf(']');
  if (start < 0 || end <= start) return const [];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw.substring(start, end + 1));
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];
  final out = <AgencyFollowUp>[];
  for (final item in decoded) {
    final parsed = AgencyFollowUp.fromJson(
      item is Map ? {...item, 'conversationId': conversationId} : null,
    );
    if (parsed == null || parsed.isExpired(now)) continue;
    // A week out is no longer "unfinished business" from this chat.
    if (parsed.askAfter.difference(now) > const Duration(days: 7)) continue;
    out.add(parsed);
  }
  return out;
}

/// Pending follow-ups and how far the extractor has read, per conversation.
class AgencyFollowUpStore {
  AgencyFollowUpStore._();

  static final AgencyFollowUpStore instance = AgencyFollowUpStore._();
  static const _key = 'agency_follow_ups_v1';
  static const maxPending = 12;

  BusinessPreferences? _preferences;

  void attach(BusinessPreferences preferences) => _preferences = preferences;

  Map<String, dynamic> _read() {
    final raw = _preferences?.getString(_key);
    if (raw == null) return {};
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  Future<void> _write(Map<String, dynamic> data) async =>
      _preferences?.setString(_key, jsonEncode(data));

  List<AgencyFollowUp> pending(DateTime now) => [
    for (final raw in (_read()['items'] as List?) ?? const [])
      if (AgencyFollowUp.fromJson(raw) case final f? when !f.isExpired(now)) f,
  ];

  DateTime? readThrough(String conversationId) => DateTime.tryParse(
    ((_read()['readThrough'] as Map?) ?? const {})[conversationId]
            ?.toString() ??
        '',
  );

  Future<void> add(
    List<AgencyFollowUp> items, {
    required String conversationId,
    required DateTime readThrough,
    required DateTime now,
  }) async {
    final data = _read();
    final merged = [...pending(now), ...items];
    final kept = merged.length > maxPending
        ? merged.sublist(merged.length - maxPending)
        : merged;
    data['items'] = [for (final f in kept) f.toJson()];
    data['readThrough'] = {
      ...((data['readThrough'] as Map?) ?? const {}),
      conversationId: readThrough.toIso8601String(),
    };
    await _write(data);
  }

  /// Removes follow-ups that were handed to a wake, asked or not, so the
  /// companion does not keep circling back to the same thing.
  Future<void> consume(Iterable<AgencyFollowUp> used, DateTime now) async {
    final keys = {for (final f in used) '${f.what}|${f.askAfter}'};
    final data = _read();
    data['items'] = [
      for (final f in pending(now))
        if (!keys.contains('${f.what}|${f.askAfter}')) f.toJson(),
    ];
    await _write(data);
  }
}

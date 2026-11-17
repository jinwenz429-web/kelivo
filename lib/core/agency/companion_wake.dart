/// A companion wake is a scheduled follow-up where the assistant decides on
/// its own whether to reach out. It may decline by replying with the silence
/// marker; that reply is discarded without a notification.
library;

const companionSilenceMarker = '[静默]';

const companionWakeDefaultNote = '想想此刻要不要去找对方。';

final RegExp _silencePattern = RegExp(
  r'^\s*[\[【](静默|silent|silence)[\]】]',
  caseSensitive: false,
);

/// Whether a visible reply means "stay quiet this time". Only the opening
/// counts, so a model that adds a short explanation after the marker is still
/// silent, while a real message that mentions the word is not.
bool isCompanionSilence(String visibleContent) =>
    _silencePattern.hasMatch(visibleContent);

/// The ephemeral system context for one wake. It is never stored as a message.
String companionWakeInstruction({
  required DateTime now,
  required String note,
  DateTime? lastMessageAt,
  DateTime? lastUserMessageAt,
}) {
  final lines = <String>[
    '[醒来] 现在是 ${_clock(now)}。这不是对方发来的消息，'
        '是你自己在这个时间醒了一下。',
  ];
  if (lastMessageAt != null) {
    lines.add('距离你们最近一条消息过了 ${_ago(now, lastMessageAt)}。');
  }
  if (lastUserMessageAt != null) {
    lines.add('对方上一次说话是 ${_ago(now, lastUserMessageAt)}前。');
  }
  final trimmed = note.trim();
  lines
    ..add('')
    ..add(trimmed.isEmpty ? companionWakeDefaultNote : trimmed)
    ..add('')
    ..add(
      '想找对方，就直接写你要发的话，像平时发消息一样，可以分几条，条与条之间空一行；'
      '不要提到「醒来」「定时」「系统」「提示」这些。',
    )
    ..add('不想打扰，就只回复 $companionSilenceMarker，别的什么都不写。');
  return lines.join('\n');
}

const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

String _clock(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}年${t.month}月${t.day}日 星期${_weekdays[t.weekday - 1]} '
      '${two(t.hour)}:${two(t.minute)}';
}

String _ago(DateTime now, DateTime then) {
  final d = now.difference(then);
  if (d.isNegative || d.inMinutes < 1) return '不到一分钟';
  if (d.inHours < 1) return '${d.inMinutes} 分钟';
  if (d.inDays < 1) {
    final m = d.inMinutes % 60;
    return m == 0 ? '${d.inHours} 小时' : '${d.inHours} 小时 $m 分钟';
  }
  return '${d.inDays} 天';
}

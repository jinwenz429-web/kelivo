/// Text handling for voice calls: what the companion is told, how its streamed
/// reply is cut into speakable sentences, and what is read aloud versus shown.
library;

import 'package:flutter/widgets.dart' show StringCharacters;

import '../home/services/message_builder_service.dart' show proactiveCueOpening;

/// Which voice engine is reading, and so which sound tags it performs.
enum CallTagDialect {
  /// Tags would be read out as words: drop them all.
  none,

  /// ElevenLabs v3: `[laughs]`, `[whispers]` …
  elevenLabs,

  /// MiniMax speech-2.8: `(laughs)`, `(breath)`, `(pant)` …
  miniMax,
}

/// ElevenLabs v3 audio tags the companion may use.
const callAudioTags = <String>[
  'laughs',
  'chuckles',
  'sighs',
  'whispers',
  'softly',
  'hesitates',
  'pause',
  'excited',
  'curious',
  'sarcastic',
  'crying',
  'clears throat',
  'gasps',
];

/// MiniMax speech-2.8 interjection tags (the full official list).
const miniMaxAudioTags = <String>[
  'laughs',
  'chuckle',
  'sighs',
  'breath',
  'inhale',
  'exhale',
  'pant',
  'gasps',
  'sniffs',
  'emm',
  'humming',
  'groans',
  'coughs',
  'clear-throat',
  'lip-smacking',
  'snorts',
  'hissing',
  'sneezes',
  'burps',
];

/// Tags offered to the companion in the prompt, by dialect. The companion
/// always writes square brackets; MiniMax tags are converted when spoken.
const _promptTags = <CallTagDialect, List<String>>{
  CallTagDialect.elevenLabs: [
    'laughs',
    'chuckles',
    'sighs',
    'whispers',
    'softly',
    'hesitates',
    'gasps',
  ],
  CallTagDialect.miniMax: [
    'laughs',
    'chuckle',
    'sighs',
    'breath',
    'inhale',
    'exhale',
    'pant',
    'gasps',
    'sniffs',
    'emm',
    'humming',
  ],
};

/// ElevenLabs-style names that MiniMax spells differently.
const _miniMaxAliases = <String, String>{
  'chuckles': 'chuckle',
  'clears-throat': 'clear-throat',
  'sigh': 'sighs',
  'laugh': 'laughs',
  'gasp': 'gasps',
  'breathes': 'breath',
  'breathing': 'breath',
  'panting': 'pant',
  'hums': 'humming',
};

String _tagKey(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'[\s_]+'), '-');

final Set<String> _elevenLabsKeys = callAudioTags.map(_tagKey).toSet();
final Set<String> _miniMaxKeys = miniMaxAudioTags.map(_tagKey).toSet();

String _tagAlternatives(Iterable<String> keys) =>
    keys.map((k) => k.split('-').map(RegExp.escape).join(r'[\s_-]+')).join('|');

/// Any known tag, in square brackets (how the companion is told to write
/// them) or in ASCII parentheses with a MiniMax name (in case it copies
/// MiniMax's own style). Unknown bracketed text is left alone.
final RegExp _audioTagPattern = RegExp(
  r'(?:\[\s*(' +
      _tagAlternatives({
        ..._elevenLabsKeys,
        ..._miniMaxKeys,
        ..._miniMaxAliases.keys,
      }) +
      r')\s*\]|\(\s*(' +
      _tagAlternatives(_miniMaxKeys) +
      r')\s*\))\s*',
  caseSensitive: false,
);

/// Rewrites tags for [dialect]: kept as `[x]` for ElevenLabs, turned into
/// `(x)` for MiniMax, dropped when the engine cannot perform them.
String _applyTags(String text, CallTagDialect dialect) =>
    text.replaceAllMapped(_audioTagPattern, (m) {
      final key = _tagKey(m.group(1) ?? m.group(2)!);
      final gap = m.group(0)! != m.group(0)!.trimRight() ? ' ' : '';
      switch (dialect) {
        case CallTagDialect.none:
          return '';
        case CallTagDialect.elevenLabs:
          final name = key.replaceAll('-', ' ');
          return _elevenLabsKeys.contains(key) ? '[$name]$gap' : '';
        case CallTagDialect.miniMax:
          final name = _miniMaxAliases[key] ?? key;
          return _miniMaxKeys.contains(name) ? '($name)$gap' : '';
      }
    });

/// Stage directions: *...*, （...）and (...) that hold no Latin letters
/// (an English aside in parentheses is more likely real speech).
final RegExp _actionPattern = RegExp(
  r'\*[^*\n]{1,80}\*|（[^（）\n]{1,60}）|\([^()\na-zA-Z]{1,60}\)',
);

final RegExp _markdownPattern = RegExp(r'[#>`_~*]');

final RegExp _emojiPattern = RegExp(
  r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{200D}]',
  unicode: true,
);

/// What the subtitles show: no audio tags, no markdown; actions stay.
String callDisplayText(String raw) => raw
    .replaceAll(_audioTagPattern, '')
    .replaceAll(_markdownPattern, '')
    .replaceAll(RegExp(r'[ \t]+'), ' ')
    .trim();

/// What is read aloud: no actions, emoji or markdown. Audio tags are kept
/// only for an engine that performs them, in that engine's own form.
String callSpeechText(String raw, {required CallTagDialect tags}) {
  final text = _applyTags(raw.replaceAll(_actionPattern, ' '), tags);
  return text
      .replaceAll(_markdownPattern, '')
      .replaceAll(_emojiPattern, '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Whether [text] has anything left to say once tags and punctuation are gone.
bool callHasWords(String text) => text
    .replaceAll(_audioTagPattern, '')
    .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '')
    .isNotEmpty;

/// Cuts a streamed reply into sentences as they complete.
class CallSentenceSplitter {
  CallSentenceSplitter({this.softLimit = 40});

  /// Past this many characters a comma also ends a chunk, so a long sentence
  /// starts playing sooner.
  final int softLimit;
  final StringBuffer _buffer = StringBuffer();

  static const _hardEnds = '。！？!?…~～\n';
  static const _softEnds = '，,；;：:、';

  /// Feeds a delta; returns the sentences it completed.
  List<String> add(String delta) {
    _buffer.write(delta);
    final text = _buffer.toString();
    final out = <String>[];
    var start = 0;
    var i = 0;
    while (i < text.length) {
      final ch = text[i];
      final hard = _hardEnds.contains(ch);
      final soft =
          !hard && _softEnds.contains(ch) && i + 1 - start >= softLimit;
      if (!hard && !soft) {
        i++;
        continue;
      }
      // Keep runs like "？！" or "……" with their sentence.
      var end = i + 1;
      while (hard && end < text.length && _hardEnds.contains(text[end])) {
        end++;
      }
      final piece = text.substring(start, end).trim();
      // Punctuation alone (or a lone tag) joins the next sentence instead.
      if (callHasWords(piece)) {
        out.add(piece);
        start = end;
      }
      i = end;
    }
    _buffer
      ..clear()
      ..write(text.substring(start));
    return out;
  }

  /// Whatever is left when the stream ends.
  String flush() {
    final rest = _buffer.toString().trim();
    _buffer.clear();
    return callHasWords(rest) ? rest : '';
  }
}

/// Call instructions appended to the assistant's own system prompt.
String callSystemInstructions({
  required CallTagDialect audioTags,
  required String userName,
}) {
  final lines = <String>[
    '# 现在在打语音电话',
    '你和$userName正在打语音电话，你说的每个字都会被直接念出来给对方听。',
    '- 像真打电话那样说话：口语、短句，一次说一到三句，别长篇大论，别列清单。',
    '- 不要写动作、神态、旁白，不要用星号或括号描写动作，不要用表情符号和 Markdown。',
    '- 对方的话是语音识别转出来的，可能有错字或断句不对，按意思理解，别纠正对方的字。',
    '- 对方可能会打断你，被打断就顺着对方的新话说，不用把刚才没说完的补完。',
  ];
  lines
    ..add(
      '- 想挂电话的时候（说完晚安、对方要去忙），先把告别的话说完，再在最后单独写 $callHangupMarker。'
      '挂断前线会多留一小会儿，对方要是又开口，就接着聊。别动不动就挂。',
    )
    ..add(
      '- 对方说要出门、要睡了、让你别打电话之类，写 $callDndOnMarker；对方说可以打了，写 $callDndOffMarker。'
      '写了以后用一句话跟对方确认。这些标记不会被念出来。',
    )
    ..add('- 对方那句话前面要是有〔小声〕，说明对方在压低声音说话，你也放轻声音、说短一点。')
    ..add('- 电话里不要调用工具，不要发图片、卡片，只说话。');
  final tags = _promptTags[audioTags];
  if (tags != null) {
    final what = audioTags == CallTagDialect.miniMax
        ? '想笑、叹气、呼吸重了、喘、吸鼻子时，可以在句子里放声音标签，会被念成真的笑声、叹气、呼吸声'
        : '想笑、叹气、压低声音时，可以在句子里放声音标签，会被念成真的笑声、叹气';
    lines.add(
      '- $what：${tags.map((t) => '[$t]').join(' ')}。'
      '用半角英文方括号，放在声音该出现的位置；一段最多一两个，只在情绪真的变了的地方放，别每句都放。',
    );
  }
  return lines.join('\n');
}

/// Hidden cue when the companion should speak first after pickup.
String callOpeningCue({String? reason}) {
  final why = (reason ?? '').trim();
  if (why.isNotEmpty) {
    return '$proactiveCueOpening\n电话是你主动打给对方的，对方刚接起来。'
        '你打这通电话是因为：$why\n'
        '像平时打电话那样自然地开口，第一句别解释规则，也别提这条提示。';
  }
  return '$proactiveCueOpening\n电话刚接通，你先开口。'
      '像平时接起这个人的电话那样，自然地说第一句，一两句就好，别提这条提示。';
}

/// Hidden cue after a long silence on the line.
const callSilenceCue =
    '$proactiveCueOpening\n电话里安静了好一会儿，对方一直没说话。'
    '像真打电话那样自然地接一句：随口说说你在干嘛、把刚才的话题往下接一点、'
    '或者问问对方是不是在忙。一两句就好，别重复上一句，别提这条提示。';

/// Marker a self-wake may answer with to call instead of texting.
const companionCallMarker = '[来电]';

final RegExp _callMarkerPattern = RegExp(r'^\s*[\[【](来电|打电话|call)[\]】]');

/// The reason after the marker, or null when the reply is not a call.
String? companionCallReason(String visibleContent) {
  final match = _callMarkerPattern.firstMatch(visibleContent);
  if (match == null) return null;
  return visibleContent.substring(match.end).trim();
}

/// Extra lines for a self-wake when calling is allowed.
const companionCallWakeHint =
    '如果此刻比起发消息，你更想直接打电话给对方（想听听对方的声音、有事想当面说、'
    '对方那边情况让你放心不下），就只回复 $companionCallMarker 加一句你为什么想打，'
    '这句话对方看不到，只会决定你接通后怎么开口。别太常打，大多数时候发消息就好。';

/// The companion ends the call after its last sentence.
const callHangupMarker = '⟪挂断⟫';
const callDndOnMarker = '⟪勿扰开⟫';
const callDndOffMarker = '⟪勿扰关⟫';

enum CallMarker { hangup, dndOn, dndOff }

final RegExp _markerPattern = RegExp(
  r'[⟪《【\[]\s*(挂断|hangup|勿扰开|dnd:on|勿扰关|dnd:off)\s*[⟫》】\]]',
  caseSensitive: false,
);

/// Markers found in [text], and the text without them.
(String, Set<CallMarker>) takeCallMarkers(String text) {
  final found = <CallMarker>{};
  final rest = text.replaceAllMapped(_markerPattern, (m) {
    final word = m.group(1)!.toLowerCase();
    found.add(switch (word) {
      '挂断' || 'hangup' => CallMarker.hangup,
      '勿扰开' || 'dnd:on' => CallMarker.dndOn,
      _ => CallMarker.dndOff,
    });
    return '';
  });
  return (rest, found);
}

/// Prefix on the user's line when she spoke softly.
const callSoftPrefix = '〔小声〕';

/// A cough, an "嗯" or a sound with no words: it does not take over a reply
/// that is already on its way.
bool isSlightUtterance(String text) {
  final stripped = text
      .replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '')
      .replaceAll(RegExp('[嗯啊哦噢呃额唔嗯哼咳哈]'), '');
  return stripped.characters.length < 2;
}

/// Hidden cue after a call the companion placed rang out.
String callMissedCue({required String reason}) {
  final why = reason.trim();
  return '$proactiveCueOpening\n你刚才给对方打了电话'
      '${why.isEmpty ? '' : '（因为：$why）'}，响了一阵没人接，聊天里已经有一张「未接来电」。'
      '你可以给对方留一两句话，像对着语音信箱说话那样；也可以什么都不留，只回复 [静默]。'
      '这一轮别做别的。';
}

/// Hidden cue after the user declined a call from the companion.
String callDeclinedCue({required String reason, required String note}) {
  final why = reason.trim();
  final said = note.trim();
  return '$proactiveCueOpening\n你刚才给对方打电话'
      '${why.isEmpty ? '' : '（因为：$why）'}，对方挂掉了'
      '${said.isEmpty ? '，没说为什么' : '，对方说：「$said」'}。'
      '顺着这个情况回一两条消息，别追着打回去。';
}

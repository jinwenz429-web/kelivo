import 'package:Kelivo/features/call/call_records.dart';
import 'package:Kelivo/features/call/call_session.dart';
import 'package:Kelivo/features/call/call_settings.dart';
import 'package:Kelivo/features/call/call_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CallSentenceSplitter', () {
    test('emits sentences as they complete and keeps punctuation runs', () {
      final splitter = CallSentenceSplitter();
      expect(splitter.add('喂？你'), ['喂？']);
      expect(splitter.add('在干嘛呢……'), ['你在干嘛呢……']);
      expect(splitter.add('我刚'), isEmpty);
      expect(splitter.flush(), '我刚');
    });

    test('lone punctuation joins the next sentence', () {
      final splitter = CallSentenceSplitter();
      expect(splitter.add('……'), isEmpty);
      expect(splitter.add('好吧。'), ['……好吧。']);
    });

    test('a long clause is cut at a comma', () {
      final splitter = CallSentenceSplitter(softLimit: 10);
      final out = splitter.add('今天在图书馆坐了一下午真的好累，然后');
      expect(out, ['今天在图书馆坐了一下午真的好累，']);
    });
  });

  group('speech and display text', () {
    test('actions are dropped from speech but kept on screen', () {
      const raw = '*揉了揉你的头* 乖（笑）[laughs] 早点睡。';
      expect(callSpeechText(raw, keepAudioTags: true), '乖 [laughs] 早点睡。');
      expect(callSpeechText(raw, keepAudioTags: false), '乖 早点睡。');
      expect(callDisplayText(raw), '揉了揉你的头 乖（笑）早点睡。');
    });

    test('an English aside in parentheses is still read', () {
      expect(
        callSpeechText('就是那首 (Leave the Door Open) 嘛', keepAudioTags: false),
        '就是那首 (Leave the Door Open) 嘛',
      );
    });

    test('tags alone have no words', () {
      expect(callHasWords('[sighs] ……'), isFalse);
      expect(callHasWords('[sighs] 嗯好'), isTrue);
    });
  });

  test('markers are taken out of the reply', () {
    final (text, markers) = takeCallMarkers('那你早点睡，晚安。⟪挂断⟫');
    expect(text, '那你早点睡，晚安。');
    expect(markers, {CallMarker.hangup});
    final (_, dnd) = takeCallMarkers('好，【勿扰开】不吵你了');
    expect(dnd, {CallMarker.dndOn});
  });

  test('a cough or an "嗯" is a slight utterance', () {
    expect(isSlightUtterance('嗯。'), isTrue);
    expect(isSlightUtterance('咳咳'), isTrue);
    expect(isSlightUtterance('等一下'), isFalse);
  });

  test('call marker from a self-wake carries the reason', () {
    expect(companionCallReason('[来电] 想听听你的声音'), '想听听你的声音');
    expect(companionCallReason('【打电话】'), '');
    expect(companionCallReason('来电了吗'), isNull);
  });

  group('CallSettings', () {
    test('round-trips and clamps', () {
      final s = CallSettings.fromJson({
        'silenceNudge': true,
        'silenceNudgeSeconds': 3,
        'voiceModel': 'v3',
        'sensitivity': 'high',
        'companionMayCall': true,
      });
      expect(s.silenceNudgeSeconds, 10);
      expect(s.voiceModel, CallVoiceModel.v3);
      final again = CallSettings.fromJson(s.toJson());
      expect(again.sensitivity, CallSensitivity.high);
      expect(again.companionMayCall, isTrue);
    });

    test('calls are limited to daytime, once a day, and respect DND', () {
      final base = const CallSettings(companionMayCall: true);
      final noon = DateTime(2026, 11, 20, 12);
      expect(base.mayCallAt(noon), isTrue);
      expect(base.mayCallAt(DateTime(2026, 11, 20, 23, 30)), isFalse);
      expect(base.copyWith(doNotDisturb: true).mayCallAt(noon), isFalse);
      final called = base.copyWith(
        lastCompanionCallAt: DateTime(2026, 11, 20, 10),
      );
      expect(called.mayCallAt(noon), isFalse);
      expect(called.mayCallAt(DateTime(2026, 11, 21, 12)), isTrue);
    });
  });

  test('soft voice needs a baseline first', () {
    final baseline = CallVoiceBaseline();
    for (var i = 0; i < 5; i++) {
      expect(baseline.isSoft(0.1), isFalse);
      baseline.add(0.4);
    }
    expect(baseline.isSoft(0.1), isTrue);
    expect(baseline.isSoft(0.35), isFalse);
  });

  test('call lines keep their flags through JSON', () {
    final line = CallLine(
      role: 'assistant',
      text: '晚安',
      at: DateTime(2026, 11, 20),
      audio: ['line_0.mp3'],
      favorite: true,
      interrupted: true,
    );
    final back = CallLine.fromJson(line.toJson());
    expect(back.audio, ['line_0.mp3']);
    expect(back.favorite, isTrue);
    expect(back.interrupted, isTrue);
  });
}

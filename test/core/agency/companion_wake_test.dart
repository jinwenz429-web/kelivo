import 'package:flutter_test/flutter_test.dart';

import 'package:Kelivo/core/agency/companion_wake.dart';
import 'package:Kelivo/core/models/scheduled_task.dart';

void main() {
  group('isCompanionSilence', () {
    test('accepts the marker, with or without a trailing note', () {
      expect(isCompanionSilence('[静默]'), isTrue);
      expect(isCompanionSilence('  【静默】'), isTrue);
      expect(isCompanionSilence('[静默] 她应该在睡觉'), isTrue);
      expect(isCompanionSilence('[Silent]'), isTrue);
    });

    test('a real message that mentions the word is not silence', () {
      expect(isCompanionSilence('今天好安静，[静默] 了一整天'), isFalse);
      expect(isCompanionSilence('醒了吗'), isFalse);
      expect(isCompanionSilence(''), isFalse);
    });
  });

  group('companionWakeInstruction', () {
    final now = DateTime(2026, 11, 17, 21, 5);

    test('carries time, gaps, the note and the silence rule', () {
      final text = companionWakeInstruction(
        now: now,
        note: '看看我吃饭没有',
        lastMessageAt: now.subtract(const Duration(hours: 2, minutes: 30)),
        lastUserMessageAt: now.subtract(const Duration(days: 1, hours: 1)),
      );
      expect(text, contains('2026年11月17日 星期二 21:05'));
      expect(text, contains('2 小时 30 分钟'));
      expect(text, contains('对方上一次说话是 1 天前'));
      expect(text, contains('看看我吃饭没有'));
      expect(text, contains(companionSilenceMarker));
    });

    test('falls back to the default note and skips unknown gaps', () {
      final text = companionWakeInstruction(now: now, note: '  ');
      expect(text, contains(companionWakeDefaultNote));
      expect(text, isNot(contains('距离')));
    });
  });

  group('ScheduledTask.companionWake', () {
    ScheduledTask task({
      required ScheduledTaskMode mode,
      bool wake = true,
      bool prepare = true,
    }) => ScheduledTask(
      id: 't',
      name: 'wake',
      prompt: 'note',
      assistantId: 'a',
      hour: 9,
      minute: 0,
      mode: mode,
      conversationId: 'c',
      companionWake: wake,
      allowPreparation: prepare,
    );

    test('round-trips through JSON', () {
      final restored = ScheduledTask.fromJson(
        task(mode: ScheduledTaskMode.followUp).toJson(),
      );
      expect(restored.companionWake, isTrue);
      expect(restored.isCompanionWake, isTrue);
      expect(
        ScheduledTask.fromJson(
          {...task(mode: ScheduledTaskMode.followUp).toJson()}
            ..remove('companionWake'),
        ).companionWake,
        isFalse,
      );
    });

    test('only applies to follow-ups and never prepares ahead', () {
      expect(task(mode: ScheduledTaskMode.newChat).isCompanionWake, isFalse);
      expect(task(mode: ScheduledTaskMode.followUp).canPrepare, isFalse);
      expect(
        task(mode: ScheduledTaskMode.followUp, wake: false).canPrepare,
        isTrue,
      );
    });
  });
}

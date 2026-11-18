import 'dart:math' as math;

import '../../../core/agency/agency_settings.dart';
import '../../../core/agency/agency_wake_check.dart';
import '../../../core/models/assistant.dart';
import '../../../core/models/scheduled_task.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/logging/flutter_logger.dart';
import '../../../core/services/scheduled_tasks_service.dart';

/// Keeps the hidden agency self-wake task pointed at the latest conversation
/// with a Companion Agency assistant, at a fresh random time after each run.
///
/// Built on the scheduled-task alarm path, so it fires with the app closed.
/// If a reschedule is ever lost, the task still repeats daily at its last
/// time, so self-wake degrades to "less random" rather than stopping.
class AgencyWakeScheduler {
  const AgencyWakeScheduler._();

  static Future<void> sync({
    required ScheduledTasksService service,
    required ChatService chat,
    required List<Assistant> assistants,
    bool reroll = false,
    math.Random? random,
  }) async {
    if (!ScheduledTasksService.supported || !service.loaded) return;
    final settings = AgencySettingsStore.instance.value;
    final existing = service.tasks.where((t) => t.isAgencyWake).firstOrNull;
    final agencyAssistants = {
      for (final a in assistants)
        if (a.companionAgencyEnabled) a.id,
    };
    final target = settings.wantsBackgroundWake && agencyAssistants.isNotEmpty
        ? chat
              .getAllConversations()
              .where(
                (c) =>
                    agencyAssistants.contains(c.assistantId) &&
                    !chat.isTemporaryConversation(c.id),
              )
              .firstOrNull
        : null;

    try {
      if (target == null) {
        if (existing != null) await service.delete(existing.id);
        return;
      }
      final model = settings.modelOverride;
      final unchanged =
          existing != null &&
          existing.enabled &&
          existing.conversationId == target.id &&
          existing.assistantId == target.assistantId &&
          existing.modelProvider == model?.providerKey &&
          existing.modelId == model?.modelId;
      if (unchanged && !reroll) return;

      final next = nextAgencyWake(
        now: DateTime.now(),
        settings: settings,
        random: random ?? math.Random(),
      );
      await service.save(
        ScheduledTask(
          id: agencyWakeTaskId,
          name: 'Companion Agency 自己醒来',
          // The real instruction is planned at wake time; the store just
          // requires a non-empty prompt.
          prompt: 'agency',
          assistantId: target.assistantId!,
          hour: next.hour,
          minute: next.minute,
          mode: ScheduledTaskMode.followUp,
          conversationId: target.id,
          modelProvider: model?.providerKey,
          modelId: model?.modelId,
          companionWake: true,
          notify: true,
          showPreview: true,
        ),
        enabled: true,
      );
      FlutterLogger.log(
        'next self-wake ${next.hour}:${next.minute.toString().padLeft(2, '0')}',
        tag: 'AgencyWake',
      );
    } catch (error) {
      FlutterLogger.log(
        'self-wake scheduling failed: $error',
        tag: 'AgencyWake',
      );
    }
  }
}

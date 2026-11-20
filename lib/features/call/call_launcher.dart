import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/business_preferences.dart';
import '../../core/models/assistant.dart';
import '../../core/providers/assistant_provider.dart';
import '../../core/providers/mcp_provider.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/user_provider.dart';
import '../../core/services/chat/chat_service.dart';
import '../../shared/widgets/snackbar.dart';
import '../home/services/local_tools_service.dart' show DeviceLocalTools;
import '../home/utils/model_display_helper.dart' show resolveChatModel;
import 'call_records.dart';
import 'call_session.dart';
import 'call_settings.dart';
import 'call_text.dart';
import 'call_voice.dart';
import 'pages/call_page.dart';

const _callChannel = MethodChannel('kelivo/call');

/// Keeps the call running with the screen locked (Android).
Future<void> setCallServiceRunning(bool running, {String title = ''}) async {
  if (!io.Platform.isAndroid) return;
  try {
    await _callChannel.invokeMethod<void>(running ? 'start' : 'stop', {
      'title': title,
    });
  } catch (_) {}
}

/// Everything a call needs, resolved from the conversation's assistant.
class CallSetup {
  const CallSetup({
    required this.conversationId,
    required this.assistant,
    required this.userName,
    required this.provider,
    required this.modelId,
  });

  final String conversationId;
  final Assistant assistant;
  final String userName;
  final ProviderConfig provider;
  final String modelId;
}

CallSetup? resolveCallSetup(BuildContext context, String conversationId) {
  final chat = context.read<ChatService>();
  final assistants = context.read<AssistantProvider>();
  final settings = context.read<SettingsProvider>();
  final conversation = chat.getConversation(conversationId);
  final assistant = assistants.resolveConversationAssistant(
    conversation?.assistantId,
  );
  if (assistant == null) return null;
  // The same chain the chat itself uses: conversation pin, assistant, global.
  final model = resolveChatModel(
    settings,
    conversation: conversation,
    assistant: assistant,
  );
  final providerKey = model.providerKey;
  final modelId = model.modelId;
  if (providerKey == null || modelId == null) return null;
  return CallSetup(
    conversationId: conversationId,
    assistant: assistant,
    userName: context.read<UserProvider>().name,
    provider: settings.getProviderConfig(providerKey),
    modelId: modelId,
  );
}

/// The Pawwake `search_memory` tool bound to the assistant, if it has one.
CallMemoryTool? findCallMemoryTool(McpProvider mcpProvider, Assistant a) {
  for (final serverId in a.mcpServerIds) {
    for (final tool in mcpProvider.getEnabledToolsForServers({serverId})) {
      if (!tool.name.endsWith('search_memory')) continue;
      return CallMemoryTool(
        definition: {
          'type': 'function',
          'function': {
            'name': 'search_memory',
            'description': tool.description ?? '搜索你们之间的记忆（事情、约定、日期、对方的喜好）。',
            'parameters':
                tool.schema ??
                {
                  'type': 'object',
                  'properties': {
                    'query': {'type': 'string'},
                  },
                  'required': ['query'],
                },
          },
        },
        call: (args) async {
          final result = await mcpProvider.callTool(serverId, tool.name, args);
          final text = (result?.content ?? const [])
              .whereType<mcp.TextContent>()
              .map((c) => c.text)
              .join('\n');
          return text.trim().isEmpty ? '没有查到相关的记忆。' : text;
        },
      );
    }
  }
  return null;
}

Future<bool> _headphonesConnected() async {
  try {
    final raw = jsonDecode(
      await DeviceLocalTools.invokeJsonTool('deviceSnapshot', const {}),
    );
    return raw is Map && raw['headphones'] == true;
  } catch (_) {
    return false;
  }
}

/// Opens a call with the conversation's assistant. [reason] is set when the
/// companion placed the call.
Future<void> startCall(
  BuildContext context, {
  required String conversationId,
  String? reason,
  CallDirection direction = CallDirection.outgoing,
}) async {
  final setup = resolveCallSetup(context, conversationId);
  final settingsProvider = context.read<SettingsProvider>();
  final tts = settingsProvider.selectedTtsService;
  final asr = settingsProvider.selectedAsrService;
  void fail(String message) =>
      showAppSnackBar(context, message: message, type: NotificationType.error);
  if (setup == null) return fail('这个对话还没有选好助手和模型，打不了电话。');
  if (tts == null || !tts.enabled) {
    return fail('先在「设置 → 语音服务」里选一个朗读服务，他才有声音。');
  }
  if (asr == null || !asr.isConfigured) {
    return fail('先在「设置 → 语音服务」里选一个语音识别，他才听得见你。');
  }
  // Ask for the microphone before the call service starts: Android refuses a
  // microphone foreground service without it.
  final recorder = AudioRecorder();
  final micAllowed = await recorder.hasPermission();
  await recorder.dispose();
  if (!context.mounted) return;
  if (!micAllowed) return fail('没有麦克风权限，他听不见你。去系统设置里给 Kelivo 开一下。');
  final mcpProvider = context.read<McpProvider>();
  final prefs = context.read<BusinessPreferences>();
  final callSettings = CallSettingsStore.instance.value;
  final memoryTool = findCallMemoryTool(mcpProvider, setup.assistant);
  final speakerMode = !await _headphonesConnected();
  final baseline = await CallVoiceBaselineStore.load(prefs);
  if (!context.mounted) return;

  final record = CallRecord(
    id: const Uuid().v4(),
    conversationId: conversationId,
    assistantId: setup.assistant.id,
    assistantName: setup.assistant.name,
    userName: setup.userName,
    startedAt: DateTime.now(),
    direction: direction,
    reason: reason ?? '',
  );
  final basePrompt = setup.assistant.systemPrompt.trim();
  final session = CallSession(
    record: record,
    settings: callSettings,
    provider: setup.provider,
    modelId: setup.modelId,
    systemPrompt: [
      if (basePrompt.isNotEmpty) basePrompt,
      callSystemInstructions(
        audioTags: CallVoice.readsAudioTags(
          CallVoice.withCallModel(tts, callSettings.voiceModel),
        ),
        userName: setup.userName,
      ),
    ].join('\n\n'),
    ttsService: tts,
    asrOptions: asr,
    baseline: baseline,
    speakerMode: speakerMode,
    memoryTool: memoryTool,
    openingReason: reason,
    onDndChanged: (on) => CallSettingsStore.instance.update(
      CallSettingsStore.instance.value.copyWith(doNotDisturb: on),
    ),
  );
  await setCallServiceRunning(true, title: '正在和${setup.assistant.name}通话');
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => CallPage(session: session, assistant: setup.assistant),
    ),
  );
  await setCallServiceRunning(false);
  await CallVoiceBaselineStore.save(prefs, session.baseline);
  if (!context.mounted) return;
  await finishCall(context, record, setup.provider);
}

/// Saves the call, hands the transcript to the gateway and copies the stored
/// round into the conversation so later chats see it.
Future<void> finishCall(
  BuildContext context,
  CallRecord record,
  ProviderConfig provider,
) async {
  final chat = context.read<ChatService>();
  record.endedAt ??= DateTime.now();
  record.lines.removeWhere((l) => l.text.trim().isEmpty);
  final store = CallRecordStore.instance;
  await store.save(record);
  if (record.lines.isEmpty || record.duration.inSeconds < 5) return;
  try {
    final stored = await CallRecordStore.upload(
      record: record,
      baseUrl: provider.baseUrl,
      apiKey: provider.apiKey,
    );
    record.uploaded = stored != null;
    final round = stored ?? localCallRound(record);
    if (!record.insertedIntoChat) {
      await chat.addMessage(
        conversationId: record.conversationId,
        role: 'user',
        content: round.userContent,
      );
      await chat.addMessage(
        conversationId: record.conversationId,
        role: 'assistant',
        content: round.assistantContent,
      );
      record.insertedIntoChat = true;
    }
  } catch (error) {
    if (context.mounted) {
      showAppSnackBar(
        context,
        message: '通话记录没传上去，可以在通话记录里重试：$error',
        type: NotificationType.warning,
      );
    }
  }
  await store.save(record);
}

/// The same round format a Pawwake gateway stores, for other gateways.
StoredCallRound localCallRound(CallRecord record) {
  String two(int v) => v.toString().padLeft(2, '0');
  final s = record.startedAt;
  final e = record.endedAt ?? DateTime.now();
  final minutes = (record.duration.inSeconds / 60).round().clamp(1, 1 << 20);
  final header =
      '[语音通话 ${s.year}-${two(s.month)}-${two(s.day)} '
      '${two(s.hour)}:${two(s.minute)}–${two(e.hour)}:${two(e.minute)}，$minutes 分钟]';
  final body = record.lines
      .map(
        (l) => '${l.isUser ? record.userName : record.assistantName}：${l.text}',
      )
      .join('\n');
  return StoredCallRound('$header\n$body', '（电话挂断了）');
}

/// How loudly the user usually talks, kept across calls.
class CallVoiceBaselineStore {
  static const _key = 'call_voice_baseline_v1';

  static Future<CallVoiceBaseline> load(BusinessPreferences prefs) async {
    await prefs.load();
    final raw = prefs.getString(_key);
    if (raw == null) return CallVoiceBaseline();
    try {
      final json = jsonDecode(raw) as Map;
      return CallVoiceBaseline(
        mean: (json['mean'] as num?)?.toDouble() ?? 0,
        samples: (json['samples'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return CallVoiceBaseline();
    }
  }

  static Future<void> save(
    BusinessPreferences prefs,
    CallVoiceBaseline baseline,
  ) => prefs.setString(
    _key,
    jsonEncode({'mean': baseline.mean, 'samples': baseline.samples}),
  );
}

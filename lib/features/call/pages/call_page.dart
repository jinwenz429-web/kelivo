import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/models/assistant.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/custom_bottom_sheet.dart';
import '../../../shared/widgets/ios_settings_rows.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/segmented_tabs.dart';
import '../../home/widgets/assistant_avatar.dart';
import '../call_records.dart';
import '../call_session.dart';
import '../call_settings.dart';

/// The in-call screen: who is talking, live subtitles, and the controls.
class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.session, required this.assistant});

  final CallSession session;
  final Assistant assistant;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  CallSession get session => widget.session;
  final ScrollController _scroll = ScrollController();
  final TextEditingController _typing = TextEditingController();
  Timer? _clock;
  bool _ending = false;

  @override
  void initState() {
    super.initState();
    session.addListener(_onSession);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    unawaited(
      session.start().catchError((Object error) {
        if (mounted) _end();
      }),
    );
  }

  void _onSession() {
    if (!mounted) return;
    if (session.phase == CallPhase.ended) {
      _leave();
      return;
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Hangs up and leaves at once; the audio devices are released after.
  void _end() {
    unawaited(session.hangUp());
    _leave();
  }

  void _leave() {
    if (_ending || !mounted) return;
    _ending = true;
    FocusScope.of(context).unfocus();
    // pop() rather than maybePop(): the PopScope below only guards the
    // system back gesture.
    Navigator.of(context).pop();
  }

  void _sendTyped() {
    final text = _typing.text;
    if (text.trim().isEmpty) return;
    session.sendText(text);
    _typing.clear();
  }

  @override
  void dispose() {
    _clock?.cancel();
    session.removeListener(_onSession);
    unawaited(session.hangUp());
    _scroll.dispose();
    _typing.dispose();
    super.dispose();
  }

  String _status() {
    if (session.notice != null) return session.notice!;
    return switch (session.phase) {
      CallPhase.connecting => '正在接通…',
      CallPhase.listening =>
        session.userSpeaking ? '在听你说…' : (session.muted ? '你静音了' : '在听'),
      CallPhase.thinking => '他在想怎么回…',
      CallPhase.speaking => '他在说话',
      CallPhase.lingering => '他要挂了…再说一句就接着聊',
      CallPhase.ended => '通话结束',
    };
  }

  String _duration() {
    final d = session.record.duration;
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final speaking = session.phase == CallPhase.speaking;
    final level = session.userSpeaking ? session.micLevel : 0.0;
    return PopScope(
      canPop: _ending,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _end();
      },
      child: Scaffold(
        backgroundColor: Color.alphaBlend(
          cs.primary.withValues(alpha: 0.10),
          const Color(0xFF15161A),
        ),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 28),
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: EdgeInsets.all(6 + (speaking ? 6 : level * 14)),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (speaking ? cs.primary : Colors.white).withValues(
                    alpha: speaking ? 0.22 : 0.10 + level * 0.3,
                  ),
                ),
                child: AssistantAvatar(assistant: widget.assistant, size: 96),
              ),
              const SizedBox(height: 14),
              Text(
                widget.assistant.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${_duration()} · ${_status()}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 13,
                ),
              ),
              if (session.error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                  child: GestureDetector(
                    onTap: session.clearError,
                    child: Text(
                      session.error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: cs.error, fontSize: 12),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Expanded(child: _subtitles()),
              _typeBox(),
              _controls(cs),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subtitles() {
    final lines = session.lines.where((l) => l.text.trim().isNotEmpty).toList();
    return ShaderMask(
      shaderCallback: (rect) => const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Colors.transparent, Colors.white, Colors.white],
        stops: [0, 0.18, 1],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(24, 40, 24, 16),
        itemCount: lines.length,
        itemBuilder: (context, index) => _line(lines[index]),
      ),
    );
  }

  Widget _typeBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 4),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _typing,
                minLines: 1,
                maxLines: 3,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _sendTyped(),
                style: const TextStyle(color: Colors.white, fontSize: 15),
                cursorColor: Colors.white,
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '不方便说话就打字…',
                  hintStyle: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
            IosIconButton(
              icon: Lucide.ArrowUp,
              size: 20,
              minSize: 40,
              color: Colors.white,
              semanticLabel: '发送',
              onTap: _sendTyped,
            ),
          ],
        ),
      ),
    );
  }

  Widget _line(CallLine line) {
    final mine = line.isUser;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Align(
        alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 300),
          child: Text(
            line.interrupted ? '${line.text}—' : line.text,
            textAlign: mine ? TextAlign.right : TextAlign.left,
            style: TextStyle(
              color: Colors.white.withValues(alpha: mine ? 0.62 : 0.95),
              fontSize: mine ? 15 : 17,
              height: 1.45,
              fontStyle: line.soft ? FontStyle.italic : FontStyle.normal,
            ),
          ),
        ),
      ),
    );
  }

  Widget _controls(ColorScheme cs) {
    Widget round(
      IconData icon,
      String label,
      VoidCallback onTap, {
      bool active = false,
      Color? color,
    }) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color:
                  color ??
                  (active
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.14)),
            ),
            child: IosIconButton(
              icon: icon,
              size: 24,
              minSize: 60,
              color: color != null
                  ? Colors.white
                  : (active ? Colors.black : Colors.white),
              semanticLabel: label,
              onTap: onTap,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 12,
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              round(
                session.muted ? Lucide.MicOff : Lucide.Mic,
                session.muted ? '已静音' : '静音',
                session.toggleMute,
                active: session.muted,
              ),
              round(
                session.speakerMode ? Lucide.Volume2 : Lucide.Headphones,
                session.speakerMode ? '外放' : '耳机',
                () => unawaited(session.setSpeakerMode(!session.speakerMode)),
              ),
              round(Lucide.Hand, '让他停', session.cutIn),
              round(Lucide.Settings2, '设置', _openSettings),
            ],
          ),
          const SizedBox(height: 22),
          round(Lucide.PhoneOff, '挂断', _end, color: const Color(0xFFE5484D)),
        ],
      ),
    );
  }

  void _openSettings() {
    showCustomBottomSheet<void>(
      context: context,
      title: '通话设置',
      builder: (context, scroll) => CallSettingsPanel(scrollController: scroll),
    );
  }
}

/// Call preferences; also reachable from the assistant's agency settings.
class CallSettingsPanel extends StatelessWidget {
  const CallSettingsPanel({super.key, this.scrollController});

  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CallSettingsStore.instance,
      builder: (context, _) {
        final store = CallSettingsStore.instance;
        final s = store.value;
        void set(CallSettings next) => unawaited(store.update(next));
        final cs = Theme.of(context).colorScheme;
        Widget caption(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        );
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          children: [
            SectionCard(
              dividers: true,
              children: [
                IosSwitchRow(
                  label: '接通后他先开口',
                  subtitle: '关掉就是你先说',
                  value: s.companionSpeaksFirst,
                  onChanged: (v) => set(s.copyWith(companionSpeaksFirst: v)),
                ),
                IosSwitchRow(
                  label: '安静久了他接话',
                  subtitle: '${s.silenceNudgeSeconds} 秒没人说话时，他自然地接一句，最多连着两次',
                  value: s.silenceNudge,
                  onChanged: (v) => set(s.copyWith(silenceNudge: v)),
                ),
                IosSwitchRow(
                  label: '通话时少思考',
                  subtitle: '思考调低，开口更快',
                  value: s.lowReasoning,
                  onChanged: (v) => set(s.copyWith(lowReasoning: v)),
                ),
              ],
            ),
            caption('他的嗓子（只对 ElevenLabs 生效）'),
            SegmentedTabs(
              tabs: const [
                SegmentedTab(label: '跟随朗读设置'),
                SegmentedTab(label: 'v3 有表情'),
                SegmentedTab(label: 'Flash 快'),
              ],
              index: s.voiceModel.index,
              onChanged: (i) =>
                  set(s.copyWith(voiceModel: CallVoiceModel.values[i])),
            ),
            caption(
              'v3 会笑、叹气、压低声音，开口慢一点；Flash 接话快，情绪平一些。下一通电话生效。'
              '朗读用 MiniMax 时这里不管用：模型选 speech-2.8（hd 或 turbo）就会有笑声、叹气、呼吸和喘息。',
            ),
            caption('听你说话的灵敏度'),
            SegmentedTabs(
              tabs: const [
                SegmentedTab(label: '低'),
                SegmentedTab(label: '中'),
                SegmentedTab(label: '高'),
              ],
              index: s.sensitivity.index,
              onChanged: (i) =>
                  set(s.copyWith(sensitivity: CallSensitivity.values[i])),
            ),
            caption('环境吵、或者他老被自己的声音打断，就调低；你说话他常听不见，就调高。外放时戴耳机最稳。'),
            SectionCard(
              dividers: true,
              children: [
                IosSwitchRow(
                  label: '允许他主动打给你',
                  subtitle: '他醒来时可以选择直接打电话，一天最多一次，10 点到 23 点',
                  value: s.companionMayCall,
                  onChanged: (v) => set(s.copyWith(companionMayCall: v)),
                ),
                IosSwitchRow(
                  label: '勿扰',
                  subtitle: '开着时他不会打来。通话里跟他说「开勿扰」「可以打了」也行',
                  value: s.doNotDisturb,
                  onChanged: (v) => set(s.copyWith(doNotDisturb: v)),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

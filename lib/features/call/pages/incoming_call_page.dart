import 'package:flutter/material.dart';

import '../../../core/models/assistant.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../home/widgets/assistant_avatar.dart';
import '../incoming_call.dart';

/// What the user chose on the incoming-call screen.
sealed class IncomingCallChoice {
  const IncomingCallChoice();
}

class AnswerCall extends IncomingCallChoice {
  const AnswerCall();
}

class DeclineCall extends IncomingCallChoice {
  const DeclineCall(this.note);
  final String note;
}

/// Full-screen ringing card: who is calling and why.
class IncomingCallPage extends StatefulWidget {
  const IncomingCallPage({
    super.key,
    required this.call,
    required this.assistant,
  });

  final IncomingCall call;
  final Assistant? assistant;

  @override
  State<IncomingCallPage> createState() => _IncomingCallPageState();
}

class _IncomingCallPageState extends State<IncomingCallPage> {
  final TextEditingController _note = TextEditingController();
  bool _choosingReason = false;

  @override
  void initState() {
    super.initState();
    IncomingCallService.instance.addListener(_onService);
  }

  @override
  void dispose() {
    IncomingCallService.instance.removeListener(_onService);
    _note.dispose();
    super.dispose();
  }

  void _onService() {
    // Rang out, or was answered/declined from the notification.
    if (IncomingCallService.instance.pending?.id != widget.call.id && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  void _choose(IncomingCallChoice choice) => Navigator.of(context).pop(choice);

  @override
  Widget build(BuildContext context) {
    final why = widget.call.reason.trim();
    return Scaffold(
      backgroundColor: const Color(0xFF15161A),
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 64),
            AssistantAvatar(assistant: widget.assistant, size: 104),
            const SizedBox(height: 18),
            Text(
              widget.call.assistantName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '来电',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
            ),
            if (why.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(36, 22, 36, 0),
                child: Text(
                  why,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
              ),
            const Spacer(),
            if (_choosingReason) _reasons() else _buttons(),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _buttons() {
    Widget button(IconData icon, String label, Color color, VoidCallback tap) {
      return Column(
        children: [
          Container(
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            child: IosIconButton(
              icon: icon,
              size: 28,
              minSize: 72,
              color: Colors.white,
              semanticLabel: label,
              onTap: tap,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.7)),
          ),
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        button(
          Lucide.PhoneOff,
          '拒接',
          const Color(0xFFE5484D),
          () => setState(() => _choosingReason = true),
        ),
        button(
          Lucide.Phone,
          '接听',
          const Color(0xFF30A46C),
          () => _choose(const AnswerCall()),
        ),
      ],
    );
  }

  Widget _reasons() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              for (final reason in callDeclineReasons)
                ActionChip(
                  label: Text(reason),
                  onPressed: () => _choose(DeclineCall(reason)),
                ),
              ActionChip(
                label: const Text('不说为什么'),
                onPressed: () => _choose(const DeclineCall('')),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _note,
            maxLength: 60,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '或者自己写一句…',
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
              counterText: '',
              suffixIcon: IosIconButton(
                icon: Lucide.ArrowUp,
                color: Colors.white,
                semanticLabel: '发送',
                onTap: () => _choose(DeclineCall(_note.text.trim())),
              ),
            ),
            onSubmitted: (text) => _choose(DeclineCall(text.trim())),
          ),
        ],
      ),
    );
  }
}

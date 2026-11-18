import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/agency/agency_settings.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_settings_rows.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/section_card.dart';
import '../../../shared/widgets/segmented_tabs.dart';
import '../../home/services/local_tools_service.dart';
import '../../model/widgets/model_select_sheet.dart';

/// Fine-grained Companion Agency settings: its model, a note it always sees,
/// and every occasion that may wake it, each with an on/off switch and how
/// eager it is. Text is Chinese only, like the rest of this fork's agency UI.
class CompanionAgencySettingsPage extends StatefulWidget {
  const CompanionAgencySettingsPage({super.key});

  @override
  State<CompanionAgencySettingsPage> createState() =>
      _CompanionAgencySettingsPageState();
}

typedef _TriggerInfo = ({
  AgencyTrigger trigger,
  IconData icon,
  String label,
  String subtitle,
});

const _feelings = <_TriggerInfo>[
  (
    trigger: AgencyTrigger.longing,
    icon: Lucide.Heart,
    label: '越久没说话越想来',
    subtitle: '自己醒来时，你们沉默得越久，它越可能来找你',
  ),
  (
    trigger: AgencyTrigger.followUp,
    icon: Lucide.ListChecks,
    label: '接着没说完的事',
    subtitle: '你提过的考试、看病、出门，过了时间来问问怎么样',
  ),
];

const _moments = <_TriggerInfo>[
  (
    trigger: AgencyTrigger.newPlace,
    icon: Lucide.MapPin,
    label: '你换了地方',
    subtitle: '离它上次知道的位置超过 1 公里',
  ),
  (
    trigger: AgencyTrigger.headphones,
    icon: Lucide.Sparkles,
    label: '你戴上了耳机',
    subtitle: '蓝牙或有线耳机刚连上',
  ),
  (
    trigger: AgencyTrigger.lateNight,
    icon: Lucide.Moon,
    label: '深夜还在玩手机',
    subtitle: '23:30 到 2:00 之间屏幕还亮着',
  ),
  (
    trigger: AgencyTrigger.bedtimeCharging,
    icon: Lucide.Battery,
    label: '睡前插上充电',
    subtitle: '晚上 9 点以后刚开始充电',
  ),
];

const _chores = <_TriggerInfo>[
  (
    trigger: AgencyTrigger.calendar,
    icon: Lucide.Calendar,
    label: '日程快开始了',
    subtitle: '需要打开「日历查询」工具',
  ),
  (
    trigger: AgencyTrigger.screenTime,
    icon: Lucide.Smartphone,
    label: '今天手机用太久',
    subtitle: '需要打开「屏幕使用时间」工具',
  ),
  (
    trigger: AgencyTrigger.lowBattery,
    icon: Lucide.Battery,
    label: '电量低',
    subtitle: '没在充电的时候',
  ),
];

class _CompanionAgencySettingsPageState
    extends State<CompanionAgencySettingsPage> {
  final _store = AgencySettingsStore.instance;
  late final TextEditingController _note = TextEditingController(
    text: _store.value.note,
  );
  Timer? _noteDebounce;

  AgencySettings get _value => _store.value;

  @override
  void dispose() {
    _noteDebounce?.cancel();
    if (_note.text != _value.note) {
      unawaited(_store.update(_value.copyWith(note: _note.text)));
    }
    _note.dispose();
    super.dispose();
  }

  Future<void> _set(AgencySettings next) async {
    await _store.update(next);
    if (mounted) setState(() {});
  }

  Future<void> _pickModel() async {
    final value = await showModelSelector(
      context,
      initialProviderKey: _value.modelProvider,
      initialModelId: _value.modelId,
      allowInherit: true,
      inheritLabel: '跟随聊天',
    );
    if (!mounted || value == null) return;
    await _set(
      value.providerKey.isEmpty || value.modelId.isEmpty
          ? _value.copyWith(clearModel: true)
          : _value.copyWith(
              model: (providerKey: value.providerKey, modelId: value.modelId),
            ),
    );
  }

  String _modelLabel(SettingsProvider settings) {
    final provider = _value.modelProvider;
    final model = _value.modelId;
    if (provider == null || model == null) return '跟随聊天';
    final config = settings.getProviderConfig(provider);
    return '${config.name} · $model';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final settings = context.watch<SettingsProvider>();
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          minSize: 44,
          semanticLabel: '返回',
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Companion Agency'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const IosSectionHeader(text: '它', first: true),
          SectionCard(
            children: [
              IosNavRow(
                icon: Lucide.Brain,
                label: '主动找你时用的模型',
                detailText: _modelLabel(settings),
                onTap: _pickModel,
              ),
              const IosRowDivider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                child: IosFormTextField(
                  label: '给它的话',
                  controller: _note,
                  minLines: 2,
                  maxLines: 6,
                  hintText: '它每次醒来或碰到事情时都会看到。比如：我上课时别找我；周末可以多来。',
                  onChanged: (text) {
                    _noteDebounce?.cancel();
                    _noteDebounce = Timer(
                      const Duration(milliseconds: 600),
                      () =>
                          unawaited(_store.update(_value.copyWith(note: text))),
                    );
                  },
                ),
              ),
            ],
          ),
          const IosSectionFooter(
            text: '不选模型就跟聊天用同一个。主动找你、挑「没说完的事」都用这里的模型，选个便宜点的也行。',
          ),
          const IosSectionHeader(text: '自己醒来'),
          SectionCard(
            children: [
              _Stepper(
                icon: Lucide.Hourglass,
                label: '最短隔多久醒一次',
                value: _value.wakeMinMinutes,
                format: _hours,
                step: 30,
                min: 30,
                max: _value.wakeMaxMinutes,
                onChanged: (v) => _set(_value.copyWith(wakeMinMinutes: v)),
              ),
              const IosRowDivider(),
              _Stepper(
                icon: Lucide.Hourglass,
                label: '最长隔多久醒一次',
                value: _value.wakeMaxMinutes,
                format: _hours,
                step: 30,
                min: _value.wakeMinMinutes,
                max: 1440,
                onChanged: (v) => _set(_value.copyWith(wakeMaxMinutes: v)),
              ),
            ],
          ),
          const IosSectionFooter(
            text:
                'App 关着它也会在这个范围里随机醒来，看看下面这些事有没有发生，'
                '每件事掷一次骰子，中了才把它叫醒；醒了它也可以决定不打扰你。'
                '夜里 1 点（开了「深夜」就是 2 点）到 8 点不醒。'
                '每天最多主动找你 4 次，两次至少隔 45 分钟。',
          ),
          const IosSectionHeader(text: '想到你'),
          SectionCard(children: _rows(_feelings)),
          const IosSectionHeader(text: '生活里的小节点'),
          SectionCard(
            children: [
              ..._rows(_moments),
              if (_value.enabled(AgencyTrigger.newPlace)) ...[
                const IosRowDivider(),
                IosNavRow(
                  icon: Lucide.MapPin,
                  label: '定位权限选「始终允许」',
                  subtitle: 'App 关着时才能发现你换了地方',
                  onTap: () => unawaited(DeviceLocalTools.openAppSettings()),
                ),
              ],
            ],
          ),
          const IosSectionHeader(text: '碰到事情'),
          SectionCard(
            children: [
              ..._rows(_chores),
              const IosRowDivider(),
              _Stepper(
                icon: Lucide.Calendar,
                label: '日程提前多久',
                value: _value.calendarLeadMinutes,
                format: (v) => '$v 分钟',
                step: 5,
                min: 5,
                max: 180,
                onChanged: (v) => _set(_value.copyWith(calendarLeadMinutes: v)),
              ),
              const IosRowDivider(),
              _Stepper(
                icon: Lucide.Smartphone,
                label: '手机用了多久算久',
                value: _value.screenTimeHours,
                format: (v) => '$v 小时',
                step: 1,
                min: 1,
                max: 12,
                onChanged: (v) => _set(_value.copyWith(screenTimeHours: v)),
              ),
              const IosRowDivider(),
              _Stepper(
                icon: Lucide.Battery,
                label: '电量低于',
                value: _value.lowBatteryPercent,
                format: (v) => '$v%',
                step: 5,
                min: 5,
                max: 50,
                onChanged: (v) => _set(_value.copyWith(lowBatteryPercent: v)),
              ),
            ],
          ),
          const IosSectionFooter(text: '「它有多主动」：少，偶尔来；中，大多数时候来；多，几乎每次都来。'),
        ],
      ),
    );
  }

  List<Widget> _rows(List<_TriggerInfo> infos) => [
    for (final (i, info) in infos.indexed) ...[
      if (i > 0) const IosRowDivider(),
      IosSwitchRow(
        icon: info.icon,
        label: info.label,
        subtitle: info.subtitle,
        value: _value.enabled(info.trigger),
        onChanged: (on) => _set(
          _value.withTrigger(
            info.trigger,
            _value.trigger(info.trigger).copyWith(enabled: on),
          ),
        ),
      ),
      if (_value.enabled(info.trigger))
        Padding(
          padding: const EdgeInsets.fromLTRB(54, 0, 12, 12),
          child: SegmentedTabs(
            height: 32,
            tabs: const [
              SegmentedTab(label: '少'),
              SegmentedTab(label: '中'),
              SegmentedTab(label: '多'),
            ],
            index: _value.trigger(info.trigger).level.index,
            onChanged: (i) => _set(
              _value.withTrigger(
                info.trigger,
                _value
                    .trigger(info.trigger)
                    .copyWith(level: AgencyLevel.values[i]),
              ),
            ),
          ),
        ),
    ],
  ];

  static String _hours(int minutes) {
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (h == 0) return '$m 分钟';
    return m == 0 ? '$h 小时' : '$h.5 小时';
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.icon,
    required this.label,
    required this.value,
    required this.format,
    required this.step,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final int value;
  final String Function(int) format;
  final int step, min, max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return IosNavRow(
      icon: icon,
      label: label,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IosIconButton(
            icon: Lucide.Minus,
            size: 18,
            minSize: 36,
            color: value - step < min ? cs.outline : cs.onSurface,
            semanticLabel: '减少',
            onTap: value - step < min ? null : () => onChanged(value - step),
          ),
          SizedBox(
            width: 72,
            child: Text(format(value), textAlign: TextAlign.center),
          ),
          IosIconButton(
            icon: Lucide.Plus,
            size: 18,
            minSize: 36,
            color: value + step > max ? cs.outline : cs.onSurface,
            semanticLabel: '增加',
            onTap: value + step > max ? null : () => onChanged(value + step),
          ),
        ],
      ),
    );
  }
}

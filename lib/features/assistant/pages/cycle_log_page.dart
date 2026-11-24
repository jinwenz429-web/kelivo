import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/agency/cycle_log.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../shared/widgets/action_sheet.dart';
import '../../../shared/widgets/ios_date_picker.dart';
import '../../../shared/widgets/ios_settings_rows.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../shared/widgets/section_card.dart';

/// Period log kept on this phone. The companion only gets a one-line
/// estimate of where today sits in the cycle. Chinese only, like the rest of
/// this fork's agency UI.
class CycleLogPage extends StatefulWidget {
  const CycleLogPage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push<void>(MaterialPageRoute<void>(builder: (_) => const CycleLogPage()));

  @override
  State<CycleLogPage> createState() => _CycleLogPageState();
}

class _CycleLogPageState extends State<CycleLogPage> {
  final _store = CycleLogStore.instance;

  CycleLog get _log => _store.value;

  Future<void> _set(CycleLog next) async {
    await _store.update(next);
    if (mounted) setState(() {});
  }

  Future<DateTime?> _pickDay(DateTime initial, {DateTime? first}) {
    final today = calendarDay(DateTime.now());
    return showIosDatePicker(
      context,
      firstDate: first ?? DateTime(today.year - 3),
      lastDate: today,
      initialDate: initial.isAfter(today) ? today : initial,
    );
  }

  Future<void> _addPast() async {
    final start = await _pickDay(DateTime.now());
    if (start == null || !mounted) return;
    final end = await _pickDay(
      start.add(Duration(days: _log.averagePeriodLength - 1)),
      first: start,
    );
    if (!mounted) return;
    await _set(_log.add(CyclePeriod(start: start, end: end)));
  }

  Future<void> _edit(CyclePeriod period) => showMobileActionSheet(
    context,
    title: _range(period),
    items: [
      ActionSheetItem(
        icon: Lucide.Calendar,
        label: '改开始那天',
        onTap: () => unawaited(_editStart(period)),
      ),
      ActionSheetItem(
        icon: Lucide.Calendar,
        label: period.ongoing ? '记上结束那天' : '改结束那天',
        onTap: () => unawaited(_editEnd(period)),
      ),
      if (!period.ongoing)
        ActionSheetItem(
          icon: Lucide.Droplets,
          label: '其实还没结束',
          onTap: () => unawaited(
            _set(_log.replace(period, period.copyWith(clearEnd: true))),
          ),
        ),
      ActionSheetItem(
        icon: Lucide.Trash2,
        label: '删掉这次',
        destructive: true,
        onTap: () => unawaited(_set(_log.remove(period))),
      ),
    ],
  );

  Future<void> _editStart(CyclePeriod period) async {
    final day = await _pickDay(period.start);
    if (day == null || !mounted) return;
    final end = period.end;
    await _set(
      _log.replace(
        period,
        CyclePeriod(
          start: day,
          end: end != null && end.isBefore(day) ? day : end,
        ),
      ),
    );
  }

  Future<void> _editEnd(CyclePeriod period) async {
    final day = await _pickDay(
      period.end ?? DateTime.now(),
      first: period.start,
    );
    if (day == null || !mounted) return;
    await _set(_log.replace(period, period.copyWith(end: day)));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final status = _log.statusOn(now);
    final latest = _log.latest;
    final ongoing =
        status?.phase == CyclePhase.period && latest?.ongoing == true;

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
        title: const Text('经期记录'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          const IosSectionHeader(text: '现在', first: true),
          SectionCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
                child: Text(
                  status == null ? '还没有记录' : CycleLog.describe(status, now),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (status != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Text(
                    '下次大约 ${_md(status.nextStart)}'
                    '${status.basedOnCycles == 0 ? '（记满两次以后会准一些）' : ''}',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: ongoing
                      ? IosTileButton(
                          icon: Lucide.Check,
                          label: '今天结束了',
                          fontSize: 15,
                          onTap: () => unawaited(_set(_log.endOn(now))),
                        )
                      : IosTileButton(
                          icon: Lucide.Droplets,
                          label: '今天来了',
                          fontSize: 15,
                          backgroundColor: cs.primary,
                          onTap: () => unawaited(_set(_log.startOn(now))),
                        ),
                ),
              ),
            ],
          ),
          const IosSectionFooter(text: '日子记错了，点下面那一次就能改。'),
          const IosSectionHeader(text: '他'),
          SectionCard(
            children: [
              IosSwitchRow(
                icon: Lucide.Heart,
                label: '让他知道',
                subtitle: '聊天、醒来和打电话时带上一句「你现在大概在哪个阶段」',
                value: _log.shareWithCompanion,
                onChanged: (on) => _set(_log.copyWith(shareWithCompanion: on)),
              ),
            ],
          ),
          const IosSectionFooter(
            text:
                '记录只存在这台手机上。他每次只收到一句推算出来的状态，'
                '心里有数，不会每个周期都来提醒你。',
          ),
          const IosSectionHeader(text: '以前'),
          SectionCard(
            children: [
              for (final (i, period) in _log.periods.indexed) ...[
                if (i > 0) const IosRowDivider(),
                IosNavRow(
                  icon: Lucide.Droplets,
                  label: _range(period),
                  detailText: period.ongoing ? '还在' : '${period.length} 天',
                  onTap: () => unawaited(_edit(period)),
                ),
              ],
              if (_log.periods.isNotEmpty) const IosRowDivider(),
              IosNavRow(
                icon: Lucide.CalendarPlus,
                label: '补记一次',
                onTap: () => unawaited(_addPast()),
              ),
            ],
          ),
          if (_log.periods.length >= 2)
            IosSectionFooter(
              text:
                  '平均周期 ${_log.averageCycleLength} 天，'
                  '经期 ${_log.averagePeriodLength} 天。',
            ),
        ],
      ),
    );
  }

  static String _md(DateTime d) => '${d.month} 月 ${d.day} 日';

  static String _range(CyclePeriod p) {
    final end = p.end;
    if (end == null) return '${_md(p.start)} 开始';
    if (end.year == p.start.year && end.month == p.start.month) {
      return '${_md(p.start)} – ${end.day} 日';
    }
    return '${_md(p.start)} – ${_md(end)}';
  }
}

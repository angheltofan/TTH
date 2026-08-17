import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/child_calendar_session.dart';

/// A compact month grid that highlights days on which the child has
/// eligible workshop sessions.
///
/// Visual encoding (never colour-only):
///   • Green dot + check icon    → at least one 'present' attendance.
///   • Red dot + close icon      → at least one 'absent' attendance.
///   • Blue outline + dot marker → unmarked eligible session.
///   • Warning icon overlay      → mixed statuses on the same day.
/// Days with no eligible session are rendered neutrally and disabled.
class AttendanceCalendarGrid extends StatelessWidget {
  const AttendanceCalendarGrid({
    super.key,
    required this.month, // any day in the target month
    required this.sessionsByDate,
    required this.selectedDate,
    required this.onDaySelected,
  });

  final DateTime month;
  final Map<DateTime, List<ChildCalendarSession>> sessionsByDate;
  final DateTime? selectedDate;
  final ValueChanged<DateTime> onDaySelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final firstOfMonth = DateTime(month.year, month.month, 1);
    // Monday-first calendar: weekday returns 1..7 for Mon..Sun.
    final leadingBlanks = (firstOfMonth.weekday - 1) % 7;
    final daysInMonth = DateUtils.getDaysInMonth(month.year, month.month);
    final totalCells =
        ((leadingBlanks + daysInMonth) / 7).ceil() * 7;

    return LayoutBuilder(builder: (context, constraints) {
      // Tighten the cell aspect on narrower screens so the whole month fits
      // without vertical scroll on typical phones.
      final width = constraints.maxWidth;
      final childAspect = width < 380 ? 0.85 : 1.0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: const [
              _WeekdayLabel('Lun'),
              _WeekdayLabel('Mar'),
              _WeekdayLabel('Mie'),
              _WeekdayLabel('Joi'),
              _WeekdayLabel('Vin'),
              _WeekdayLabel('Sâm'),
              _WeekdayLabel('Dum'),
            ],
          ),
          const SizedBox(height: 6),
          GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: childAspect,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            itemCount: totalCells,
            itemBuilder: (context, index) {
              final dayNum = index - leadingBlanks + 1;
              if (dayNum < 1 || dayNum > daysInMonth) {
                return const SizedBox.shrink();
              }
              final date = DateTime(month.year, month.month, dayNum);
              final key = DateTime(date.year, date.month, date.day);
              final sessions = sessionsByDate[key] ?? const [];
              final isSelected = selectedDate != null &&
                  DateUtils.isSameDay(selectedDate!, date);
              return _CalendarCell(
                date: date,
                sessions: sessions,
                selected: isSelected,
                today: DateUtils.isSameDay(date, DateTime.now()),
                onTap: sessions.isEmpty ? null : () => onDaySelected(date),
                theme: theme,
              );
            },
          ),
        ],
      );
    });
  }
}

class _WeekdayLabel extends StatelessWidget {
  const _WeekdayLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppColors.muted,
          ),
        ),
      ),
    );
  }
}

enum _DayMood { none, presentOnly, absentOnly, unmarkedOnly, mixed }

_DayMood _moodFor(List<ChildCalendarSession> sessions) {
  if (sessions.isEmpty) return _DayMood.none;
  var hasPresent = false;
  var hasAbsent = false;
  var hasUnmarked = false;
  for (final s in sessions) {
    switch (s.status) {
      case 'present':
      case 'motivated':
        hasPresent = true;
      case 'absent':
        hasAbsent = true;
      default:
        hasUnmarked = true;
    }
  }
  final flags = [hasPresent, hasAbsent, hasUnmarked].where((f) => f).length;
  if (flags >= 2) return _DayMood.mixed;
  if (hasPresent) return _DayMood.presentOnly;
  if (hasAbsent) return _DayMood.absentOnly;
  return _DayMood.unmarkedOnly;
}

class _CalendarCell extends StatelessWidget {
  const _CalendarCell({
    required this.date,
    required this.sessions,
    required this.selected,
    required this.today,
    required this.onTap,
    required this.theme,
  });

  final DateTime date;
  final List<ChildCalendarSession> sessions;
  final bool selected;
  final bool today;
  final VoidCallback? onTap;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final mood = _moodFor(sessions);
    final (bg, fg, border, icon) = switch (mood) {
      _DayMood.none => (
          Colors.transparent,
          AppColors.muted,
          AppColors.borderLight,
          null as IconData?,
        ),
      _DayMood.presentOnly => (
          AppColors.success.withValues(alpha: 0.18),
          AppColors.success,
          AppColors.success,
          Icons.check_rounded,
        ),
      _DayMood.absentOnly => (
          AppColors.error.withValues(alpha: 0.15),
          AppColors.error,
          AppColors.error,
          Icons.close_rounded,
        ),
      _DayMood.unmarkedOnly => (
          Colors.transparent,
          AppColors.info,
          AppColors.info,
          Icons.circle_outlined,
        ),
      _DayMood.mixed => (
          AppColors.warning.withValues(alpha: 0.15),
          AppColors.warning,
          AppColors.warning,
          Icons.horizontal_rule_rounded,
        ),
    };

    final tooltip = _tooltipFor(sessions);
    final baseText = theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: mood == _DayMood.none
              ? AppColors.muted.withValues(alpha: 0.6)
              : fg,
        );

    final cell = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.purple : border,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text('${date.day}', style: baseText),
            const SizedBox(height: 2),
            if (icon != null)
              Icon(icon, size: 12, color: fg)
            else if (today)
              Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(
                  color: AppColors.purple,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
    if (tooltip == null) return cell;
    return Tooltip(message: tooltip, child: cell);
  }

  String? _tooltipFor(List<ChildCalendarSession> sessions) {
    if (sessions.isEmpty) return null;
    final lines = <String>[];
    for (final s in sessions) {
      final label = switch (s.status) {
        'present' => 'Prezent',
        'absent' => 'Absent',
        'motivated' => 'Motivat',
        _ => 'Nemarcat',
      };
      lines.add(
        '• ${s.startTimeShort} – ${s.workshopTitle}: $label',
      );
    }
    return lines.join('\n');
  }
}

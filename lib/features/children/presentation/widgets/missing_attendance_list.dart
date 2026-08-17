import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/child_calendar_session.dart';

/// Displays past sessions for a child that have no attendance yet, with
/// inline Prezent / Absent buttons. Used by the "Prezențe necompletate"
/// mode of the child attendance calendar page.
class MissingAttendanceList extends StatelessWidget {
  const MissingAttendanceList({
    super.key,
    required this.sessions,
    required this.onMark,
    required this.busyWorkshopIds,
  });

  final List<ChildCalendarSession> sessions;
  final Future<void> Function(
    ChildCalendarSession session,
    String status,
  ) onMark;
  final Set<String> busyWorkshopIds;

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      return _EmptyState();
    }
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: sessions.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final s = sessions[i];
        return _MissingItem(
          session: s,
          busy: busyWorkshopIds.contains(s.scheduledWorkshopId),
          onMark: onMark,
        );
      },
    );
  }
}

class _MissingItem extends StatelessWidget {
  const _MissingItem({
    required this.session,
    required this.busy,
    required this.onMark,
  });

  final ChildCalendarSession session;
  final bool busy;
  final Future<void> Function(ChildCalendarSession, String) onMark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.borderLight),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 480;
        final label = _title(session);
        final subtitle = _subtitle(session);

        final buttonsRow = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CompactBtn(
              label: 'Prezent',
              icon: Icons.check_rounded,
              color: AppColors.success,
              onTap: busy ? null : () => onMark(session, 'present'),
            ),
            const SizedBox(width: 6),
            _CompactBtn(
              label: 'Absent',
              icon: Icons.close_rounded,
              color: AppColors.error,
              onTap: busy ? null : () => onMark(session, 'absent'),
            ),
            if (busy) ...[
              const SizedBox(width: 8),
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ],
        );

        if (isNarrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  )),
              const SizedBox(height: 2),
              Text(subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                  )),
              const SizedBox(height: 10),
              buttonsRow,
            ],
          );
        }
        return Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                      )),
                ],
              ),
            ),
            buttonsRow,
          ],
        );
      }),
    );
  }

  static const _months = [
    '', 'ian', 'feb', 'mar', 'apr', 'mai', 'iun',
    'iul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];

  String _title(ChildCalendarSession s) {
    final d = s.workshopDate;
    return '${d.day} ${_months[d.month]} ${d.year} — ${s.workshopTitle}';
  }

  String _subtitle(ChildCalendarSession s) {
    final parts = <String>[];
    if (s.dayOfWeek != null && s.dayOfWeek!.isNotEmpty) {
      parts.add(s.dayOfWeek!.toLowerCase());
    }
    parts.add('${s.startTimeShort}–${s.endTimeShort}');
    if (s.workshopType.isNotEmpty) parts.add(s.workshopType);
    return parts.join(' • ');
  }
}

class _CompactBtn extends StatelessWidget {
  const _CompactBtn({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 14),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.5)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size(0, 36),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.30)),
      ),
      child: Column(
        children: [
          const Icon(Icons.check_circle_outline_rounded,
              size: 32, color: AppColors.success),
          const SizedBox(height: 8),
          Text(
            'Toate prezențele recente sunt completate.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.success,
            ),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../domain/child_current_status_row.dart';

/// Horizontal chronological timeline of attendance rows for one series.
///
/// Each pill shows: date, status icon, status label, and — for PRESENT
/// rows — the running "N / 4" counter (absences don't advance it).
/// Scrolls horizontally on narrow viewports so the timeline never
/// truncates or compresses to illegible sizes.
class AttendanceTimeline extends StatelessWidget {
  const AttendanceTimeline({
    super.key,
    required this.rows,
    this.emptyMessage,
    this.compact = false,
  });

  final List<ChildCurrentStatusRow> rows;
  final String? emptyMessage;

  /// When true, uses a smaller pill footprint (used inside accordion
  /// bodies where vertical space is at a premium).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Text(
        emptyMessage ?? 'Nu există înregistrări pentru acest interval.',
        style: TextStyle(
          color: AppColors.muted,
          fontSize: compact ? 12 : 13,
          fontWeight: FontWeight.w500,
        ),
      );
    }

    // Compute running present counter, capped at 4 within a cycle.
    var presentSoFar = 0;
    final pills = <_TimelinePill>[];
    for (final r in rows) {
      String? counter;
      if (r.attendanceStatus == 'present') {
        presentSoFar += 1;
        if (presentSoFar > 4) presentSoFar = 4;
        counter = '$presentSoFar / 4';
      }
      pills.add(_TimelinePill(
        date: r.workshopDate,
        status: r.attendanceStatus,
        counter: counter,
        compact: compact,
      ));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < pills.length; i++) ...[
            if (i > 0) _Connector(compact: compact),
            pills[i],
          ],
        ],
      ),
    );
  }
}

class _TimelinePill extends StatelessWidget {
  const _TimelinePill({
    required this.date,
    required this.status,
    required this.counter,
    required this.compact,
  });

  final DateTime? date;
  final String? status;
  final String? counter;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (status) {
      'present' => (AppColors.success, Icons.check_rounded, 'Prezent'),
      'absent' => (AppColors.error, Icons.close_rounded, 'Absent'),
      'motivated' =>
        (AppColors.warning, Icons.event_available_rounded, 'Motivat'),
      _ => (AppColors.muted, Icons.circle_outlined, 'Nemarcat'),
    };
    final dateLabel = date == null ? '—' : _fmtDate(date!);
    final width = compact ? 84.0 : 92.0;
    final iconSize = compact ? 20.0 : 24.0;

    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            dateLabel,
            style: TextStyle(
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w700,
              color: AppColors.muted,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Container(
            width: iconSize + 12,
            height: iconSize + 12,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 1.5),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: iconSize - 4, color: color),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: compact ? 10 : 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
          if (counter != null) ...[
            const SizedBox(height: 2),
            Text(
              counter!,
              style: TextStyle(
                fontSize: compact ? 10 : 11,
                fontWeight: FontWeight.w600,
                color: AppColors.muted,
              ),
            ),
          ] else
            const SizedBox(height: 15), // keep vertical alignment across rows
        ],
      ),
    );
  }

  static const _months = [
    '', 'ian', 'feb', 'mar', 'apr', 'mai', 'iun',
    'iul', 'aug', 'sep', 'oct', 'nov', 'dec',
  ];

  String _fmtDate(DateTime d) => '${d.day.toString().padLeft(2, '0')} '
      '${_months[d.month]}';
}

class _Connector extends StatelessWidget {
  const _Connector({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: compact ? 22 : 26),
      child: Container(
        width: compact ? 16 : 20,
        height: 2,
        color: AppColors.borderLight,
      ),
    );
  }
}

/// Compact progress dots representation (● ● ● ○). Used by the series
/// selector card. Purely for present count — absences are not shown here
/// per spec.
class PresentProgressDots extends StatelessWidget {
  const PresentProgressDots({super.key, required this.presentCount});
  final int presentCount;

  @override
  Widget build(BuildContext context) {
    final filled = presentCount.clamp(0, 4);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(4, (i) {
        final isFilled = i < filled;
        return Padding(
          padding: EdgeInsets.only(right: i < 3 ? 6 : 0),
          child: Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isFilled
                  ? AppColors.success
                  : Colors.transparent,
              border: Border.all(
                color: isFilled ? AppColors.success : AppColors.muted,
                width: 1.5,
              ),
            ),
          ),
        );
      }),
    );
  }
}

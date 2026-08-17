import 'package:flutter/material.dart';

import '../../../../../core/theme/app_theme.dart';
import 'current_tab.dart' show CompletedCycleAccordion;
import 'series_snapshot.dart';

/// "Istoric cicluri" tab: every series with all its cycles as accordions.
/// Newest cycle first inside each series block, series ordered
/// alphabetically for stability.
class HistoryTab extends StatelessWidget {
  const HistoryTab({
    super.key,
    required this.childId,
    required this.snapshots,
  });

  final String childId;
  final Map<String, SeriesFinancialSnapshot> snapshots;

  @override
  Widget build(BuildContext context) {
    final ordered = snapshots.values
        .where((s) => s.allCycles.isNotEmpty)
        .toList()
      ..sort((a, b) => a.seriesTitle.compareTo(b.seriesTitle));

    if (ordered.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'Nu există istoric de cicluri pentru acest copil.',
            style: TextStyle(color: AppColors.muted),
          ),
        ),
      );
    }

    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var s = 0; s < ordered.length; s++) ...[
          if (s > 0) const SizedBox(height: 20),
          Text(
            ordered[s].seriesTitle,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
              color: AppColors.purple,
            ),
          ),
          const SizedBox(height: 8),
          for (var i = ordered[s].allCycles.length - 1; i >= 0; i--) ...[
            CompletedCycleAccordion(
              childId: childId,
              snapshot: ordered[s],
              cycleIndex: i,
              cycleNumber: i + 1,
            ),
            const SizedBox(height: 8),
          ],
        ],
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../data/workshops_repository.dart';

/// Compact summary of what a workshop-series cancellation will touch.
/// Used by the workshop details page's "Anulează atelierul" dialog to
/// give the admin an at-a-glance impact preview before they confirm.
class SeriesImpactSummary extends StatelessWidget {
  const SeriesImpactSummary({super.key, required this.impact});
  final SeriesCancellationImpact impact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _row(theme, 'Sesiuni anulate', impact.scheduledCount, outline),
          _row(theme, 'Înscrieri păstrate', impact.enrollmentCount, outline),
          _row(theme, 'Prezențe păstrate în istoric',
              impact.attendanceCount, outline),
        ],
      ),
    );
  }

  Widget _row(ThemeData theme, String label, int count, Color trailingColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          Text(
            '$count',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: trailingColor,
            ),
          ),
        ],
      ),
    );
  }
}

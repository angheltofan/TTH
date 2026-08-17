import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/widgets/error_state.dart';
import '../../../../../core/widgets/loading_state.dart';
import '../../../providers/child_details_providers.dart';
import 'current_tab.dart';
import 'history_tab.dart';
import 'series_snapshot.dart';
import 'summary_and_alert.dart';

/// Top-level module that replaces the previous `CurrentStatusCard` +
/// `PaymentStatusCard` on the Child Details page. Renders (top → bottom):
///   • Financial summary strip (4 compact cards)
///   • Payment alert banner (if any due cycles)
///   • Small plain-weight "Prezențe și plăți" label
///   • Underline TabBar left-aligned (compact — text-only tabs, small)
///   • Current or History tab content, in its own bordered card
///
/// Chrome is intentionally minimal to match the mockup: no big
/// DetailsSectionCard title/icon header — the tab strip is the label.
class AttendancePaymentsSection extends ConsumerStatefulWidget {
  const AttendancePaymentsSection({super.key, required this.childId});
  final String childId;

  @override
  ConsumerState<AttendancePaymentsSection> createState() =>
      _AttendancePaymentsSectionState();
}

class _AttendancePaymentsSectionState
    extends ConsumerState<AttendancePaymentsSection>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final attendanceAsync =
        ref.watch(childCurrentStatusRowsProvider(widget.childId));
    final cyclesAsync =
        ref.watch(childPaymentCyclesNewProvider(widget.childId));

    if (attendanceAsync.isLoading || cyclesAsync.isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: AppLoading(),
      );
    }
    if (attendanceAsync.hasError) {
      return AppError(message: attendanceAsync.error.toString());
    }
    if (cyclesAsync.hasError) {
      return AppError(message: cyclesAsync.error.toString());
    }

    final snapshots = SeriesFinancialSnapshot.buildAll(
      attendanceAsync.valueOrNull ?? const [],
      cyclesAsync.valueOrNull ?? const [],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FinancialSummaryStrip(snapshots: snapshots),
        if (_hasAnyDue(snapshots)) ...[
          const SizedBox(height: 10),
          PaymentAlertBanner(snapshots: snapshots),
        ],
        const SizedBox(height: 16),
        _SectionLabel(),
        const SizedBox(height: 4),
        _CompactTabBar(controller: _tabs),
        const SizedBox(height: 12),
        AnimatedBuilder(
          animation: _tabs,
          builder: (_, _) {
            return _tabs.index == 0
                ? CurrentTab(
                    childId: widget.childId,
                    snapshots: snapshots,
                  )
                : HistoryTab(
                    childId: widget.childId,
                    snapshots: snapshots,
                  );
          },
        ),
      ],
    );
  }

  bool _hasAnyDue(Map<String, SeriesFinancialSnapshot> snapshots) =>
      snapshots.values.any((s) => s.totalDue > 0);
}

/// Plain "Prezențe și plăți" label — small, medium weight, no icon, no
/// card chrome. Matches the mockup's "quiet header" pattern.
class _SectionLabel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      'Prezențe și plăți',
      style: theme.textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
      ),
    );
  }
}

/// Compact underline TabBar, left-aligned. Uses tab-width indicator
/// (not full-tab-width) so the underline hugs the label text.
class _CompactTabBar extends StatelessWidget {
  const _CompactTabBar({required this.controller});
  final TabController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: TabBar(
        controller: controller,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        labelColor: AppColors.purple,
        unselectedLabelColor: theme.colorScheme.onSurface
            .withValues(alpha: 0.55),
        indicatorColor: AppColors.purple,
        indicatorSize: TabBarIndicatorSize.label,
        indicatorWeight: 2,
        dividerColor: theme.colorScheme.outline.withValues(alpha: 0.15),
        dividerHeight: 1,
        padding: EdgeInsets.zero,
        labelPadding: const EdgeInsets.symmetric(horizontal: 14),
        labelStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
        unselectedLabelStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
        tabs: const [
          Tab(height: 38, text: 'Situație curentă'),
          Tab(height: 38, text: 'Istoric cicluri'),
        ],
      ),
    );
  }
}

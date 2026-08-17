import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/widgets/error_state.dart';
import '../../../../../core/widgets/loading_state.dart';
import '../../../providers/child_details_providers.dart';
import '../details_section_card.dart';
import 'current_tab.dart';
import 'history_tab.dart';
import 'series_snapshot.dart';
import 'summary_and_alert.dart';

/// Top-level module that replaces the previous `CurrentStatusCard` +
/// `PaymentStatusCard` on the Child Details page. Renders:
///   • Financial summary strip (4 compact cards)
///   • Payment alert banner (if any due cycles)
///   • Card with two tabs: "Situație curentă" + "Istoric cicluri"
///
/// All computation flows through [SeriesFinancialSnapshot.buildAll] so
/// data classification stays consistent between tabs.
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
      return const DetailsSectionCard(
        title: 'Prezențe și plăți',
        iconData: Icons.event_available_rounded,
        iconColor: Color(0xFF3B82F6),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: AppLoading(),
        ),
      );
    }

    if (attendanceAsync.hasError) {
      return DetailsSectionCard(
        title: 'Prezențe și plăți',
        iconData: Icons.event_available_rounded,
        iconColor: const Color(0xFF3B82F6),
        child: AppError(message: attendanceAsync.error.toString()),
      );
    }
    if (cyclesAsync.hasError) {
      return DetailsSectionCard(
        title: 'Prezențe și plăți',
        iconData: Icons.event_available_rounded,
        iconColor: const Color(0xFF3B82F6),
        child: AppError(message: cyclesAsync.error.toString()),
      );
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
        const SizedBox(height: 12),
        DetailsSectionCard(
          title: 'Prezențe și plăți',
          iconData: Icons.event_available_rounded,
          iconColor: const Color(0xFF3B82F6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TabBarStrip(controller: _tabs),
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
          ),
        ),
      ],
    );
  }

  bool _hasAnyDue(Map<String, SeriesFinancialSnapshot> snapshots) =>
      snapshots.values.any((s) => s.totalDue > 0);
}

class _TabBarStrip extends StatelessWidget {
  const _TabBarStrip({required this.controller});
  final TabController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest
            .withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: TabBar(
        controller: controller,
        labelColor: Colors.white,
        unselectedLabelColor: AppColors.muted,
        indicator: BoxDecoration(
          color: AppColors.purple,
          borderRadius: BorderRadius.circular(10),
        ),
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 13,
        ),
        tabs: const [
          Tab(text: 'Situație curentă'),
          Tab(text: 'Istoric cicluri'),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/responsive.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../auth/providers/auth_providers.dart';
import '../../parent/presentation/widgets/linked_parents_card.dart';
import '../../workshops/providers/enrollment_providers.dart';
import '../providers/child_details_providers.dart';
import 'child_attendance_calendar_page.dart';
import 'widgets/assigned_workshops_card.dart';
import 'widgets/attendance_payments/attendance_payments_section.dart';
import 'widgets/child_info_card.dart';
import 'widgets/generate_child_report_button.dart';

class ChildDetailsPage extends ConsumerStatefulWidget {
  const ChildDetailsPage({super.key, required this.childId});
  final String childId;

  @override
  ConsumerState<ChildDetailsPage> createState() => _ChildDetailsPageState();
}

class _ChildDetailsPageState extends ConsumerState<ChildDetailsPage> {
  @override
  Widget build(BuildContext context) {
    final childAsync = ref.watch(childByIdProvider(widget.childId));
    final workshopsAsync =
        ref.watch(childWorkshopSeriesProvider(widget.childId));
    final isAdmin =
        ref.watch(currentProfileProvider).valueOrNull?.isAdmin ?? false;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/children'),
        ),
        title: const Text('Detalii copil'),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_month_rounded),
            tooltip: 'Calendar prezențe',
            onPressed: () => ChildAttendanceCalendarModal.show(
              context,
              childId: widget.childId,
            ),
          ),
          GenerateChildReportButton(childId: widget.childId),
          const SizedBox(width: 4),
        ],
      ),
      body: childAsync.when(
        loading: () => const AppLoading(),
        error: (e, _) => Center(child: AppError(message: e.toString())),
        data: (child) {
          if (child == null) {
            return const Center(child: Text('Copilul nu a fost găsit.'));
          }
          return SingleChildScrollView(
            padding: context.mobilePadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Date copil
                ChildInfoCard(
                  child: child,
                  isAdmin: isAdmin,
                  workshopType: workshopsAsync.valueOrNull?.isNotEmpty == true
                      ? workshopsAsync.valueOrNull!.first.workshopType
                      : null,
                ),
                SizedBox(height: context.sectionGap),

                // 2. Atelierele la care vine (enrollment management)
                AssignedWorkshopsCard(childId: widget.childId),
                SizedBox(height: context.sectionGap),

                // 3. Prezențe și plăți — replaces the former "Status
                //    actual" + "Status plată" cards. Series-aware,
                //    tabbed (current vs history), with chronological
                //    timelines, an alert banner, and a summary strip.
                //    Rendered for both paid and free children: for free
                //    kids the summary/alert/history are trivially empty
                //    (no cycles exist server-side) and the current tab
                //    renders their pre-windowed attendance progression.
                AttendancePaymentsSection(childId: widget.childId),

                // 4. Părinți asociați — admin-only.
                if (isAdmin) ...[
                  SizedBox(height: context.sectionGap),
                  LinkedParentsCard(childId: widget.childId),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

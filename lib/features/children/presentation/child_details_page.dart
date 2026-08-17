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
import 'widgets/child_info_card.dart';
import 'widgets/current_status_card.dart';
import 'widgets/generate_child_report_button.dart';
import 'widgets/payment_status_card.dart';

class ChildDetailsPage extends ConsumerStatefulWidget {
  const ChildDetailsPage({super.key, required this.childId});
  final String childId;

  @override
  ConsumerState<ChildDetailsPage> createState() => _ChildDetailsPageState();
}

class _ChildDetailsPageState extends ConsumerState<ChildDetailsPage> {
  // Realtime is handled centrally by appRealtimeProvider, which subscribes
  // to `attendance` and `payment_cycles` and invalidates the same child
  // providers when the payload contains this child's id. The autoDispose
  // family providers below mount fresh on first watch, so there's no need
  // for a postFrameCallback invalidate-storm — that pattern was forcing a
  // second fetch immediately after the first autoDispose mount.

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

                // 2. Atelierul la care vine
                AssignedWorkshopsCard(childId: widget.childId),
                SizedBox(height: context.sectionGap),

                // 3. Status actual — identical card for both paths.
                //
                // For paid children the row source is `attendance` rows
                // with `payment_cycle_id IS NULL`, which the server
                // resets to NULL by linking them when a new cycle is
                // created. For free children no cycle is ever created
                // (DB trigger skips the INSERT), so the provider
                // windows the same query to the trailing "current
                // block" past the last 4th-present row — giving the
                // same X / 4 → reset to 0 / 4 behavior without any
                // financial side effect.
                CurrentStatusCard(childId: widget.childId),

                // 4. Status plată — paid participants only. Free
                // participants never have payment cycles, so the whole
                // payment card (and the cicluri / istoric / confirma
                // plata controls inside it) are skipped.
                if (!child.isFreeParticipant) ...[
                  SizedBox(height: context.sectionGap),
                  PaymentStatusCard(childId: widget.childId),
                ],

                // 5. Părinți asociați — admin-only in P4. Trainer read-only
                // access pending an RLS extension on child_parents/profiles.
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

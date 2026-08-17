import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/responsive.dart';
import '../../../auth/providers/auth_providers.dart';
import '../../domain/child_current_status_row.dart';
import '../../providers/child_details_providers.dart';
import 'attendance_row_item.dart';
import 'payment_dialog.dart';
import 'payment_status_helpers.dart';

class ActiveCycleSection extends ConsumerStatefulWidget {
  const ActiveCycleSection({
    super.key,
    required this.childId,
    required this.seriesId,
    required this.currentRows,
    required this.dueGroup,
    required this.isConfirmed,
    this.confirmedPaymentMethod,
  });

  final String childId;
  /// The workshop series this active cycle belongs to. Advance payments
  /// are scoped per (child, series) since migration 20260820.
  final String seriesId;
  final List<ChildCurrentStatusRow> currentRows;
  final CycleGroup? dueGroup;
  final bool isConfirmed;

  /// Display method for an already-confirmed advance payment: 'POS', 'OP', null.
  final String? confirmedPaymentMethod;

  @override
  ConsumerState<ActiveCycleSection> createState() => _ActiveCycleSectionState();
}

class _ActiveCycleSectionState extends ConsumerState<ActiveCycleSection> {
  bool _confirmedLocally = false;

  /// Method label tracked after local confirmation: 'POS', 'OP', or null.
  String? _confirmedMethod;

  bool get _showAsConfirmed => widget.isConfirmed || _confirmedLocally;

  String? get _effectiveMethod =>
      _confirmedLocally ? _confirmedMethod : widget.confirmedPaymentMethod;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = widget.currentRows;
    final isMobile = context.isMobile;

    final titleWidget = Text(
      'Ciclu activ',
      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
    );

    final actionWidget = _showAsConfirmed
        ? ConfirmedBadge(paymentMethod: _effectiveMethod)
        : FilledButton(
            onPressed: _onConfirm,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            child: const Text('Confirmă plata'),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Title row ──────────────────────────────────────────────────────
        if (isMobile)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              titleWidget,
              const SizedBox(height: 6),
              actionWidget,
            ],
          )
        else
          Row(
            children: [
              Expanded(child: titleWidget),
              actionWidget,
            ],
          ),
        const SizedBox(height: 4),
        Text(
          _showAsConfirmed
              ? 'Plata a fost confirmată pentru ședințele de mai jos.'
              : widget.dueGroup != null
                  ? 'Confirmați plata pentru ciclul curent.'
                  : 'Marchează plata în avans pentru ședințele de mai jos.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        const SizedBox(height: 12),
        // ── Attendance rows ───────────────────────────────────────────────
        const AttendanceTableHeader(),
        for (int i = 0; i < rows.length; i++)
          AttendanceRowItem(
            index: i + 1,
            workshopTitle: rows[i].workshopTitle ?? '—',
            dayOfWeek: rows[i].dayOfWeek,
            workshopDate: rows[i].workshopDate,
            startTime: rows[i].startTime,
            endTime: rows[i].endTime,
            attendanceStatus: rows[i].attendanceStatus,
            observation: rows[i].observation,
          ),
      ],
    );
  }

  Future<void> _onConfirm() async {
    final authUser = ref.read(currentUserProvider);
    if (authUser == null) return;
    final isStaff =
        ref.read(currentProfileProvider).valueOrNull?.isStaff ?? false;

    final isDue = widget.dueGroup != null;
    final repo = ref.read(childDetailsRepositoryProvider);

    final result = await showPaymentMethodDialog(
      context,
      onConfirm: (method, observation) async {
        final methodLower = method.toLowerCase(); // 'pos' or 'op'
        // Per spec: only the admin's observation goes into the notes
        // column. Empty → null (the repository converts empty string
        // to null / omit). The legacy "Plată confirmată prin POS."
        // baseline is dropped because `payment_method` is now always
        // set, so notes is no longer needed as a method fallback.
        final notes = observation ?? '';
        if (isDue) {
          await repo.confirmPayment(
            isStaff: isStaff,
            cycleId: widget.dueGroup!.cycleId,
            userId: authUser.id,
            paymentMethod: methodLower,
            notes: notes,
          );
        } else {
          await repo.markAdvancePayment(
            childId: widget.childId,
            seriesId: widget.seriesId,
            paymentMethod: methodLower,
            notes: notes,
          );
        }
      },
    );

    if (result == null) return;

    if (isDue) {
      ref.invalidate(childPaymentStatusRowsProvider(widget.childId));
      ref.invalidate(childPaymentCyclesNewProvider(widget.childId));
      ref.invalidate(childCurrentStatusRowsProvider(widget.childId));
      ref.invalidate(childCurrentStatusProvider(widget.childId));
    } else {
      ref.invalidate(childPaymentStatusRowsProvider(widget.childId));
      ref.invalidate(childPaymentCyclesNewProvider(widget.childId));
      if (mounted) {
        setState(() {
          _confirmedLocally = true;
          _confirmedMethod = result; // 'POS' or 'OP' (returned by dialog)
        });
      }
    }
  }
}

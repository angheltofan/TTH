import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/utils/date_utils.dart';
import '../../../../../core/utils/responsive.dart';
import '../../../../auth/providers/auth_providers.dart';
import '../../../providers/child_details_providers.dart';
import '../payment_dialog.dart';
import 'attendance_timeline.dart';
import 'series_snapshot.dart';

/// The default tab: left-column selector of series + right-column detail
/// showing the current cycle progress, its chronological timeline, and
/// an accordion of completed cycles for the same series.
///
/// Layout:
///   • desktop (≥900px): 2-column, 320px selector + Expanded detail
///   • tablet (600-900): single-column with a horizontal chip selector
///   • mobile (<600): dropdown selector + full-width detail
class CurrentTab extends ConsumerStatefulWidget {
  const CurrentTab({
    super.key,
    required this.childId,
    required this.snapshots,
  });

  final String childId;
  final Map<String, SeriesFinancialSnapshot> snapshots;

  @override
  ConsumerState<CurrentTab> createState() => _CurrentTabState();
}

class _CurrentTabState extends ConsumerState<CurrentTab> {
  String? _selectedSeriesId;

  @override
  Widget build(BuildContext context) {
    if (widget.snapshots.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            'Copilul nu are ateliere active sau istoric de prezențe.',
            style: TextStyle(color: AppColors.muted),
          ),
        ),
      );
    }

    final ordered = widget.snapshots.values.toList()
      ..sort((a, b) => a.seriesTitle.compareTo(b.seriesTitle));
    _selectedSeriesId ??= ordered.first.seriesId;
    final selected =
        widget.snapshots[_selectedSeriesId] ?? ordered.first;

    final width = MediaQuery.of(context).size.width;
    if (width >= 900) {
      return _buildTwoColumn(ordered, selected);
    }
    if (context.isMobile) {
      return _buildMobile(ordered, selected);
    }
    return _buildTablet(ordered, selected);
  }

  Widget _buildTwoColumn(
      List<SeriesFinancialSnapshot> ordered, SeriesFinancialSnapshot sel) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 320,
          child: _SelectorList(
            snapshots: ordered,
            selectedId: sel.seriesId,
            onSelect: (id) => setState(() => _selectedSeriesId = id),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(child: _DetailPane(childId: widget.childId, snapshot: sel)),
      ],
    );
  }

  Widget _buildTablet(
      List<SeriesFinancialSnapshot> ordered, SeriesFinancialSnapshot sel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 68,
          child: _ChipSelector(
            snapshots: ordered,
            selectedId: sel.seriesId,
            onSelect: (id) => setState(() => _selectedSeriesId = id),
          ),
        ),
        const SizedBox(height: 12),
        _DetailPane(childId: widget.childId, snapshot: sel),
      ],
    );
  }

  Widget _buildMobile(
      List<SeriesFinancialSnapshot> ordered, SeriesFinancialSnapshot sel) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DropdownSelector(
          snapshots: ordered,
          selectedId: sel.seriesId,
          onSelect: (id) => setState(() => _selectedSeriesId = id),
        ),
        const SizedBox(height: 12),
        _DetailPane(childId: widget.childId, snapshot: sel),
      ],
    );
  }
}

// ── LEFT COLUMN: selector list ────────────────────────────────────────

class _SelectorList extends StatelessWidget {
  const _SelectorList({
    required this.snapshots,
    required this.selectedId,
    required this.onSelect,
  });

  final List<SeriesFinancialSnapshot> snapshots;
  final String selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final s in snapshots) ...[
          _SelectorCard(
            snapshot: s,
            selected: s.seriesId == selectedId,
            onTap: () => onSelect(s.seriesId),
          ),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _SelectorCard extends StatelessWidget {
  const _SelectorCard({
    required this.snapshot,
    required this.selected,
    required this.onTap,
  });

  final SeriesFinancialSnapshot snapshot;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lastP = snapshot.lastPresentDate;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.purple.withValues(alpha: 0.06)
                : theme.cardTheme.color,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? AppColors.purple
                  : theme.colorScheme.outline.withValues(alpha: 0.2),
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                snapshot.seriesTitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                'Ciclu curent',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${snapshot.currentPresentCount} / 4 prezențe',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  PresentProgressDots(
                    presentCount: snapshot.currentPresentCount,
                  ),
                ],
              ),
              if (lastP != null || snapshot.currentBlockClosingSoon) ...[
                const SizedBox(height: 8),
                if (lastP != null)
                  Text(
                    'Ultima prezență: ${formatDate(lastP)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (snapshot.currentBlockClosingSoon) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Următoarea prezență închide ciclul.',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.info,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Tablet chip selector ──────────────────────────────────────────────

class _ChipSelector extends StatelessWidget {
  const _ChipSelector({
    required this.snapshots,
    required this.selectedId,
    required this.onSelect,
  });

  final List<SeriesFinancialSnapshot> snapshots;
  final String selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      scrollDirection: Axis.horizontal,
      itemCount: snapshots.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (context, i) {
        final s = snapshots[i];
        final selected = s.seriesId == selectedId;
        return ChoiceChip(
          selected: selected,
          onSelected: (_) => onSelect(s.seriesId),
          label: Text(
            '${s.seriesTitle} · ${s.currentPresentCount}/4',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : null,
            ),
          ),
          selectedColor: AppColors.purple,
        );
      },
    );
  }
}

// ── Mobile dropdown selector ──────────────────────────────────────────

class _DropdownSelector extends StatelessWidget {
  const _DropdownSelector({
    required this.snapshots,
    required this.selectedId,
    required this.onSelect,
  });

  final List<SeriesFinancialSnapshot> snapshots;
  final String selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: selectedId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Selectează atelier',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: [
        for (final s in snapshots)
          DropdownMenuItem(
            value: s.seriesId,
            child: Text(
              '${s.seriesTitle} · ${s.currentPresentCount}/4',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (v) {
        if (v != null) onSelect(v);
      },
    );
  }
}

// ── RIGHT COLUMN: detail pane ─────────────────────────────────────────

class _DetailPane extends ConsumerWidget {
  const _DetailPane({required this.childId, required this.snapshot});
  final String childId;
  final SeriesFinancialSnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final present = snapshot.currentPresentCount;
    final statusLabel = present >= 4
        ? 'Complet · așteaptă plată'
        : present == 0
            ? 'În desfășurare'
            : 'În desfășurare · $present/4';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            snapshot.seriesTitle,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text('Ciclu curent',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.muted,
                    fontWeight: FontWeight.w700,
                  )),
              const SizedBox(width: 8),
              _StatusChip(text: statusLabel),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Text(
                '$present / 4 prezențe',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 12),
              PresentProgressDots(presentCount: present),
              const Spacer(),
              if (snapshot.hasAdvance)
                _AdvanceBadge(cycle: snapshot.advanceCycle!),
            ],
          ),
          if (snapshot.currentBlock.isNotEmpty) ...[
            const SizedBox(height: 16),
            AttendanceTimeline(rows: snapshot.currentBlock),
          ] else ...[
            const SizedBox(height: 12),
            Text(
              'Ciclul curent nu are încă prezențe marcate.',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (snapshot.allCycles.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(
              'Cicluri finalizate',
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 8),
            for (var i = snapshot.allCycles.length - 1; i >= 0; i--) ...[
              CompletedCycleAccordion(
                childId: childId,
                snapshot: snapshot,
                cycleIndex: i,
                cycleNumber: i + 1,
              ),
              const SizedBox(height: 8),
            ],
          ],
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.info,
        ),
      ),
    );
  }
}

class _AdvanceBadge extends StatelessWidget {
  const _AdvanceBadge({required this.cycle});
  final dynamic cycle;
  @override
  Widget build(BuildContext context) {
    final method = (cycle.paymentMethod as String?)?.toUpperCase();
    final label = method != null && method.isNotEmpty
        ? 'Achitat în avans · $method'
        : 'Achitat în avans';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppColors.info,
        ),
      ),
    );
  }
}

// ── Completed cycle accordion ─────────────────────────────────────────

class CompletedCycleAccordion extends ConsumerStatefulWidget {
  const CompletedCycleAccordion({
    super.key,
    required this.childId,
    required this.snapshot,
    required this.cycleIndex,
    required this.cycleNumber,
  });

  final String childId;
  final SeriesFinancialSnapshot snapshot;
  final int cycleIndex;
  final int cycleNumber;

  @override
  ConsumerState<CompletedCycleAccordion> createState() =>
      _CompletedCycleAccordionState();
}

class _CompletedCycleAccordionState
    extends ConsumerState<CompletedCycleAccordion> {
  bool _expanded = false;
  bool _confirming = false;

  @override
  Widget build(BuildContext context) {
    final cycle = widget.snapshot.allCycles[widget.cycleIndex];
    final rows = widget.snapshot.rowsForCycle(cycle.id);
    final theme = Theme.of(context);

    final (statusColor, statusLabel) = switch (cycle.status) {
      'paid' => (AppColors.success, 'Achitat'),
      'due' => (AppColors.warning, 'De plată'),
      'overdue' => (AppColors.error, 'Restant'),
      'cancelled' => (AppColors.muted, 'Anulat'),
      _ => (AppColors.muted, cycle.status ?? '—'),
    };

    final period = (cycle.periodStart != null && cycle.periodEnd != null)
        ? '${formatDate(cycle.periodStart!)} – ${formatDate(cycle.periodEnd!)}'
        : '—';
    final presCount = widget.snapshot.presencesInCycle(cycle.id);
    final absCount = widget.snapshot.absencesInCycle(cycle.id);

    return Container(
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: AppColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              'Ciclul #${widget.cycleNumber}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                    color: statusColor.withValues(alpha: 0.4)),
                              ),
                              child: Text(
                                statusLabel,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: statusColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$period · $presCount prezențe'
                          '${absCount > 0 ? ", $absCount absențe" : ""}',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.muted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (cycle.paidAt != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Achitat la ${formatDate(cycle.paidAt!)}'
                            '${cycle.paymentMethod != null ? " · ${cycle.paymentMethod!.toUpperCase()}" : ""}',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.success,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (cycle.status == 'due' || cycle.status == 'overdue')
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: FilledButton(
                        onPressed: _confirming
                            ? null
                            : () => _confirm(cycle.id),
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: _confirming
                            ? const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Text(
                                'Confirmă plata',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700),
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Container(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: theme.colorScheme.outline.withValues(alpha: 0.12),
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: AttendanceTimeline(rows: rows, compact: true),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirm(String cycleId) async {
    final authUser = ref.read(currentUserProvider);
    if (authUser == null) return;
    final isStaff =
        ref.read(currentProfileProvider).valueOrNull?.isStaff ?? false;
    setState(() => _confirming = true);
    try {
      await showPaymentMethodDialog(
        context,
        onConfirm: (method, observation) async {
          await ref
              .read(childDetailsRepositoryProvider)
              .confirmPayment(
                isStaff: isStaff,
                cycleId: cycleId,
                userId: authUser.id,
                paymentMethod: method.toLowerCase(),
                notes: observation ?? '',
              );
        },
      );
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }
}

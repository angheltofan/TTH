import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/date_utils.dart';
import '../../domain/dashboard_workshop.dart';
import 'workshop_card_helpers.dart';

/// A unified workshop card used in both "Ateliere azi" and "Toate atelierele".
/// Identical typography, badges, spacing, and status display in both sections.
/// Also reused on the parent dashboard's "Program săptămâna aceasta".
///
/// - Set [showDate] = true in the "all workshops" list to include the date.
/// - Set [isOwn] = true when the workshop belongs to the logged-in trainer.
/// - Pass [onTap] to make the card clickable (staff: navigate to the
///   workshop detail page; parent: leave null — parent has no RLS
///   access to the staff workshop pages, so the row stays read-only).
/// - Pass [customChildrenLabel] to override the default
///   "`{childrenCount} copii`" meta entry. The parent dashboard uses
///   this to list its own children attending the session, e.g.
///   "Sofia, Matei".
class DashboardWorkshopItem extends StatelessWidget {
  const DashboardWorkshopItem({
    super.key,
    required this.workshop,
    this.isOwn = false,
    this.showDate = false,
    this.onTap,
    this.customChildrenLabel,
  });

  final DashboardWorkshop workshop;
  final bool isOwn;
  final bool showDate;
  final VoidCallback? onTap;
  final String? customChildrenLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = resolveWorkshopCardStatus(
      workshopDate: workshop.workshopDate,
      startTime: workshop.startTime,
      endTime: workshop.endTime,
    );
    final (statusLabel, statusColor) = switch (status) {
      WorkshopCardStatus.ongoing => ('În desfășurare', AppColors.success),
      WorkshopCardStatus.upcoming => ('Programat', AppColors.info),
      WorkshopCardStatus.finished => ('Finalizat', theme.colorScheme.outline),
    };
    final (typeIcon, typeColor) = workshopTypeStyle(workshop.workshopType);

    final childrenLabel = customChildrenLabel ??
        ((workshop.childrenCount != null && workshop.childrenCount! > 0)
            ? '${workshop.childrenCount} copii'
            : null);

    final metaParts = [
      if (showDate) formatDate(workshop.workshopDate),
      '${formatTimeString(workshop.startTime)}–${formatTimeString(workshop.endTime)}',
      if (workshop.trainerName != null) workshop.trainerName!,
      if (childrenLabel != null && childrenLabel.isNotEmpty) childrenLabel,
    ];

    return Material(
      color: isOwn
          ? theme.colorScheme.primary.withValues(alpha: 0.06)
          : theme.cardTheme.color,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        // Falls back to navigating to the staff workshop detail page so
        // the existing staff callsites stay tap-through without an
        // explicit handler. Parent callsites pass `onTap: () {}` (or
        // omit and the tap goes nowhere — guarded by GoRouter's
        // role-redirect for the staff route anyway).
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isOwn
                  ? theme.colorScheme.primary.withValues(alpha: 0.4)
                  : theme.colorScheme.outline.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // ── Type icon ──────────────────────────────────────────────
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: typeColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(typeIcon, color: typeColor, size: 19),
              ),
              const SizedBox(width: 12),

              // ── Title + meta ───────────────────────────────────────────
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            workshop.title,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w600),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isOwn) ...[
                          const SizedBox(width: 6),
                          const WorkshopOwnBadge(),
                        ],
                      ],
                    ),
                    if (metaParts.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        metaParts.join(' · '),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 5),
                    // ── Day-of-week chip + status pill ──
                    //
                    // We replaced the redundant workshop-type chip
                    // (already conveyed by the icon on the left) with
                    // a day-of-week chip, more useful in "Toate
                    // atelierele" scanning. The "Programat" status is
                    // hidden because the day already implies future
                    // scheduling; only "În desfășurare" (live now) and
                    // "Finalizat" (past) render, since those carry
                    // information the day+time can't.
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.info.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: AppColors.info.withValues(alpha: 0.28)),
                          ),
                          child: Text(
                            workshop.dayOfWeek,
                            style: const TextStyle(
                              color: AppColors.info,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (status != WorkshopCardStatus.upcoming)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(
                              color: statusColor.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              statusLabel,
                              style: TextStyle(
                                color: statusColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

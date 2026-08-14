import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/date_utils.dart';
import '../../../core/utils/responsive.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../auth/providers/auth_providers.dart';
import '../../children/providers/children_providers.dart';
import '../data/workshops_repository.dart';
import '../domain/series_enrolled_child.dart';
import '../providers/enrollment_providers.dart';
import '../providers/workshops_providers.dart';
import 'widgets/workshop_children_list.dart';
import 'widgets/workshop_header_card.dart';

// ─────────────────────────────────────────────────────────────────────────────

class WorkshopDetailsPage extends ConsumerStatefulWidget {
  const WorkshopDetailsPage({super.key, required this.workshopId});

  final String workshopId;

  @override
  ConsumerState<WorkshopDetailsPage> createState() =>
      _WorkshopDetailsPageState();
}

class _WorkshopDetailsPageState extends ConsumerState<WorkshopDetailsPage> {
  // Tracks which childIds are currently being saved
  final Set<String> _marking = {};
  bool _markingAll = false;
  String? _listenedSeriesId;

  // Realtime for `attendance` and `workshop_enrollments` is handled centrally
  // by appRealtimeProvider. For enrollments, the central provider invalidates
  // seriesEnrolledChildrenProvider(seriesId) — but it cannot also invalidate
  // workshopDetailsProvider(workshopId) because the payload only carries
  // series_id. We bridge that gap below with a ref.listen on the enrolled
  // children provider; when it refreshes, we invalidate the details view.

  /// Admin-only **Cancel session** flow.
  ///
  /// Cancelling a session soft-archives just the single
  /// `scheduled_workshops` row — sets `archived_at = now()`,
  /// `archived_by = adminId`, `is_active = false`. Attendance and
  /// enrollment history are always preserved.
  ///
  /// Works both for one-off workshops and for a single occurrence of a
  /// recurring series (per rule 8). To cancel the whole recurring
  /// series, admins use the "Cancel entire series" action on the edit
  /// page.
  Future<void> _cancelSession() async {
    final profile = ref.read(currentProfileProvider).valueOrNull;
    final isAdmin = profile?.isAdmin ?? false;
    final adminId = profile?.id;
    if (!isAdmin || adminId == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Anulează sesiunea?'),
        content: const Text(
          'Sesiunea va fi anulată și eliminată din programul activ. '
          'Prezențele istorice și rapoartele copiilor se păstrează '
          'integral.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Renunță'),
          ),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Anulează sesiunea'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await ref.read(workshopsRepositoryProvider).cancelWorkshopOneOff(
            isAdmin: isAdmin,
            adminId: adminId,
            workshopId: widget.workshopId,
          );
      if (kDebugMode) debugPrint('[Workshop] session cancelled');
      // Realtime (rt:scheduled_workshops) invalidates the affected list
      // providers (workshopByIdProvider, allScheduledWorkshopsProvider,
      // todayWorkshopsProvider, workshopsListProvider,
      // dashboardStatsProvider) — no need to duplicate the invalidates
      // here.
      ref.invalidate(workshopDetailsProvider(widget.workshopId));
      await ref.read(workshopDetailsProvider(widget.workshopId).future);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sesiunea a fost anulată.')),
        );
        context.canPop() ? context.pop() : context.go('/dashboard');
      }
    } on WorkshopCancelBlockedException catch (e) {
      _showBlockedMessage(e);
      return;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Eroare: $e')));
      }
    }
  }

  void _showBlockedMessage(WorkshopCancelBlockedException e) {
    if (!mounted) return;
    final message = switch (e.reason) {
      WorkshopCancelBlockedReason.refusedByServer =>
        'Anularea nu a fost executată pe server (probabil permisiuni '
            'insuficiente sau o regulă RLS). Sesiunea nu a fost modificată.',
    };
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _mark(String childId, String status, String? observation) async {
    if (_marking.contains(childId)) return;
    setState(() => _marking.add(childId));
    try {
      final user = ref.read(currentUserProvider);
      final isStaff =
          ref.read(currentProfileProvider).valueOrNull?.isStaff ?? false;
      await ref.read(workshopsRepositoryProvider).markAttendance(
            isStaff: isStaff,
            workshopId: widget.workshopId,
            childId: childId,
            status: status,
            observation: observation,
            markedBy: user?.id ?? '',
          );
      // Await the details refresh so the row's button color reflects the new
      // attendance status before the spinner clears. Otherwise the button
      // briefly shows the previous status until the cached provider catches up.
      ref.invalidate(workshopDetailsProvider(widget.workshopId));
      await ref.read(workshopDetailsProvider(widget.workshopId).future);
      // allChildrenProvider is intentionally invalidated here because the
      // realtime rt:attendance handler SKIPS it when childId is present
      // (it uses targeted childByIdProvider instead). This is the only
      // refresh path for the children list's last-attendance pill.
      // weeklyAttendancesProvider and dashboardStatsProvider are covered
      // unconditionally by rt:attendance — no manual invalidate needed.
      ref.invalidate(allChildrenProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Eroare: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _marking.remove(childId));
    }
  }

  Future<void> _markAll(List<String> childIds) async {
    if (_markingAll || childIds.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Marchează toți prezenți'),
        content: const Text('Marchezi toți copiii ca prezenți?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Anulează'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirmă'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _markingAll = true);
    try {
      final user = ref.read(currentUserProvider);
      final isStaff =
          ref.read(currentProfileProvider).valueOrNull?.isStaff ?? false;
      await ref.read(workshopsRepositoryProvider).markAllPresent(
            isStaff: isStaff,
            workshopId: widget.workshopId,
            childIds: childIds,
            markedBy: user?.id ?? '',
          );
      // Await the details refresh so all rows show their new attendance
      // status before the "marking all" spinner clears.
      // allChildrenProvider stays — realtime rt:attendance skips it when
      // childId is in the payload. weeklyAttendancesProvider /
      // dashboardStatsProvider are covered by realtime unconditionally.
      ref.invalidate(workshopDetailsProvider(widget.workshopId));
      await ref.read(workshopDetailsProvider(widget.workshopId).future);
      if (kDebugMode) debugPrint('[Workshop] all present marked');
      ref.invalidate(allChildrenProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Toți copiii au fost marcați prezenți.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Eroare: $e')));
      }
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detailsAsync =
        ref.watch(workshopDetailsProvider(widget.workshopId));
    final profile = ref.watch(currentProfileProvider).valueOrNull;
    final isAdmin = profile?.isAdmin ?? false;
    final theme = Theme.of(context);

    // Remember which series this workshop belongs to so we know which
    // enrolled-children provider to listen on.
    final detailsRows = detailsAsync.valueOrNull;
    if (detailsRows != null && detailsRows.isNotEmpty) {
      _listenedSeriesId = detailsRows.first.seriesId;
    }

    // Central appRealtimeProvider invalidates seriesEnrolledChildrenProvider
    // for the affected series, but it cannot know which scheduled_workshop_id
    // belongs to this view — workshop_enrollments rows only carry series_id.
    // Bridge that gap: whenever the enrolled-children list refreshes for our
    // series, also invalidate this workshop's details provider so the join
    // re-runs and shows the new roster.
    if (_listenedSeriesId != null) {
      ref.listen<AsyncValue<List<SeriesEnrolledChild>>>(
        seriesEnrolledChildrenProvider(_listenedSeriesId!),
        (_, _) {
          if (mounted) {
            ref.invalidate(workshopDetailsProvider(widget.workshopId));
          }
        },
      );
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/dashboard'),
        ),
        title: const Text('Detalii atelier'),
        actions: [
          if (isAdmin)
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'edit') {
                  context.go('/workshops/${widget.workshopId}/edit');
                } else if (value == 'cancel') {
                  _cancelSession();
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    leading: Icon(Icons.edit_outlined),
                    title: Text('Editează sesiunea'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ),
                const PopupMenuItem(
                  value: 'cancel',
                  child: ListTile(
                    leading: Icon(Icons.cancel_outlined,
                        color: AppColors.error),
                    title: Text('Anulează sesiunea',
                        style: TextStyle(color: AppColors.error)),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  ),
                ),
              ],
            ),
        ],
      ),
      body: detailsAsync.when(
        skipLoadingOnReload: true,
        loading: () => const AppLoading(),
        error: (e, _) => Center(child: AppError(message: e.toString())),
        data: (rows) {
          if (rows.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.event_outlined,
                      size: 48, color: theme.colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(
                    'Nu există date pentru acest atelier.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.outline),
                  ),
                ],
              ),
            );
          }

          final first = rows.first;

          // Date restriction: can only mark on or after the workshop date
          final today = DateTime.now();
          final todayDate =
              DateTime(today.year, today.month, today.day);
          final workshopDay = DateTime(
            first.workshopDate.year,
            first.workshopDate.month,
            first.workshopDate.day,
          );
          final canMarkByDate = !todayDate.isBefore(workshopDay);

          // Role-based permission
          final hasRole = isAdmin ||
              (profile?.isTrainer == true &&
                  profile!.id == first.trainerId);
          final canMark = canMarkByDate && hasRole;
          final enrolled =
              rows.where((r) => r.childId != null).toList();

          return SingleChildScrollView(
            padding: context.mobilePadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WorkshopHeaderCard(row: first),
                // Banner when workshop is in the future
                if (hasRole && !canMarkByDate) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.warning.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color:
                              AppColors.warning.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_clock_outlined,
                            size: 16, color: AppColors.warning),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Prezența poate fi marcată începând cu ziua atelierului (${formatDate(first.workshopDate)}).',
                            style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.warning,
                                fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                WorkshopChildrenList(
                  workshopId: widget.workshopId,
                  enrolled: enrolled,
                  marking: _marking,
                  canMark: canMark,
                  onMark: _mark,
                  onChildTap: (childId) =>
                      context.push('/children/$childId'),
                  isAdmin: isAdmin,
                  seriesId: first.seriesId,
                  onEnrolled: () {
                    // Keep this invalidate: realtime reaches
                    // workshopDetailsProvider only via the
                    // `seriesEnrolledChildrenProvider` → ref.listen
                    // bridge defined above, which adds 50–200 ms of
                    // latency. The user just clicked "add" — refresh
                    // the roster immediately. allChildrenProvider is
                    // already covered by rt:workshop_enrollments.
                    ref.invalidate(
                        workshopDetailsProvider(widget.workshopId));
                    if (kDebugMode) {
                      debugPrint(
                          '[Workshop] enrollment done, details refreshed');
                    }
                  },
                  markingAll: _markingAll,
                  onMarkAll: canMark && enrolled.isNotEmpty
                      ? () => _markAll(
                            enrolled
                                .map((r) => r.childId!)
                                .toList(),
                          )
                      : null,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}


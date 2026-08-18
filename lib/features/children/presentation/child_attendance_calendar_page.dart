import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../auth/domain/app_profile.dart';
import '../../auth/providers/auth_providers.dart';
import '../domain/child_calendar_session.dart';
import '../providers/attendance_calendar_providers.dart';
import '../providers/child_details_providers.dart';
import 'widgets/attendance_calendar_grid.dart';
import 'widgets/attendance_session_editor.dart';
import 'widgets/missing_attendance_list.dart';

/// Compact modal calendar for a single child's historical attendance.
///
/// Sized ~700×620 on desktop; near-full on mobile. Two tabs: monthly
/// calendar + "Prezențe necompletate". The modal stays open between saves
/// so the user can quickly repair a whole streak of forgotten sessions.
///
/// Since migration `20260817_chronological_payment_cycles.sql`, payment
/// cycles are recomputed chronologically server-side on every attendance
/// mutation — no client-side lock is applied here.
class ChildAttendanceCalendarModal extends ConsumerStatefulWidget {
  const ChildAttendanceCalendarModal({super.key, required this.childId});
  final String childId;

  /// Opens the modal on both mobile and desktop. On desktop it's a
  /// centered dialog (~720×640). On mobile it's a near-full sheet with a
  /// safe-area padded top.
  static Future<void> show(BuildContext context, {required String childId}) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 600;
    if (isMobile) {
      return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.94,
        ),
        builder: (_) => ChildAttendanceCalendarModal(childId: childId),
      );
    }
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 720,
            maxHeight: 640,
          ),
          child: SizedBox(
            width: 720,
            height: 640,
            child: ChildAttendanceCalendarModal(childId: childId),
          ),
        ),
      ),
    );
  }

  @override
  ConsumerState<ChildAttendanceCalendarModal> createState() =>
      _ChildAttendanceCalendarModalState();
}

class _ChildAttendanceCalendarModalState
    extends ConsumerState<ChildAttendanceCalendarModal>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  late DateTime _month;
  DateTime? _selectedDate;
  final Set<String> _busyWorkshopIds = {};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    final now = DateTime.now();
    _month = DateTime(now.year, now.month, 1);
    // Ensure every recurring series the child is enrolled in has all its
    // historical weekly sessions materialised. Idempotent — no-op when
    // everything is already in place. Runs once per modal open.
    WidgetsBinding.instance.addPostFrameCallback((_) => _runBackfill());
  }

  Future<void> _runBackfill() async {
    try {
      final inserted = await ref
          .read(attendanceCalendarRepositoryProvider)
          .ensureBackfilled(widget.childId);
      if (inserted > 0 && mounted) {
        // New scheduled_workshops rows now exist — refresh so they appear
        // in the calendar / missing list immediately.
        _invalidateAllProvidersForThisChild();
      }
    } catch (_) {
      // Non-fatal: the calendar still works with existing sessions.
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _prevMonth() {
    setState(() {
      _month = DateTime(_month.year, _month.month - 1, 1);
      _selectedDate = null;
    });
  }

  void _nextMonth() {
    setState(() {
      _month = DateTime(_month.year, _month.month + 1, 1);
      _selectedDate = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final childAsync = ref.watch(childByIdProvider(widget.childId));

    return Material(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        children: [
          _ModalHeader(
            childAsync: childAsync,
            onClose: () => Navigator.of(context).pop(),
          ),
          Container(
            color: theme.scaffoldBackgroundColor,
            child: TabBar(
              controller: _tabs,
              labelColor: AppColors.purple,
              unselectedLabelColor: AppColors.muted,
              indicatorColor: AppColors.purple,
              tabs: const [
                Tab(text: 'Calendar', icon: Icon(Icons.calendar_month_rounded)),
                Tab(text: 'Necompletate', icon: Icon(Icons.event_busy_rounded)),
              ],
            ),
          ),
          Expanded(
            child: childAsync.when(
              loading: () => const AppLoading(),
              error: (e, _) => Center(child: AppError(message: e.toString())),
              data: (child) {
                if (child == null) {
                  return const Center(
                      child: Text('Copilul nu a fost găsit.'));
                }
                return TabBarView(
                  controller: _tabs,
                  children: [
                    _buildCalendarTab(context),
                    _buildMissingTab(context),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Calendar tab ────────────────────────────────────────────────────────

  Widget _buildCalendarTab(BuildContext context) {
    final key = CalendarMonthKey(
      childId: widget.childId,
      year: _month.year,
      month: _month.month,
    );
    final async = ref.watch(childCalendarMonthProvider(key));

    return async.when(
      loading: () => const AppLoading(),
      error: (e, _) => Center(child: AppError(message: e.toString())),
      data: (sessions) {
        final byDate = _groupByDate(sessions);
        final selectedSessions = _selectedDate == null
            ? const <ChildCalendarSession>[]
            : (byDate[DateTime(_selectedDate!.year, _selectedDate!.month,
                    _selectedDate!.day)] ??
                const []);
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _MonthHeader(
                month: _month,
                onPrev: _prevMonth,
                onNext: _nextMonth,
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: _sectionDecoration(context),
                child: AttendanceCalendarGrid(
                  month: _month,
                  sessionsByDate: byDate,
                  selectedDate: _selectedDate,
                  onDaySelected: (d) {
                    setState(() => _selectedDate = d);
                    final sess = byDate[DateTime(d.year, d.month, d.day)] ??
                        const [];
                    if (sess.length == 1) {
                      _openEditor(sess.first);
                    }
                  },
                ),
              ),
              const SizedBox(height: 12),
              _Legend(),
              if (_selectedDate != null) ...[
                const SizedBox(height: 12),
                _SelectedDayPanel(
                  date: _selectedDate!,
                  sessions: selectedSessions,
                  onTapSession: _openEditor,
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  // ── Missing tab ────────────────────────────────────────────────────────

  Widget _buildMissingTab(BuildContext context) {
    final async =
        ref.watch(childMissingAttendanceProvider(widget.childId));
    return async.when(
      loading: () => const AppLoading(),
      error: (e, _) => Center(child: AppError(message: e.toString())),
      data: (sessions) {
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Sesiuni recente fără prezență marcată',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Include ultimele 6 luni pentru atelierele la care copilul '
                'este înscris în prezent.',
                style: TextStyle(
                  color: AppColors.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              MissingAttendanceList(
                sessions: sessions,
                busyWorkshopIds: _busyWorkshopIds,
                onMark: _markInline,
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Actions ────────────────────────────────────────────────────────────

  Future<void> _openEditor(ChildCalendarSession s) async {
    final profile = ref.read(currentProfileProvider).valueOrNull;
    if (profile == null) return;
    final canEdit = profile.isStaff && _canEditWorkshop(s, profile);
    if (!canEdit) {
      _showReadOnly(s);
      return;
    }
    // Delete requires an existing attendance row + the same
    // "canEditWorkshop" rule used for Prezent/Absent: admin (any) or
    // trainer of THIS workshop. RLS
    // (`attendance_delete_admin_or_trainer`) re-enforces on the server
    // since migration 20260823.
    final canDelete = s.hasAttendance && canEdit;
    await AttendanceSessionEditor.show(
      context,
      session: s,
      onSave: (status, obs) => _submit(s, status, obs),
      onDelete: canDelete ? () => _deleteAttendance(s) : null,
    );
  }

  Future<void> _deleteAttendance(ChildCalendarSession s) async {
    final profile = ref.read(currentProfileProvider).valueOrNull;
    if (profile == null || !profile.isStaff) return;
    // Extra defence: refuse if a trainer somehow reaches this code path
    // for a workshop they don't own. RLS would reject it anyway, but
    // failing early gives a nicer user message.
    if (!_canEditWorkshop(s, profile)) return;
    final attendanceId = s.attendanceId;
    if (attendanceId == null) return;
    try {
      await ref
          .read(attendanceCalendarRepositoryProvider)
          .deleteAttendance(
            attendanceId: attendanceId,
            isStaff: profile.isStaff,
          );
      _invalidateAllProvidersForThisChild();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Prezența a fost ștearsă.'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nu s-a putut șterge prezența: $e'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _submit(
    ChildCalendarSession s,
    String status,
    String? observation,
  ) async {
    final profile = ref.read(currentProfileProvider).valueOrNull;
    if (profile == null) return;
    try {
      await ref
          .read(attendanceCalendarRepositoryProvider)
          .upsertAttendance(
            childId: widget.childId,
            scheduledWorkshopId: s.scheduledWorkshopId,
            status: status,
            observation: observation,
            markedBy: profile.id,
            isStaff: profile.isStaff,
          );
      _invalidateAllProvidersForThisChild();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Prezența a fost salvată.'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nu s-a putut salva prezența: $e'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  Future<void> _markInline(
      ChildCalendarSession s, String status) async {
    final profile = ref.read(currentProfileProvider).valueOrNull;
    if (profile == null) return;
    if (!_canEditWorkshop(s, profile)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nu ai permisiuni pentru acest atelier.'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
    setState(() => _busyWorkshopIds.add(s.scheduledWorkshopId));
    try {
      await ref
          .read(attendanceCalendarRepositoryProvider)
          .upsertAttendance(
            childId: widget.childId,
            scheduledWorkshopId: s.scheduledWorkshopId,
            status: status,
            observation: null,
            markedBy: profile.id,
            isStaff: profile.isStaff,
          );
      _invalidateAllProvidersForThisChild();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Eroare: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _busyWorkshopIds.remove(s.scheduledWorkshopId));
      }
    }
  }

  void _showReadOnly(ChildCalendarSession s) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(s.workshopTitle.isEmpty ? 'Sesiune' : s.workshopTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${s.workshopDate.day}.${s.workshopDate.month.toString().padLeft(2, '0')}'
              '.${s.workshopDate.year} • '
              '${s.startTimeShort}–${s.endTimeShort}',
              style: const TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 8),
            Text('Status: ${_labelFor(s.status)}'),
            if (s.markedByName != null)
              Text('Marcat de: ${s.markedByName}'),
            if (s.observation != null && s.observation!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Observație: ${s.observation}'),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Închide'),
          ),
        ],
      ),
    );
  }

  String _labelFor(String? status) => switch (status) {
        'present' => 'Prezent',
        'absent' => 'Absent',
        'motivated' => 'Motivat',
        _ => 'Nemarcat',
      };

  bool _canEditWorkshop(ChildCalendarSession s, AppProfile profile) {
    if (profile.isAdmin) return true;
    if (profile.isTrainer &&
        s.trainerId != null &&
        s.trainerId == profile.id) {
      return true;
    }
    return false;
  }

  void _invalidateAllProvidersForThisChild() {
    for (int m = -1; m <= 1; m++) {
      final target = DateTime(_month.year, _month.month + m, 1);
      ref.invalidate(childCalendarMonthProvider(CalendarMonthKey(
        childId: widget.childId,
        year: target.year,
        month: target.month,
      )));
    }
    ref.invalidate(childMissingAttendanceProvider(widget.childId));
  }

  Map<DateTime, List<ChildCalendarSession>> _groupByDate(
      List<ChildCalendarSession> sessions) {
    final map = <DateTime, List<ChildCalendarSession>>{};
    for (final s in sessions) {
      final key = DateTime(
          s.workshopDate.year, s.workshopDate.month, s.workshopDate.day);
      (map[key] ??= []).add(s);
    }
    return map;
  }

  BoxDecoration _sectionDecoration(BuildContext context) {
    final theme = Theme.of(context);
    return BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: theme.colorScheme.outline.withValues(alpha: 0.25),
      ),
    );
  }
}

// ── Wrapper page for direct-URL deep links (e.g. legacy bookmarks) ─────
//
// The primary trigger for the calendar is now the modal opened by the
// AppBar action on ChildDetailsPage. This page is kept so that a
// bookmarked `/children/:id/attendance-calendar` URL still works — it
// renders a full-screen scaffold containing the same modal body.

class ChildAttendanceCalendarPage extends StatelessWidget {
  const ChildAttendanceCalendarPage({super.key, required this.childId});
  final String childId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => context.canPop()
              ? context.pop()
              : context.go('/children/$childId'),
        ),
        title: const Text('Calendar prezențe'),
      ),
      body: ChildAttendanceCalendarModal(childId: childId),
    );
  }
}

// ── Sub-widgets ─────────────────────────────────────────────────────────

class _ModalHeader extends StatelessWidget {
  const _ModalHeader({required this.childAsync, required this.onClose});
  final AsyncValue childAsync;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final childName = childAsync.valueOrNull?.fullName as String? ?? '';
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outline.withValues(alpha: 0.15),
          ),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.calendar_month_rounded,
              color: AppColors.purple, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Calendar prezențe',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (childName.isNotEmpty)
                  Text(
                    childName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            tooltip: 'Închide',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  const _MonthHeader({
    required this.month,
    required this.onPrev,
    required this.onNext,
  });

  final DateTime month;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  static const _romMonths = [
    '', 'Ianuarie', 'Februarie', 'Martie', 'Aprilie', 'Mai', 'Iunie',
    'Iulie', 'August', 'Septembrie', 'Octombrie', 'Noiembrie', 'Decembrie',
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: onPrev,
          icon: const Icon(Icons.chevron_left_rounded),
          tooltip: 'Luna anterioară',
        ),
        Expanded(
          child: Center(
            child: Text(
              '${_romMonths[month.month]} ${month.year}',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
        ),
        IconButton(
          onPressed: onNext,
          icon: const Icon(Icons.chevron_right_rounded),
          tooltip: 'Luna următoare',
        ),
      ],
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    Widget item(Color c, IconData icon, String label) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              color: c.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: c),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 10, color: c),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.muted,
              )),
        ],
      );
    }

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        item(AppColors.success, Icons.check_rounded, 'Prezent'),
        item(AppColors.error, Icons.close_rounded, 'Absent'),
        item(AppColors.info, Icons.circle_outlined, 'Nemarcat'),
        item(AppColors.warning, Icons.horizontal_rule_rounded, 'Mixt'),
      ],
    );
  }
}

class _SelectedDayPanel extends StatelessWidget {
  const _SelectedDayPanel({
    required this.date,
    required this.sessions,
    required this.onTapSession,
  });

  final DateTime date;
  final List<ChildCalendarSession> sessions;
  final ValueChanged<ChildCalendarSession> onTapSession;

  static const _months = [
    '', 'ianuarie', 'februarie', 'martie', 'aprilie', 'mai', 'iunie',
    'iulie', 'august', 'septembrie', 'octombrie', 'noiembrie', 'decembrie',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${date.day} ${_months[date.month]} ${date.year}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          if (sessions.isEmpty)
            const Text(
              'Nicio sesiune înregistrată pentru această zi.',
              style: TextStyle(color: AppColors.muted),
            )
          else
            for (final s in sessions)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _SessionRow(session: s, onTap: () => onTapSession(s)),
              ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({required this.session, required this.onTap});
  final ChildCalendarSession session;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (badgeColor, badgeLabel) = switch (session.status) {
      'present' => (AppColors.success, 'Prezent'),
      'absent' => (AppColors.error, 'Absent'),
      'motivated' => (AppColors.warning, 'Motivat'),
      _ => (AppColors.info, 'Nemarcat'),
    };
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.borderLight),
        ),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 32,
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${session.startTimeShort}–${session.endTimeShort} • '
                    '${session.workshopTitle}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    badgeLabel,
                    style: TextStyle(
                      color: badgeColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
          ],
        ),
      ),
    );
  }
}

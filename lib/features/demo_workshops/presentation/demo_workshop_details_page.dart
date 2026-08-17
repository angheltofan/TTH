import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/date_utils.dart';
import '../../../core/widgets/error_state.dart';
import '../../../core/widgets/loading_state.dart';
import '../../auth/providers/auth_providers.dart';
import '../../children/providers/child_details_providers.dart';
import '../../children/providers/children_providers.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../workshops/providers/enrollment_providers.dart';
import '../domain/demo_workshop.dart';
import '../providers/demo_workshops_providers.dart';

// ── DemoWorkshopDetailsPage ───────────────────────────────────────────────────

class DemoWorkshopDetailsPage extends ConsumerStatefulWidget {
  const DemoWorkshopDetailsPage({super.key, required this.demoId});
  final String demoId;

  @override
  ConsumerState<DemoWorkshopDetailsPage> createState() =>
      _DemoWorkshopDetailsPageState();
}

class _DemoWorkshopDetailsPageState
    extends ConsumerState<DemoWorkshopDetailsPage> {
  bool _busy = false;

  Future<void> _setStatus(String status, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(label),
        content: Text('Confirmi modificarea statusului la "$label"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Anulează')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirmă')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(demoWorkshopsRepositoryProvider)
          .updateStatus(widget.demoId, status);
      // Manual invalidations removed: appRealtimeProvider's
      // `rt:demo_workshops` channel already invalidates
      // demoWorkshopByIdProvider, todayDemoWorkshopsProvider and
      // dashboardStatsProvider on the same row change — duplicating
      // them here fired six refetches per status update.
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Eroare: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _convert(DemoWorkshop demo) async {
    final repo = ref.read(demoWorkshopsRepositoryProvider);

    // Step 1: look for an existing child matching name + phone.
    final existing = await repo.findExistingChild(
      firstName: demo.childFirstName,
      lastName: demo.childLastName,
      phone: demo.parentPhone,
    );

    if (!mounted) return;

    String? existingChildId;

    if (existing != null) {
      final link = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Copil existent găsit'),
          content: Text(
              'Există deja un copil cu numele "${existing['first_name']} ${existing['last_name']}" '
              'și telefonul ${existing['parent_phone'] ?? '—'}.\n\n'
              'Vrei să legi demo-ul de acest copil existent?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Creează copil nou')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Folosește existent')),
          ],
        ),
      );
      if (!mounted) return;
      if (link == true) {
        existingChildId = existing['id'] as String;
      }
    }

    // Step 2: pick workshop series.
    if (!mounted) return;
    final seriesId = await showDialog<String>(
      context: context,
      builder: (ctx) => _SelectSeriesDialog(demoType: demo.workshopType),
    );
    if (seriesId == null || !mounted) return;

    // Step 3: single atomic RPC call.
    // The RPC creates the child (if needed), upserts the enrollment, and
    // flips the demo to status='converted' in one transaction. Idempotent
    // re-call returns enrollmentCreated=false.
    setState(() => _busy = true);
    try {
      final result = await repo.convertDemoToEnrollment(
        demoId: widget.demoId,
        seriesId: seriesId,
        existingChildId: existingChildId,
      );
      final childId = result.childId;

      ref.invalidate(demoWorkshopByIdProvider(widget.demoId));
      ref.invalidate(todayDemoWorkshopsProvider);
      ref.invalidate(allChildrenProvider);
      ref.invalidate(dashboardStatsProvider);
      ref.invalidate(activeWorkshopSeriesProvider);
      ref.invalidate(seriesEnrolledChildrenProvider(seriesId));
      ref.invalidate(availableChildrenForSeriesProvider(seriesId));
      ref.invalidate(childWorkshopSeriesProvider(childId));
      ref.invalidate(childByIdProvider(childId));
      ref.invalidate(childCurrentStatusRowsProvider(childId));

      if (mounted) {
        final msg = result.enrollmentCreated
            ? 'Copilul a fost înscris cu succes.'
            : 'Demo-ul este deja convertit.';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Eroare: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final demoAsync = ref.watch(demoWorkshopByIdProvider(widget.demoId));
    final profile = ref.watch(currentProfileProvider).valueOrNull;
    final isAdmin = profile?.isAdmin ?? false;
    final theme = Theme.of(context);

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
        title: const Text('Demo atelier'),
      ),
      body: demoAsync.when(
        loading: () => const AppLoading(),
        error: (e, _) => Center(child: AppError(message: e.toString())),
        data: (demo) {
          if (demo == null) {
            return const Center(child: Text('Demo-ul nu a fost găsit.'));
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DemoInfoCard(demo: demo),
                const SizedBox(height: 20),
                if (isAdmin && demo.isScheduled) ...[
                  _AdminActionsCard(
                    demo: demo,
                    busy: _busy,
                    onMarkCompleted: () =>
                        _setStatus('completed', 'Finalizat'),
                    onMarkNoShow: () =>
                        _setStatus('no_show', 'Absent'),
                    onCancel: () => _setStatus('cancelled', 'Anulat'),
                    onConvert: () => _convert(demo),
                  ),
                ],
                if (!demo.isScheduled)
                  _StatusBanner(status: demo.status),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ── Info card ─────────────────────────────────────────────────────────────────

class _DemoInfoCard extends StatelessWidget {
  const _DemoInfoCard({required this.demo});
  final DemoWorkshop demo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget row(IconData icon, String label, String? value) {
      if (value == null || value.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon,
                size: 16, color: theme.colorScheme.outline),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                  Text(value,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.35)),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  demo.childFullName,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              _DemoBadge(),
              const SizedBox(width: 8),
              _StatusChip(status: demo.status),
            ],
          ),
          const SizedBox(height: 14),
          row(Icons.person_outline, 'Nume părinte', demo.parentName),
          row(Icons.phone_outlined, 'Telefon', demo.parentPhone),
          row(Icons.email_outlined, 'Email', demo.parentEmail),
          row(Icons.calendar_today_outlined, 'Dată',
              formatDate(demo.demoDate)),
          row(Icons.access_time_outlined, 'Oră',
              '${formatTimeString(demo.startTime)} – ${formatTimeString(demo.endTime)}'),
          row(Icons.category_outlined, 'Tip atelier', demo.workshopType),
          row(Icons.event_outlined, 'Titlu atelier', demo.workshopTitle),
          row(Icons.person_pin_outlined, 'Trainer', demo.trainerName),
          row(Icons.notes_outlined, 'Note', demo.notes),
        ],
      ),
    );
  }
}

// ── Admin actions card ────────────────────────────────────────────────────────

class _AdminActionsCard extends StatelessWidget {
  const _AdminActionsCard({
    required this.demo,
    required this.busy,
    required this.onMarkCompleted,
    required this.onMarkNoShow,
    required this.onCancel,
    required this.onConvert,
  });
  final DemoWorkshop demo;
  final bool busy;
  final VoidCallback onMarkCompleted;
  final VoidCallback onMarkNoShow;
  final VoidCallback onCancel;
  final VoidCallback onConvert;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: onConvert,
          icon: const Icon(Icons.how_to_reg_rounded),
          label: const Text('Înscrie definitiv'),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.success,
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: onMarkCompleted,
                child: const Text('Finalizat'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: onMarkNoShow,
                child: const Text('Absent'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: onCancel,
                style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.error),
                child: const Text('Anulează'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ── Status banner shown when demo is no longer scheduled ─────────────────────

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'completed' => ('Finalizat', AppColors.success),
      'no_show' => ('Absent', AppColors.warning),
      'cancelled' => ('Anulat', AppColors.error),
      'converted' => ('Înscris definitiv', AppColors.purple),
      _ => (status, AppColors.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, color: color, size: 18),
          const SizedBox(width: 10),
          Text(
            'Status: $label',
            style: TextStyle(
                color: color, fontWeight: FontWeight.w600, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

// ── Small badge / chip widgets ────────────────────────────────────────────────

class _DemoBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.demoBadge.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        'DEMO',
        style: TextStyle(
          color: AppColors.demoBadge,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'scheduled' => ('Programat', AppColors.info),
      'completed' => ('Finalizat', AppColors.success),
      'no_show' => ('Absent', AppColors.warning),
      'cancelled' => ('Anulat', AppColors.error),
      'converted' => ('Înscris', AppColors.purple),
      _ => (status, AppColors.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

// ── Select series dialog ──────────────────────────────────────────────────────

class _SelectSeriesDialog extends ConsumerWidget {
  const _SelectSeriesDialog({required this.demoType});
  final String demoType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seriesAsync = ref.watch(activeWorkshopSeriesProvider);

    return AlertDialog(
      title: const Text('Selectează seria'),
      content: SizedBox(
        width: 340,
        child: seriesAsync.when(
          loading: () => const SizedBox(
              height: 80,
              child: Center(
                  child: CircularProgressIndicator(strokeWidth: 2))),
          error: (e, _) => Text('Eroare: $e'),
          data: (seriesList) {
            if (seriesList.isEmpty) {
              return const Text(
                  'Nu există serii active disponibile.');
            }
            // Prefer series whose workshop_type matches the demo's type.
            // Fall back to the full list if none match so the admin is never
            // locked out of completing the conversion.
            final demoTypeLower = demoType.trim().toLowerCase();
            final matching = demoTypeLower.isEmpty
                ? seriesList
                : seriesList
                    .where((s) =>
                        (s.workshopType ?? '').trim().toLowerCase() ==
                        demoTypeLower)
                    .toList();
            final visible =
                matching.isNotEmpty ? matching : seriesList;

            return ListView.separated(
              shrinkWrap: true,
              itemCount: visible.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1),
              itemBuilder: (context, i) {
                final s = visible[i];
                return ListTile(
                  title: Text(s.title),
                  subtitle: s.dayOfWeek != null
                      ? Text('${s.dayOfWeek} · ${s.startTime.substring(0, 5)}')
                      : null,
                  onTap: () => Navigator.pop(context, s.id),
                  dense: true,
                );
              },
            );
          },
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Anulează')),
      ],
    );
  }
}

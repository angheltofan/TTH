import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../supabase/supabase_client_provider.dart';
import '../../features/auth/providers/auth_providers.dart';
import '../../features/children/providers/attendance_calendar_providers.dart';
import '../../features/children/providers/child_details_providers.dart';
import '../../features/children/providers/children_providers.dart';
import '../../features/dashboard/providers/dashboard_providers.dart';
import '../../features/demo_workshops/providers/demo_workshops_providers.dart';
import '../../features/notifications/providers/notifications_providers.dart';
import '../../features/payments_due/providers/payments_due_providers.dart';
import '../../features/workshops/providers/enrollment_providers.dart';
import '../../features/workshops/providers/workshops_providers.dart';

// ── Payload helpers ───────────────────────────────────────────────────────────

/// Returns the primary record from a Realtime payload:
/// newRecord for INSERT/UPDATE, oldRecord for DELETE.
Map<String, dynamic> _primaryRecord(PostgresChangePayload p) =>
    p.newRecord.isNotEmpty ? p.newRecord : p.oldRecord;

/// Extracts a String field from a payload record, returning null if absent.
String? _str(Map<String, dynamic> record, String key) {
  final v = record[key];
  return v is String ? v : null;
}

// ── Provider ──────────────────────────────────────────────────────────────────

/// Centralized Supabase Realtime sync provider.
///
/// - Watched by [AppShell] while any authenticated staff user is active.
/// - Gates on admin/trainer role — no channels created for unauthenticated or
///   non-staff users.
/// - Creates one Supabase channel per table.
/// - Disposes all channels on logout (profile changes to null or non-staff).
/// - Complements local invalidations (does not replace them).
final appRealtimeProvider = Provider.autoDispose<void>((ref) {
  final profile = ref.watch(currentProfileProvider).valueOrNull;

  // Gate: only activate for authenticated staff users.
  if (profile == null || (!profile.isAdmin && !profile.isTrainer)) return;

  final client = ref.watch(supabaseClientProvider);
  if (kDebugMode) debugPrint('[RT] appRealtime: subscribing all channels');

  // ── 1. attendance ─────────────────────────────────────────────────────────
  //
  // When attendance changes on any device, update the workshop detail view,
  // child status, dashboard stats and weekly attendance counter.
  //
  // Invalidation policy:
  //   - dashboardStatsProvider, todayWorkshopsProvider, weeklyAttendancesProvider
  //     are always invalidated (dashboard depends on aggregate counts).
  //   - When childId is present, we invalidate just that child's providers
  //     (incl. childByIdProvider) and skip allChildrenProvider — the children
  //     list's last-attendance pill may be briefly stale, accepted in Phase 2.
  //   - When childId is null (rare), fall back to invalidating allChildrenProvider.
  final attChannel = client
      .channel('rt:attendance')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'attendance',
        callback: (payload) {
          final rec = _primaryRecord(payload);
          final wsId = _str(rec, 'scheduled_workshop_id');
          final childId = _str(rec, 'child_id');
          if (kDebugMode) {
            debugPrint(
              '[RT] attendance → ${payload.eventType} '
              'wsId=$wsId childId=$childId',
            );
          }
          // Aggregate / dashboard-facing providers (always).
          ref.invalidate(dashboardStatsProvider);
          ref.invalidate(todayWorkshopsProvider);
          ref.invalidate(weeklyAttendancesProvider);
          if (kDebugMode) {
            debugPrint(
              '[RT] attendance: invalidated dashboardStats, '
              'todayWorkshops, weeklyAttendances',
            );
          }
          // Targeted invalidations using IDs from the payload.
          if (wsId != null) {
            ref.invalidate(workshopDetailsProvider(wsId));
            if (kDebugMode) {
              debugPrint('[RT] attendance: workshopDetailsProvider($wsId) invalidated');
            }
          }
          if (childId != null) {
            ref.invalidate(childByIdProvider(childId));
            ref.invalidate(childCurrentStatusProvider(childId));
            ref.invalidate(childCurrentStatusRowsProvider(childId));
            ref.invalidate(childPaymentStatusRowsProvider(childId));
            ref.invalidate(childMissingAttendanceProvider(childId));
            // The calendar-month provider is a keyed family (year+month).
            // We cannot invalidate a specific key without knowing the
            // workshop's date, so refresh all currently-mounted variants
            // for this child.
            ref.invalidate(childCalendarMonthProvider);
            if (kDebugMode) {
              debugPrint(
                '[RT] attendance: child providers($childId) invalidated '
                '(childById, currentStatus, currentStatusRows, paymentStatusRows, '
                'missingAttendance, calendarMonth)',
              );
            }
          } else {
            // Fallback: childId unknown, refresh the whole list so the
            // last-attendance pill stays consistent.
            ref.invalidate(allChildrenProvider);
            if (kDebugMode) {
              debugPrint(
                '[RT] attendance: childId null → fell back to allChildrenProvider',
              );
            }
          }
        },
      )
      .subscribe((status, [err]) {
        if (kDebugMode) debugPrint('[RT] rt:attendance → $status');
      });

  // ── 2. scheduled_workshops ────────────────────────────────────────────────
  //
  // Keeps workshop lists and dashboard in sync across devices.
  final swChannel = client
      .channel('rt:scheduled_workshops')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'scheduled_workshops',
        callback: (payload) {
          final rec = _primaryRecord(payload);
          final id = _str(rec, 'id');
          if (kDebugMode) {
            debugPrint(
              '[RT] scheduled_workshops → ${payload.eventType} id=$id',
            );
          }
          ref.invalidate(todayWorkshopsProvider);
          ref.invalidate(allScheduledWorkshopsProvider);
          ref.invalidate(workshopsListProvider);
          ref.invalidate(dashboardStatsProvider);
          if (id != null) {
            ref.invalidate(workshopByIdProvider(id));
            ref.invalidate(workshopDetailsProvider(id));
            if (kDebugMode) {
              debugPrint('[RT] scheduled_workshops: workshop providers($id) invalidated');
            }
          }
        },
      )
      .subscribe((status, [err]) {
        if (kDebugMode) debugPrint('[RT] rt:scheduled_workshops → $status');
      });

  // ── 3. workshop_series ────────────────────────────────────────────────────
  //
  // Keeps series lists in sync when a series is created, updated or deactivated.
  final seriesChannel = client
      .channel('rt:workshop_series')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'workshop_series',
        callback: (payload) {
          final rec = _primaryRecord(payload);
          final id = _str(rec, 'id');
          if (kDebugMode) {
            debugPrint(
              '[RT] workshop_series → ${payload.eventType} id=$id',
            );
          }
          ref.invalidate(activeWorkshopSeriesProvider);
          ref.invalidate(activeSeriesForDemoProvider);
          if (id != null) {
            ref.invalidate(workshopSeriesByIdProvider(id));
            if (kDebugMode) {
              debugPrint('[RT] workshop_series: workshopSeriesByIdProvider($id) invalidated');
            }
          }
        },
      )
      .subscribe((status, [err]) {
        if (kDebugMode) debugPrint('[RT] rt:workshop_series → $status');
      });

  // ── 4. workshop_enrollments ───────────────────────────────────────────────
  //
  // When a child is enrolled or removed from a series on another device,
  // update the series children list, child workshop list and children page.
  final enrollChannel = client
      .channel('rt:workshop_enrollments')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'workshop_enrollments',
        callback: (payload) {
          final rec = _primaryRecord(payload);
          final seriesId = _str(rec, 'series_id');
          final childId = _str(rec, 'child_id');
          if (kDebugMode) {
            debugPrint(
              '[RT] workshop_enrollments → ${payload.eventType} '
              'seriesId=$seriesId childId=$childId',
            );
          }
          ref.invalidate(activeWorkshopSeriesProvider);
          ref.invalidate(allChildrenProvider);
          if (seriesId != null) {
            ref.invalidate(seriesEnrolledChildrenProvider(seriesId));
            ref.invalidate(availableChildrenForSeriesProvider(seriesId));
            ref.invalidate(workshopSeriesByIdProvider(seriesId));
            if (kDebugMode) {
              debugPrint('[RT] workshop_enrollments: series providers($seriesId) invalidated');
            }
          }
          if (childId != null) {
            ref.invalidate(childWorkshopSeriesProvider(childId));
            ref.invalidate(availableWorkshopSeriesForChildProvider(childId));
            ref.invalidate(childCurrentStatusProvider(childId));
            ref.invalidate(childByIdProvider(childId));
            ref.invalidate(childMissingAttendanceProvider(childId));
            ref.invalidate(childCalendarMonthProvider);
            if (kDebugMode) {
              debugPrint('[RT] workshop_enrollments: child providers($childId) invalidated');
            }
          }
        },
      )
      .subscribe((status, [err]) {
        if (kDebugMode) debugPrint('[RT] rt:workshop_enrollments → $status');
      });

  // ── 5. children ───────────────────────────────────────────────────────────
  //
  // Keeps child list and child detail pages in sync when a child is
  // created or edited from another device.
  final childrenChannel = client
      .channel('rt:children')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'children',
        callback: (payload) {
          final rec = _primaryRecord(payload);
          final id = _str(rec, 'id');
          if (kDebugMode) {
            debugPrint('[RT] children → ${payload.eventType} id=$id');
          }
          ref.invalidate(allChildrenProvider);
          ref.invalidate(dashboardStatsProvider);
          if (id != null) {
            ref.invalidate(childByIdProvider(id));
            ref.invalidate(childDetailProvider(id));
            ref.invalidate(childWorkshopSeriesProvider(id));
            ref.invalidate(childCurrentStatusProvider(id));
            if (kDebugMode) {
              debugPrint('[RT] children: child providers($id) invalidated');
            }
          }
        },
      )
      .subscribe((status, [err]) {
        if (kDebugMode) debugPrint('[RT] rt:children → $status');
      });

  // ── 6. payment_cycles ────────────────────────────────────────────────────
  //
  // Keeps payment status and overdue list in sync across devices.
  //
  // Invalidation policy:
  //   - dashboardStatsProvider and paymentsDueProvider always (the
  //     payments-due list and dashboard tile aggregate across children).
  //   - When childId is present, invalidate exact child payment providers
  //     and skip allChildrenProvider (the list's last-attendance pill is
  //     unaffected by payment changes).
  //   - When childId is null, fall back to allChildrenProvider.
  final payChannel = client
      .channel('rt:payment_cycles')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'payment_cycles',
        callback: (payload) {
          final rec = _primaryRecord(payload);
          final childId = _str(rec, 'child_id');
          if (kDebugMode) {
            debugPrint(
              '[RT] payment_cycles → ${payload.eventType} childId=$childId',
            );
          }
          ref.invalidate(dashboardStatsProvider);
          ref.invalidate(paymentsDueProvider);
          if (kDebugMode) {
            debugPrint(
              '[RT] payment_cycles: invalidated dashboardStats, paymentsDue',
            );
          }
          if (childId != null) {
            ref.invalidate(childByIdProvider(childId));
            ref.invalidate(childPaymentCyclesNewProvider(childId));
            ref.invalidate(childPaymentStatusRowsProvider(childId));
            ref.invalidate(childCurrentStatusProvider(childId));
            ref.invalidate(childCurrentStatusRowsProvider(childId));
            ref.invalidate(childCalendarMonthProvider);
            if (kDebugMode) {
              debugPrint(
                '[RT] payment_cycles: child providers($childId) invalidated '
                '(childById, paymentCyclesNew, paymentStatusRows, '
                'currentStatus, currentStatusRows, calendarMonth)',
              );
            }
          } else {
            // Fallback when childId is missing — refresh the list.
            ref.invalidate(allChildrenProvider);
            if (kDebugMode) {
              debugPrint(
                '[RT] payment_cycles: childId null → fell back to allChildrenProvider',
              );
            }
          }
        },
      )
      .subscribe((status, [err]) {
        if (kDebugMode) debugPrint('[RT] rt:payment_cycles → $status');
      });

  // ── 7. notifications ──────────────────────────────────────────────────────
  //
  // Keeps notification bell and list fresh when new notifications arrive
  // (e.g. generated server-side or from another session).
  final notifChannel = client
      .channel('rt:notifications')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'notifications',
        callback: (payload) {
          if (kDebugMode) {
            debugPrint('[RT] notifications → ${payload.eventType}');
          }
          ref.invalidate(notificationsProvider);
          ref.invalidate(recentNotificationsProvider);
          ref.invalidate(unreadCountFutureProvider);
        },
      )
      .subscribe((status, [err]) {
        if (kDebugMode) debugPrint('[RT] rt:notifications → $status');
      });

  // ── 8. demo_workshops ────────────────────────────────────────────────────
  //
  // Keeps today's demo list and demo detail pages in sync.
  final demoChannel = client
      .channel('rt:demo_workshops')
      .onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'demo_workshops',
        callback: (payload) {
          final rec = _primaryRecord(payload);
          final id = _str(rec, 'id');
          if (kDebugMode) {
            debugPrint('[RT] demo_workshops → ${payload.eventType} id=$id');
          }
          ref.invalidate(todayDemoWorkshopsProvider);
          ref.invalidate(dashboardStatsProvider);
          if (id != null) {
            ref.invalidate(demoWorkshopByIdProvider(id));
            if (kDebugMode) {
              debugPrint('[RT] demo_workshops: demoWorkshopByIdProvider($id) invalidated');
            }
          }
        },
      )
      .subscribe((status, [err]) {
        if (kDebugMode) debugPrint('[RT] rt:demo_workshops → $status');
      });

  // ── Cleanup on dispose / logout ───────────────────────────────────────────
  ref.onDispose(() {
    if (kDebugMode) debugPrint('[RT] appRealtime: removing all channels');
    client.removeChannel(attChannel);
    client.removeChannel(swChannel);
    client.removeChannel(seriesChannel);
    client.removeChannel(enrollChannel);
    client.removeChannel(childrenChannel);
    client.removeChannel(payChannel);
    client.removeChannel(notifChannel);
    client.removeChannel(demoChannel);
  });
});

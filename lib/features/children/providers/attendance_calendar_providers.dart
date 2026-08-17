import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_client_provider.dart';
import '../data/attendance_calendar_repository.dart';
import '../domain/child_calendar_session.dart';

// ── Repository ───────────────────────────────────────────────────────────────

final attendanceCalendarRepositoryProvider =
    Provider<AttendanceCalendarRepository>((ref) {
  return AttendanceCalendarRepository(ref.watch(supabaseClientProvider));
});

// ── Month provider ───────────────────────────────────────────────────────────
//
// Family key `(childId, year, month)` — the page selects a month via a
// prev/next arrow row.

class CalendarMonthKey {
  const CalendarMonthKey({
    required this.childId,
    required this.year,
    required this.month,
  });

  final String childId;
  final int year;
  final int month; // 1..12

  @override
  bool operator ==(Object other) =>
      other is CalendarMonthKey &&
      other.childId == childId &&
      other.year == year &&
      other.month == month;

  @override
  int get hashCode => Object.hash(childId, year, month);
}

final childCalendarMonthProvider = FutureProvider.autoDispose
    .family<List<ChildCalendarSession>, CalendarMonthKey>((ref, key) async {
  final start = DateTime(key.year, key.month, 1);
  final end = DateTime(key.year, key.month + 1, 1);
  return ref.watch(attendanceCalendarRepositoryProvider).fetchMonth(
        childId: key.childId,
        monthStart: start,
        monthEndExclusive: end,
      );
});

// ── Missing-attendance provider ──────────────────────────────────────────────

final childMissingAttendanceProvider = FutureProvider.autoDispose
    .family<List<ChildCalendarSession>, String>((ref, childId) {
  return ref
      .watch(attendanceCalendarRepositoryProvider)
      .fetchMissing(childId: childId);
});

/// One workshop session in the historical attendance calendar for a child.
///
/// A session is "eligible" for display when either:
///   • the child already has an `attendance` row for the `scheduled_workshop`
///     (persisted history — always shown, even after the child has left the
///     series or the workshop has been archived), OR
///   • the child is currently enrolled in the workshop's series AND the
///     workshop is active AND its date is on/before today (recovery of a
///     session the trainer forgot to mark).
///
/// Attendance is always editable regardless of cycle membership. Payment
/// cycles are recomputed chronologically by the server-side trigger
/// `trg_recalculate_cycles_on_attendance` after every mutation (see
/// migration `20260817_chronological_payment_cycles.sql`), so a flip of
/// present↔absent on a linked row no longer causes drift.
class ChildCalendarSession {
  const ChildCalendarSession({
    required this.scheduledWorkshopId,
    required this.workshopDate,
    required this.startTime,
    required this.endTime,
    required this.workshopTitle,
    required this.workshopType,
    required this.dayOfWeek,
    required this.trainerId,
    this.attendanceId,
    this.status,
    this.observation,
    this.markedAt,
    this.markedByName,
    this.isWorkshopArchived = false,
    this.isEnrolmentActive = false,
  });

  final String scheduledWorkshopId;
  final DateTime workshopDate;
  final String startTime; // "HH:mm:ss"
  final String endTime;
  final String workshopTitle;
  final String workshopType;
  final String? dayOfWeek;
  final String? trainerId;

  final String? attendanceId;
  final String? status; // 'present' | 'absent' | 'motivated' | null
  final String? observation;
  final DateTime? markedAt;
  final String? markedByName;

  final bool isWorkshopArchived;
  final bool isEnrolmentActive;

  bool get hasAttendance => attendanceId != null;

  /// Handy string like "17:30".
  String get startTimeShort =>
      startTime.length >= 5 ? startTime.substring(0, 5) : startTime;
  String get endTimeShort =>
      endTime.length >= 5 ? endTime.substring(0, 5) : endTime;

  ChildCalendarSession copyWith({
    String? status,
    String? observation,
    String? attendanceId,
    DateTime? markedAt,
    String? markedByName,
  }) {
    return ChildCalendarSession(
      scheduledWorkshopId: scheduledWorkshopId,
      workshopDate: workshopDate,
      startTime: startTime,
      endTime: endTime,
      workshopTitle: workshopTitle,
      workshopType: workshopType,
      dayOfWeek: dayOfWeek,
      trainerId: trainerId,
      attendanceId: attendanceId ?? this.attendanceId,
      status: status ?? this.status,
      observation: observation ?? this.observation,
      markedAt: markedAt ?? this.markedAt,
      markedByName: markedByName ?? this.markedByName,
      isWorkshopArchived: isWorkshopArchived,
      isEnrolmentActive: isEnrolmentActive,
    );
  }
}

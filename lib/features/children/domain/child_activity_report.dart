/// Domain model bundle for the Child Activity Report PDF.
///
/// All fields are pre-resolved display values — no UUIDs, no raw nulls.
/// The PDF service consumes this directly; it never reaches back into the
/// database. The repository is the single integration point.
class ChildActivityReportData {
  const ChildActivityReportData({
    required this.childInfo,
    required this.activeWorkshops,
    required this.attendanceRows,
    required this.paymentRows,
    required this.observations,
    required this.summary,
    required this.generatedAt,
  });

  final ChildReportChildInfo childInfo;
  final List<ChildReportWorkshopInfo> activeWorkshops;
  final List<ChildReportAttendanceRow> attendanceRows;
  final List<ChildReportPaymentRow> paymentRows;
  final List<ChildReportObservation> observations;
  final ChildReportSummary summary;
  final DateTime generatedAt;
}

class ChildReportChildInfo {
  const ChildReportChildInfo({
    required this.id,
    required this.fullName,
    this.birthDate,
    this.age,
    this.parentName,
    this.parentPhone,
    this.parentEmail,
  });

  final String id;
  final String fullName;
  final DateTime? birthDate;
  final int? age;
  final String? parentName;
  final String? parentPhone;
  final String? parentEmail;
}

class ChildReportWorkshopInfo {
  const ChildReportWorkshopInfo({
    required this.title,
    this.workshopType,
    this.dayOfWeek,
    this.startTime,
    this.endTime,
    this.trainerName,
  });

  final String title;
  final String? workshopType;
  final String? dayOfWeek;
  final String? startTime;
  final String? endTime;
  final String? trainerName;
}

class ChildReportAttendanceRow {
  const ChildReportAttendanceRow({
    this.date,
    required this.workshopTitle,
    this.workshopType,
    this.trainerName,
    this.startTime,
    this.endTime,
    required this.status,
    this.observation,
  });

  final DateTime? date;
  final String workshopTitle;
  final String? workshopType;
  final String? trainerName;
  final String? startTime;
  final String? endTime;

  /// Raw status from `attendance.status`: 'present' / 'absent' / 'motivated'.
  final String status;
  final String? observation;
}

class ChildReportPaymentRow {
  const ChildReportPaymentRow({
    this.periodStart,
    this.periodEnd,
    this.sessionsCount,
    this.status,
    this.paymentMethod,
    this.paidAt,
    this.notes,
    this.seriesTitle,
  });

  final DateTime? periodStart;
  final DateTime? periodEnd;
  final int? sessionsCount;

  /// Raw status from `payment_cycles.status`: 'paid' / 'paid_advance' / 'due'
  /// / 'overdue' / 'cancelled'.
  final String? status;

  /// Raw method from `payment_cycles.payment_method`: 'pos' / 'op' / null.
  final String? paymentMethod;
  final DateTime? paidAt;
  final String? notes;
  /// Workshop series title (joined from workshop_series.title). Used to
  /// group cycles per series in the PDF. Nullable for legacy rows.
  final String? seriesTitle;
}

class ChildReportObservation {
  const ChildReportObservation({
    this.date,
    required this.workshopTitle,
    required this.text,
  });

  final DateTime? date;
  final String workshopTitle;
  final String text;
}

class ChildReportSummary {
  const ChildReportSummary({
    required this.totalSessions,
    required this.presentCount,
    required this.absentCount,
    required this.motivatedCount,
    required this.attendanceRate,
    required this.totalWorkshops,
    required this.totalPaymentCycles,
    required this.confirmedPayments,
    required this.overduePayments,
  });

  /// Count of attendance rows considered (`present` + `absent` + `motivated`).
  final int totalSessions;
  final int presentCount;
  final int absentCount;
  final int motivatedCount;

  /// 0.0–1.0 (presentCount / totalSessions). Null-safe: zero when no
  /// sessions are recorded, so the PDF can format unconditionally.
  final double attendanceRate;

  /// Distinct workshop series the child has ever attended (by title).
  final int totalWorkshops;
  final int totalPaymentCycles;
  final int confirmedPayments;
  final int overduePayments;

  bool get hasActivity => totalSessions > 0;
}

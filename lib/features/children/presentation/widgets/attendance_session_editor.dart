import 'package:flutter/material.dart';

import '../../../../core/theme/app_theme.dart';
import '../../domain/child_calendar_session.dart';

/// Bottom sheet / dialog used to edit a single [ChildCalendarSession] from
/// the calendar. Renders as a bottom sheet on mobile widths and a dialog
/// on desktop widths; both call [onSave] with the chosen
/// `(status, observation)`.
class AttendanceSessionEditor extends StatefulWidget {
  const AttendanceSessionEditor({
    super.key,
    required this.session,
    required this.onSave,
  });

  final ChildCalendarSession session;
  final Future<void> Function(String status, String? observation) onSave;

  static Future<void> show(
    BuildContext context, {
    required ChildCalendarSession session,
    required Future<void> Function(String status, String? observation) onSave,
  }) {
    final isMobile = MediaQuery.of(context).size.width < 600;
    if (isMobile) {
      return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (_) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: AttendanceSessionEditor(session: session, onSave: onSave),
        ),
      );
    }
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: AttendanceSessionEditor(session: session, onSave: onSave),
        ),
      ),
    );
  }

  @override
  State<AttendanceSessionEditor> createState() =>
      _AttendanceSessionEditorState();
}

class _AttendanceSessionEditorState extends State<AttendanceSessionEditor> {
  late String _status;
  late final TextEditingController _obsCtrl;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _status = widget.session.status ?? 'present';
    _obsCtrl = TextEditingController(text: widget.session.observation ?? '');
  }

  @override
  void dispose() {
    _obsCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final obs = _obsCtrl.text.trim();
      await widget.onSave(_status, obs.isEmpty ? null : obs);
      if (!mounted) return;
      Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.purple.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.event_note_rounded,
                    size: 18, color: AppColors.purple),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  s.workshopTitle.isEmpty ? 'Sesiune' : s.workshopTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _headerSubtitle(s),
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppColors.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          if (s.hasAttendance)
            _CurrentStateChip(status: s.status, markedByName: s.markedByName),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _StatusBtn(
                  label: 'Prezent',
                  icon: Icons.check_rounded,
                  color: AppColors.success,
                  selected: _status == 'present',
                  onTap: () => setState(() => _status = 'present'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _StatusBtn(
                  label: 'Absent',
                  icon: Icons.close_rounded,
                  color: AppColors.error,
                  selected: _status == 'absent',
                  onTap: () => setState(() => _status = 'absent'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _obsCtrl,
            decoration: const InputDecoration(
              labelText: 'Observație (opțional)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            maxLines: 2,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed:
                    _saving ? null : () => Navigator.pop(context),
                child: const Text('Anulează'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Salvează'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _headerSubtitle(ChildCalendarSession s) {
    final date = _fmtDate(s.workshopDate);
    final time = '${s.startTimeShort}–${s.endTimeShort}';
    final parts = [date, time];
    if (s.workshopType.isNotEmpty) parts.add(s.workshopType);
    return parts.join(' • ');
  }

  static const _months = [
    '', 'ianuarie', 'februarie', 'martie', 'aprilie', 'mai', 'iunie',
    'iulie', 'august', 'septembrie', 'octombrie', 'noiembrie', 'decembrie',
  ];

  String _fmtDate(DateTime d) => '${d.day} ${_months[d.month]} ${d.year}';
}

class _CurrentStateChip extends StatelessWidget {
  const _CurrentStateChip({required this.status, this.markedByName});
  final String? status;
  final String? markedByName;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      'present' => (AppColors.success, 'Prezent'),
      'absent' => (AppColors.error, 'Absent'),
      'motivated' => (AppColors.warning, 'Motivat'),
      _ => (AppColors.muted, 'Nemarcat'),
    };
    final suffix = markedByName == null || markedByName!.isEmpty
        ? ''
        : ' • marcat de $markedByName';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        'Status actual: $label$suffix',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _StatusBtn extends StatelessWidget {
  const _StatusBtn({
    required this.label,
    required this.icon,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (selected) {
      return FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.5)),
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

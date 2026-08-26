import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../children/presentation/widgets/child_form_helpers.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../providers/enrollment_providers.dart';
import '../providers/workshops_providers.dart';
import 'workshop_form_actions.dart' show RecurringScope;
import 'workshop_type_section.dart' show normalizeDayOfWeek, normalizeWorkshopType;

// ── WorkshopFormPage ──────────────────────────────────────────────────────────
//
// Visual + structural parity with [ChildFormPage]:
//   • Same `ChildSectionCard` for each section (icon-badge header + title).
//   • Same `ChildFormField` label / required-asterisk wrapper.
//   • Same `buildChildFormInputDeco` for every input.
//   • Same `ChildFormSaveRow` at the bottom (cancel + save + error banner).
//   • Same outer `SingleChildScrollView` + `Center(maxWidth: 720)` layout.
//
// Save semantics, validation, recurring-scope handling and provider
// invalidations preserved verbatim from the previous implementation —
// only presentation was refactored.

String _generateUuid() {
  final rng = Random.secure();
  final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

const _kWorkshopTypeOptions = <_WTypeOption>[
  _WTypeOption('Robotica', 'Robotică'),
  _WTypeOption('Benzi desenate', 'Benzi desenate'),
  _WTypeOption('Modelare 3D', 'Modelare 3D'),
  _WTypeOption('Desen și pictură', 'Desen și pictură'),
  _WTypeOption('Povestiri', 'Povestiri'),
  _WTypeOption('Programare', 'Programare'),
  _WTypeOption('Lectura', 'Lectură'),
  _WTypeOption('Altele', 'Altele'),
];

const _kDaysOfWeek = [
  'Luni',
  'Marți',
  'Miercuri',
  'Joi',
  'Vineri',
  'Sâmbătă',
  'Duminică',
];

class _WTypeOption {
  const _WTypeOption(this.value, this.label);
  final String value;
  final String label;
}

class WorkshopFormPage extends ConsumerStatefulWidget {
  const WorkshopFormPage({super.key, this.workshopId});
  final String? workshopId;

  @override
  ConsumerState<WorkshopFormPage> createState() => _WorkshopFormPageState();
}

class _WorkshopFormPageState extends ConsumerState<WorkshopFormPage> {
  bool get _isEditing => widget.workshopId != null;

  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  String? _workshopType;
  String? _dayOfWeek;
  String? _trainerId;

  DateTime? _workshopDate;
  TimeOfDay? _startTime;
  TimeOfDay? _endTime;

  bool _isRecurring = false;
  bool _isActive = true;
  bool _populated = false;
  bool _populateScheduled = false;
  bool _saving = false;
  String? _saveError;
  // Canonical FK to workshop_series.id. The repository mirrors this into
  // both `series_id` and `recurring_series_id` columns on save so the
  // legacy column stays in sync until it is dropped.
  String? _seriesId;
  RecurringScope _applyScope = RecurringScope.thisOnly;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _populate() {
    if (_populated || _populateScheduled || !_isEditing) return;
    final ws = ref.read(workshopByIdProvider(widget.workshopId!)).valueOrNull;
    if (ws == null) return;
    _populateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _populated) return;
      setState(() {
        _populated = true;
        _titleCtrl.text = ws.title;
        _notesCtrl.text = ws.notes ?? '';
        _workshopType = normalizeWorkshopType(ws.workshopType);
        _dayOfWeek = normalizeDayOfWeek(ws.dayOfWeek);
        _trainerId = ws.trainerId;
        _workshopDate = ws.workshopDate;
        _isRecurring = ws.isRecurring ?? false;
        _isActive = ws.isActive ?? true;
        _seriesId = ws.seriesId;
        _startTime = _parseTime(ws.startTime);
        _endTime = _parseTime(ws.endTime);
      });
    });
  }

  TimeOfDay? _parseTime(String? hhmm) {
    if (hhmm == null || hhmm.isEmpty) return null;
    final parts = hhmm.split(':');
    if (parts.length < 2) return null;
    return TimeOfDay(
      hour: int.tryParse(parts[0]) ?? 0,
      minute: int.tryParse(parts[1]) ?? 0,
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _workshopDate ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
    );
    if (picked != null) setState(() => _workshopDate = picked);
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _startTime ?? const TimeOfDay(hour: 9, minute: 0),
    );
    if (picked != null) setState(() => _startTime = picked);
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _endTime ?? const TimeOfDay(hour: 10, minute: 0),
    );
    if (picked != null) setState(() => _endTime = picked);
  }

  Future<void> _save() async {
    setState(() => _saveError = null);
    if (!_formKey.currentState!.validate()) return;
    if (_workshopDate == null) {
      setState(() => _saveError = 'Selectează data atelierului.');
      return;
    }
    if (_startTime == null) {
      setState(() => _saveError = 'Selectează ora de start.');
      return;
    }
    if (_endTime == null) {
      setState(() => _saveError = 'Selectează ora de final.');
      return;
    }
    if (_trainerId == null) {
      setState(() => _saveError = 'Selectează un trainer.');
      return;
    }

    setState(() => _saving = true);
    try {
      final repo = ref.read(workshopsRepositoryProvider);

      // Ensure a recurring workshop ALWAYS has a series id, including when an
      // existing non-recurring workshop is being flipped to recurring (the
      // form was previously only generating an id on initial create).
      // Without this, the saved row has is_recurring=true but series_id=null,
      // which later breaks workshop_enrollments.
      final needsNewSeriesId =
          _isRecurring && (_seriesId == null || _seriesId!.isEmpty);
      if (needsNewSeriesId) {
        _seriesId = _generateUuid();
      }

      final payload = <String, dynamic>{
        'title': _titleCtrl.text.trim(),
        'workshop_type': _workshopType,
        'day_of_week': _dayOfWeek,
        'workshop_date': _workshopDate!.toIso8601String().split('T').first,
        'start_time': _formatTod(_startTime!),
        'end_time': _formatTod(_endTime!),
        'trainer_id': _trainerId,
        'notes': _notesCtrl.text.trim().isEmpty
            ? null
            : _notesCtrl.text.trim(),
        'is_recurring': _isRecurring,
        'is_active': _isActive,
        // Canonical column; WorkshopsRepository mirrors this into the
        // legacy `recurring_series_id` column on save.
        if (_isRecurring && needsNewSeriesId) 'series_id': _seriesId,
      };

      if (_isEditing) {
        final applyToSeries =
            _seriesId != null && _applyScope == RecurringScope.series;
        if (applyToSeries) {
          final seriesPayload = Map<String, dynamic>.from(payload)
            ..remove('workshop_date');
          await repo.updateSeries(
            seriesId: _seriesId!,
            fromDate: _workshopDate!,
            data: seriesPayload,
          );
        } else {
          await repo.update(widget.workshopId!, payload);
        }
      } else {
        await repo.create(payload);
        // Auto-backfill: a brand-new recurring series with a past start
        // date needs the missing weekly occurrences materialised so the
        // historical attendance calendar has real rows to work with.
        // Idempotent — safe if there's nothing to backfill.
        if (_isRecurring &&
            _seriesId != null &&
            _workshopDate!.isBefore(
                DateTime.now().subtract(const Duration(days: 6)))) {
          try {
            final inserted = await repo.backfillSeriesSessions(
              seriesId: _seriesId!,
              fromDate: _workshopDate!,
            );
            if (kDebugMode) {
              debugPrint('[Workshop] backfill inserted $inserted sessions');
            }
          } catch (e) {
            if (kDebugMode) debugPrint('[Workshop] backfill failed: $e');
            // Non-fatal — the workshop itself was created successfully.
          }
        }
      }

      ref.invalidate(allScheduledWorkshopsProvider);
      ref.invalidate(todayWorkshopsProvider);
      ref.invalidate(workshopsListProvider);
      ref.invalidate(activeWorkshopSeriesProvider);
      ref.invalidate(dashboardStatsProvider);
      if (_isEditing) {
        ref.invalidate(workshopByIdProvider(widget.workshopId!));
        ref.invalidate(workshopDetailsProvider(widget.workshopId!));
        if (_seriesId != null) {
          ref.invalidate(workshopSeriesByIdProvider(_seriesId!));
        }
      }
      if (kDebugMode) debugPrint('[Workshop] providers invalidated after save');

      if (mounted) {
        if (_isEditing) {
          context.go('/workshops/${widget.workshopId}');
        } else {
          context.canPop() ? context.pop() : context.go('/dashboard');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saveError = 'Eroare la salvare: $e';
          _saving = false;
        });
      }
    } finally {
      if (mounted && _saving) setState(() => _saving = false);
    }
  }

  String _formatTod(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isEditing) {
      ref.watch(workshopByIdProvider(widget.workshopId!));
      _populate();
    }

    final inputDeco = buildChildFormInputDeco(theme);

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
        title: Text(_isEditing ? 'Editare atelier' : 'Atelier nou'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Form(
              key: _formKey,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 600;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Informații atelier ────────────────────────────
                      ChildSectionCard(
                        icon: Icons.info_outline_rounded,
                        title: 'Informații atelier',
                        child: _BasicInfoSection(
                          titleCtrl: _titleCtrl,
                          workshopType: _workshopType,
                          dayOfWeek: _dayOfWeek,
                          isActive: _isActive,
                          inputDeco: inputDeco,
                          onTypeChanged: (v) =>
                              setState(() => _workshopType = v),
                          onDayChanged: (v) =>
                              setState(() => _dayOfWeek = v),
                          onActiveChanged: (v) =>
                              setState(() => _isActive = v),
                          isWide: isWide,
                        ),
                      ),
                      const SizedBox(height: 20),
                      // ── Programare ────────────────────────────────────
                      ChildSectionCard(
                        icon: Icons.calendar_today_outlined,
                        title: 'Programare',
                        child: _ScheduleSection(
                          workshopDate: _workshopDate,
                          startTime: _startTime,
                          endTime: _endTime,
                          isRecurring: _isRecurring,
                          inputDeco: inputDeco,
                          onPickDate: _pickDate,
                          onPickStart: _pickStartTime,
                          onPickEnd: _pickEndTime,
                          onRecurringChanged: (v) =>
                              setState(() => _isRecurring = v),
                          isEditing: _isEditing,
                          hasRecurringSeries: _seriesId != null,
                          applyScope: _applyScope,
                          onScopeChanged: (v) =>
                              setState(() => _applyScope = v),
                          isWide: isWide,
                        ),
                      ),
                      const SizedBox(height: 20),
                      // ── Trainer ───────────────────────────────────────
                      ChildSectionCard(
                        icon: Icons.person_outline_rounded,
                        title: 'Trainer',
                        child: _TrainerSection(
                          trainerId: _trainerId,
                          inputDeco: inputDeco,
                          onTrainerChanged: (v) =>
                              setState(() => _trainerId = v),
                          onTrainerReset: (v) =>
                              setState(() => _trainerId = v),
                        ),
                      ),
                      const SizedBox(height: 20),
                      // ── Observații ────────────────────────────────────
                      ChildSectionCard(
                        icon: Icons.sticky_note_2_outlined,
                        title: 'Observații',
                        child: ChildFormField(
                          label: 'Note',
                          child: TextFormField(
                            controller: _notesCtrl,
                            decoration: inputDeco.copyWith(
                                hintText: 'Opțional'),
                            maxLines: 4,
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                      ChildFormSaveRow(
                        saving: _saving,
                        isEditing: _isEditing,
                        onSave: _save,
                        saveError: _saveError,
                      ),
                      // "Anulează întreaga serie" button removed
                      // 2026-08-26. Cancellation now flows through the
                      // details page's single "Anulează sesiunea"
                      // popup action which auto-decides:
                      //   • recurring workshop → cancels the whole series
                      //   • one-off workshop → cancels just the row
                      // Rationale: users found two separate cancel
                      // surfaces confusing and expected the "cancel
                      // session" action to be permanent.
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Cancel-series flow removed 2026-08-26. All cancellation now goes
  // through workshop_details_page.dart's `_cancelSession` which auto-
  // decides based on whether the workshop belongs to a series.
}

// ── Section: basic info (title + type + day + isActive) ──────────────────────

class _BasicInfoSection extends StatelessWidget {
  const _BasicInfoSection({
    required this.titleCtrl,
    required this.workshopType,
    required this.dayOfWeek,
    required this.isActive,
    required this.inputDeco,
    required this.onTypeChanged,
    required this.onDayChanged,
    required this.onActiveChanged,
    required this.isWide,
  });

  final TextEditingController titleCtrl;
  final String? workshopType;
  final String? dayOfWeek;
  final bool isActive;
  final InputDecoration inputDeco;
  final ValueChanged<String?> onTypeChanged;
  final ValueChanged<String?> onDayChanged;
  final ValueChanged<bool> onActiveChanged;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final typeField = ChildFormField(
      label: 'Tip atelier',
      required: true,
      child: DropdownButtonFormField<String>(
        key: ValueKey('workshop-type-$workshopType'),
        initialValue: workshopType,
        decoration: inputDeco,
        hint: const Text('Selectează tipul'),
        items: _kWorkshopTypeOptions
            .map((o) => DropdownMenuItem(
                  value: o.value,
                  child: Text(o.label),
                ))
            .toList(),
        onChanged: onTypeChanged,
        validator: (v) =>
            v == null ? 'Selectează tipul atelierului' : null,
      ),
    );
    final dayField = ChildFormField(
      label: 'Ziua săptămânii',
      required: true,
      child: DropdownButtonFormField<String>(
        key: ValueKey('workshop-day-$dayOfWeek'),
        initialValue: dayOfWeek,
        decoration: inputDeco,
        hint: const Text('Selectează ziua'),
        items: _kDaysOfWeek
            .map((d) => DropdownMenuItem(value: d, child: Text(d)))
            .toList(),
        onChanged: onDayChanged,
        validator: (v) => v == null ? 'Selectează ziua' : null,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChildFormField(
          label: 'Titlu',
          required: true,
          child: TextFormField(
            controller: titleCtrl,
            decoration: inputDeco,
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Titlul este obligatoriu' : null,
          ),
        ),
        const SizedBox(height: 14),
        if (isWide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: typeField),
              const SizedBox(width: 14),
              Expanded(child: dayField),
            ],
          )
        else ...[
          typeField,
          const SizedBox(height: 14),
          dayField,
        ],
        const SizedBox(height: 14),
        _ToggleTile(
          icon: Icons.toggle_on_outlined,
          label: 'Atelier activ',
          subtitle: 'Apare în lista de ateliere active',
          value: isActive,
          onChanged: onActiveChanged,
        ),
      ],
    );
  }
}

// ── Section: schedule (date + start + end + recurring + scope) ──────────────

class _ScheduleSection extends StatelessWidget {
  const _ScheduleSection({
    required this.workshopDate,
    required this.startTime,
    required this.endTime,
    required this.isRecurring,
    required this.inputDeco,
    required this.onPickDate,
    required this.onPickStart,
    required this.onPickEnd,
    required this.onRecurringChanged,
    required this.isEditing,
    required this.hasRecurringSeries,
    required this.applyScope,
    required this.onScopeChanged,
    required this.isWide,
  });

  final DateTime? workshopDate;
  final TimeOfDay? startTime;
  final TimeOfDay? endTime;
  final bool isRecurring;
  final InputDecoration inputDeco;
  final VoidCallback onPickDate;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;
  final ValueChanged<bool> onRecurringChanged;
  final bool isEditing;
  final bool hasRecurringSeries;
  final RecurringScope applyScope;
  final ValueChanged<RecurringScope> onScopeChanged;
  final bool isWide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget readonlyField({
      required String label,
      required String value,
      required IconData icon,
      required VoidCallback onTap,
      String? hint,
    }) {
      return ChildFormField(
        label: label,
        required: true,
        child: GestureDetector(
          onTap: onTap,
          child: AbsorbPointer(
            child: TextFormField(
              readOnly: true,
              controller: TextEditingController(text: value),
              decoration: inputDeco.copyWith(
                hintText: hint,
                suffixIcon:
                    Icon(icon, size: 18, color: theme.colorScheme.outline),
              ),
            ),
          ),
        ),
      );
    }

    final dateField = readonlyField(
      label: 'Data',
      value: workshopDate == null ? '' : _fmtDate(workshopDate!),
      icon: Icons.calendar_today_outlined,
      onTap: onPickDate,
      hint: 'Alege data',
    );
    final startField = readonlyField(
      label: 'Ora start',
      value: startTime == null ? '' : _fmtTod(startTime!),
      icon: Icons.access_time_rounded,
      onTap: onPickStart,
      hint: 'HH:MM',
    );
    final endField = readonlyField(
      label: 'Ora final',
      value: endTime == null ? '' : _fmtTod(endTime!),
      icon: Icons.access_time_rounded,
      onTap: onPickEnd,
      hint: 'HH:MM',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        dateField,
        const SizedBox(height: 14),
        if (isWide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: startField),
              const SizedBox(width: 14),
              Expanded(child: endField),
            ],
          )
        else ...[
          startField,
          const SizedBox(height: 14),
          endField,
        ],
        const SizedBox(height: 14),
        _ToggleTile(
          icon: Icons.repeat_rounded,
          label: 'Atelier recurent',
          subtitle:
              'Face parte dintr-o serie săptămânală cu același trainer',
          value: isRecurring,
          onChanged: onRecurringChanged,
        ),
        if (isEditing && hasRecurringSeries) ...[
          const SizedBox(height: 14),
          _RecurringScopePicker(
            value: applyScope,
            onChanged: onScopeChanged,
          ),
        ],
      ],
    );
  }

  static String _fmtDate(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
  static String _fmtTod(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

// ── Section: trainer ────────────────────────────────────────────────────────

class _TrainerSection extends ConsumerWidget {
  const _TrainerSection({
    required this.trainerId,
    required this.inputDeco,
    required this.onTrainerChanged,
    required this.onTrainerReset,
  });

  final String? trainerId;
  final InputDecoration inputDeco;
  final ValueChanged<String?> onTrainerChanged;
  final ValueChanged<String?> onTrainerReset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final trainersAsync = ref.watch(trainersForDropdownProvider);

    return ChildFormField(
      label: 'Trainer responsabil',
      required: true,
      child: trainersAsync.when(
        loading: () => Container(
          height: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.4)),
          ),
          alignment: Alignment.center,
          child: const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (e, _) => Text(
          'Eroare: $e',
          style: TextStyle(color: theme.colorScheme.error),
        ),
        data: (trainers) {
          final validIds = trainers.map((t) => t.id).toSet();
          final safeId = (trainerId != null && validIds.contains(trainerId))
              ? trainerId
              : null;
          if (safeId != trainerId) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              onTrainerReset(safeId);
            });
          }
          return DropdownButtonFormField<String>(
            key: ValueKey('workshop-trainer-$safeId'),
            initialValue: safeId,
            decoration: inputDeco,
            hint: const Text('Selectează trainer'),
            items: trainers
                .map((t) => DropdownMenuItem(
                      value: t.id,
                      child: Text(t.displayName),
                    ))
                .toList(),
            onChanged: onTrainerChanged,
            validator: (v) => v == null ? 'Selectează un trainer' : null,
          );
        },
      ),
    );
  }
}

// ── Reusable toggle tile (matches Child form's `Copil activ` row) ──────────

class _ToggleTile extends StatelessWidget {
  const _ToggleTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.purple, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(subtitle,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
          ),
          Switch.adaptive(
            value: value,
            activeThumbColor: AppColors.purple,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

// ── Recurring-scope picker (only when editing a recurring instance) ───────

class _RecurringScopePicker extends StatelessWidget {
  const _RecurringScopePicker({required this.value, required this.onChanged});

  final RecurringScope value;
  final ValueChanged<RecurringScope> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.4)),
        color: theme.scaffoldBackgroundColor,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: Text(
              'Aplică modificările',
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          _ScopeTile(
            label: 'Doar acestei instanțe',
            subtitle: 'Modifică numai atelierul curent',
            selected: value == RecurringScope.thisOnly,
            onTap: () => onChanged(RecurringScope.thisOnly),
          ),
          Divider(
            height: 1,
            indent: 14,
            endIndent: 14,
            color: theme.colorScheme.outline.withValues(alpha: 0.2),
          ),
          _ScopeTile(
            label: 'Seriei recurente',
            subtitle:
                'Modifică toate atelierele viitoare din această serie',
            selected: value == RecurringScope.series,
            onTap: () => onChanged(RecurringScope.series),
          ),
        ],
      ),
    );
  }
}

class _ScopeTile extends StatelessWidget {
  const _ScopeTile({
    required this.label,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_off_rounded,
              size: 20,
              color: selected ? AppColors.purple : theme.colorScheme.outline,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.purple : null,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

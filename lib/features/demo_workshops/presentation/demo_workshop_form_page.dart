import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/date_utils.dart';
import '../../auth/providers/auth_providers.dart';
import '../../children/presentation/widgets/child_form_helpers.dart';
import '../../dashboard/providers/dashboard_providers.dart';
import '../../workshops/domain/workshop_series.dart';
import '../providers/demo_workshops_providers.dart';

// ── DemoWorkshopFormPage ──────────────────────────────────────────────────────
//
// Visual + structural parity with [ChildFormPage]:
//   • Same `ChildSectionCard` for each section (icon-badge header + title).
//   • Same `ChildFormField` label / required-asterisk wrapper.
//   • Same `buildChildFormInputDeco` for every input.
//   • Same `ChildFormSaveRow` for the save / cancel row.
//   • Same outer `SingleChildScrollView` + `Center(maxWidth: 680)` layout.
//
// Business logic, validation rules, payload shape and Supabase calls
// preserved verbatim from the previous implementation — only presentation
// was refactored.

class DemoWorkshopFormPage extends ConsumerStatefulWidget {
  const DemoWorkshopFormPage({super.key});

  @override
  ConsumerState<DemoWorkshopFormPage> createState() =>
      _DemoWorkshopFormPageState();
}

class _DemoWorkshopFormPageState extends ConsumerState<DemoWorkshopFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _parentNameCtrl = TextEditingController();
  final _parentPhoneCtrl = TextEditingController();
  final _parentEmailCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  WorkshopSeries? _selectedSeries;
  DateTime _demoDate = DateTime.now();
  TimeOfDay _startTime = const TimeOfDay(hour: 10, minute: 0);
  TimeOfDay _endTime = const TimeOfDay(hour: 11, minute: 0);
  bool _saving = false;
  String? _saveError;

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _parentNameCtrl.dispose();
    _parentPhoneCtrl.dispose();
    _parentEmailCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  static TimeOfDay _parseHHMM(String t) {
    final p = t.split(':');
    return TimeOfDay(
      hour: int.tryParse(p[0]) ?? 0,
      minute: int.tryParse(p.length > 1 ? p[1] : '0') ?? 0,
    );
  }

  String _fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:00';

  static String _seriesLabel(WorkshopSeries s) {
    final start = formatTimeString(s.startTime);
    final end = s.endTime != null ? formatTimeString(s.endTime!) : '';
    final timeRange = end.isNotEmpty ? '$start–$end' : start;
    final day = s.dayOfWeek ?? '';
    final trainer = s.trainerName ?? '—';
    return '${s.title} • $day $timeRange • $trainer';
  }

  void _onSeriesSelected(WorkshopSeries? series) {
    setState(() {
      _selectedSeries = series;
      if (series != null) {
        _startTime = _parseHHMM(series.startTime);
        if (series.endTime != null) {
          _endTime = _parseHHMM(series.endTime!);
        }
      }
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _demoDate,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _demoDate = picked);
  }

  Future<void> _pickTime(bool isStart) async {
    final initial = isStart ? _startTime : _endTime;
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startTime = picked;
        } else {
          _endTime = picked;
        }
      });
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedSeries == null) {
      setState(() => _saveError = 'Selectează un atelier demo.');
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final userId = ref.read(currentUserProvider)?.id ?? '';
      final series = _selectedSeries!;
      await ref.read(demoWorkshopsRepositoryProvider).create({
        'child_first_name': _firstNameCtrl.text.trim(),
        'child_last_name': _lastNameCtrl.text.trim(),
        'parent_name': _parentNameCtrl.text.trim(),
        'parent_phone': _parentPhoneCtrl.text.trim(),
        if (_parentEmailCtrl.text.trim().isNotEmpty)
          'parent_email': _parentEmailCtrl.text.trim(),
        'workshop_type': series.workshopType ?? '',
        'workshop_title': series.title,
        'demo_date':
            '${_demoDate.year}-'
            '${_demoDate.month.toString().padLeft(2, '0')}-'
            '${_demoDate.day.toString().padLeft(2, '0')}',
        'start_time': _fmtTime(_startTime),
        'end_time': _fmtTime(_endTime),
        'trainer_id': series.trainerId,
        if (_notesCtrl.text.trim().isNotEmpty)
          'notes': _notesCtrl.text.trim(),
        'status': 'scheduled',
        'created_by': userId,
      });
      ref.invalidate(todayDemoWorkshopsProvider);
      ref.invalidate(dashboardStatsProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Demo programat cu succes.')),
        );
        context.canPop() ? context.pop() : context.go('/dashboard');
      }
    } on PostgrestException catch (e) {
      if (!mounted) return;
      final isPermission =
          e.code == '42501' || (e.message.contains('permission denied'));
      setState(() {
        _saveError = isPermission
            ? 'Nu ai permisiunea să programezi ateliere demo. '
                'Verifică rolul contului sau politicile RLS.'
            : 'Eroare la salvare. Încearcă din nou.';
        _saving = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _saveError = 'A apărut o eroare. Încearcă din nou.';
          _saving = false;
        });
      }
    } finally {
      if (mounted && _saving) setState(() => _saving = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
        title: const Text('Programează demo'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Date copil ─────────────────────────────────────────
                  ChildSectionCard(
                    icon: Icons.child_care_outlined,
                    title: 'Date copil',
                    child: _ChildNamesRow(
                      firstNameCtrl: _firstNameCtrl,
                      lastNameCtrl: _lastNameCtrl,
                      inputDeco: inputDeco,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // ── Date părinte ───────────────────────────────────────
                  ChildSectionCard(
                    icon: Icons.contact_phone_outlined,
                    title: 'Date părinte',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ChildFormField(
                          label: 'Nume părinte',
                          required: true,
                          child: TextFormField(
                            controller: _parentNameCtrl,
                            decoration: inputDeco,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Câmp obligatoriu'
                                : null,
                          ),
                        ),
                        const SizedBox(height: 14),
                        ChildFormField(
                          label: 'Telefon',
                          required: true,
                          child: TextFormField(
                            controller: _parentPhoneCtrl,
                            keyboardType: TextInputType.phone,
                            decoration: inputDeco,
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? 'Câmp obligatoriu'
                                : null,
                          ),
                        ),
                        const SizedBox(height: 14),
                        ChildFormField(
                          label: 'Email',
                          child: TextFormField(
                            controller: _parentEmailCtrl,
                            keyboardType: TextInputType.emailAddress,
                            decoration: inputDeco.copyWith(
                                hintText: 'Opțional'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  // ── Atelier demo ───────────────────────────────────────
                  ChildSectionCard(
                    icon: Icons.school_outlined,
                    title: 'Atelier demo',
                    child: _SeriesPicker(
                      selectedSeries: _selectedSeries,
                      inputDeco: inputDeco,
                      onChanged: _onSeriesSelected,
                      seriesLabel: _seriesLabel,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // ── Dată și oră ────────────────────────────────────────
                  ChildSectionCard(
                    icon: Icons.schedule_outlined,
                    title: 'Dată și oră',
                    child: _DateTimePickers(
                      demoDate: _demoDate,
                      startTime: _startTime,
                      endTime: _endTime,
                      onPickDate: _pickDate,
                      onPickStart: () => _pickTime(true),
                      onPickEnd: () => _pickTime(false),
                      inputDeco: inputDeco,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // ── Observații ─────────────────────────────────────────
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
                    isEditing: false,
                    onSave: _save,
                    saveError: _saveError,
                    createLabel: 'Adaugă demo',
                    cancelFallbackRoute: '/dashboard',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Sub-widgets ─────────────────────────────────────────────────────────────

class _ChildNamesRow extends StatelessWidget {
  const _ChildNamesRow({
    required this.firstNameCtrl,
    required this.lastNameCtrl,
    required this.inputDeco,
  });
  final TextEditingController firstNameCtrl;
  final TextEditingController lastNameCtrl;
  final InputDecoration inputDeco;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 360;
        final first = ChildFormField(
          label: 'Prenume',
          required: true,
          child: TextFormField(
            controller: firstNameCtrl,
            decoration: inputDeco,
            validator: (v) => (v == null || v.trim().isEmpty)
                ? 'Câmp obligatoriu'
                : null,
          ),
        );
        final last = ChildFormField(
          label: 'Nume',
          required: true,
          child: TextFormField(
            controller: lastNameCtrl,
            decoration: inputDeco,
            validator: (v) => (v == null || v.trim().isEmpty)
                ? 'Câmp obligatoriu'
                : null,
          ),
        );
        if (wide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: first),
              const SizedBox(width: 14),
              Expanded(child: last),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            first,
            const SizedBox(height: 14),
            last,
          ],
        );
      },
    );
  }
}

class _SeriesPicker extends ConsumerWidget {
  const _SeriesPicker({
    required this.selectedSeries,
    required this.inputDeco,
    required this.onChanged,
    required this.seriesLabel,
  });
  final WorkshopSeries? selectedSeries;
  final InputDecoration inputDeco;
  final ValueChanged<WorkshopSeries?> onChanged;
  final String Function(WorkshopSeries) seriesLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final seriesAsync = ref.watch(activeSeriesForDemoProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChildFormField(
          label: 'Selectează atelierul',
          required: true,
          child: seriesAsync.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text(
              'Eroare la încărcare: $e',
              style: TextStyle(color: theme.colorScheme.error),
            ),
            data: (seriesList) => DropdownButtonFormField<WorkshopSeries>(
              key: ValueKey('demo-series-${selectedSeries?.id}'),
              initialValue: selectedSeries,
              isExpanded: true,
              decoration: inputDeco,
              items: seriesList
                  .map((s) => DropdownMenuItem<WorkshopSeries>(
                        value: s,
                        child: Text(
                          seriesLabel(s),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ))
                  .toList(),
              onChanged: onChanged,
              validator: (_) =>
                  selectedSeries == null ? 'Selectează un atelier' : null,
            ),
          ),
        ),
        if (selectedSeries != null) ...[
          const SizedBox(height: 12),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.purple.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: AppColors.purple.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                const Icon(Icons.person_pin_outlined,
                    size: 16, color: AppColors.purple),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Trainer: ${selectedSeries!.trainerName ?? '—'}  ·  '
                    '${selectedSeries!.workshopType ?? ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.purple,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _DateTimePickers extends StatelessWidget {
  const _DateTimePickers({
    required this.demoDate,
    required this.startTime,
    required this.endTime,
    required this.onPickDate,
    required this.onPickStart,
    required this.onPickEnd,
    required this.inputDeco,
  });
  final DateTime demoDate;
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final VoidCallback onPickDate;
  final VoidCallback onPickStart;
  final VoidCallback onPickEnd;
  final InputDecoration inputDeco;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget readonlyField({
      required String label,
      required String value,
      required IconData icon,
      required VoidCallback onTap,
      bool required = false,
    }) {
      return ChildFormField(
        label: label,
        required: required,
        child: GestureDetector(
          onTap: onTap,
          child: AbsorbPointer(
            child: TextFormField(
              readOnly: true,
              controller: TextEditingController(text: value),
              decoration: inputDeco.copyWith(
                suffixIcon: Icon(icon, size: 18,
                    color: theme.colorScheme.outline),
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        readonlyField(
          label: 'Data demo',
          value: formatDate(demoDate),
          icon: Icons.calendar_today_outlined,
          onTap: onPickDate,
          required: true,
        ),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (context, box) {
          final wide = box.maxWidth >= 360;
          final start = readonlyField(
            label: 'Ora start',
            value: startTime.format(context),
            icon: Icons.access_time_rounded,
            onTap: onPickStart,
            required: true,
          );
          final end = readonlyField(
            label: 'Ora final',
            value: endTime.format(context),
            icon: Icons.access_time_rounded,
            onTap: onPickEnd,
            required: true,
          );
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: start),
                const SizedBox(width: 14),
                Expanded(child: end),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              start,
              const SizedBox(height: 14),
              end,
            ],
          );
        }),
      ],
    );
  }
}

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../core/widgets/app_buttons.dart';

// ── InputDecoration factory ───────────────────────────────────────────────────

InputDecoration buildChildFormInputDeco(ThemeData theme) {
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide:
        BorderSide(color: theme.colorScheme.outline.withValues(alpha: 0.4)),
  );
  return InputDecoration(
    filled: true,
    fillColor: theme.scaffoldBackgroundColor,
    border: inputBorder,
    enabledBorder: inputBorder,
    focusedBorder: inputBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.purple, width: 1.5)),
    errorBorder: inputBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.error, width: 1.5)),
    focusedErrorBorder: inputBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.error, width: 1.5)),
    contentPadding:
        const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
  );
}

// ── Form field wrapper with label ─────────────────────────────────────────────

class ChildFormField extends StatelessWidget {
  const ChildFormField({
    super.key,
    required this.label,
    required this.child,
    this.required = false,
  });
  final String label;
  final Widget child;
  final bool required;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontWeight: FontWeight.w600)),
          if (required)
            const Text(' *',
                style: TextStyle(color: AppColors.error, fontSize: 12)),
        ]),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

// ── Access denied view ────────────────────────────────────────────────────────
class ChildFormAccessDenied extends StatelessWidget {
  const ChildFormAccessDenied({super.key});

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
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/children'),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline_rounded,
                size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text('Acces interzis',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text('Doar administratorii pot gestiona copiii.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}

// ── Save row (error + cancel + submit) ────────────────────────────────────────

class ChildFormSaveRow extends StatelessWidget {
  const ChildFormSaveRow({
    super.key,
    required this.saving,
    required this.isEditing,
    required this.onSave,
    this.saveError,
    this.createLabel = 'Adaugă copil',
    this.cancelFallbackRoute = '/children',
  });

  final bool saving;
  final bool isEditing;
  final VoidCallback onSave;
  final String? saveError;

  /// Label for the primary button when creating a new entity.
  /// Defaults to "Adaugă copil" because the widget was originally
  /// written for the child form; callers on other forms (workshops,
  /// demo workshops) pass the appropriate label.
  final String createLabel;

  /// Where the Cancel button navigates when the current route can't be
  /// popped. Defaults to the children list for the same historical
  /// reason as [createLabel].
  final String cancelFallbackRoute;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (saveError != null) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.error.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppColors.error.withValues(alpha: 0.25)),
            ),
            child: Row(children: [
              const Icon(Icons.error_outline,
                  color: AppColors.error, size: 18),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(saveError!,
                      style: const TextStyle(
                          color: AppColors.error, fontSize: 13))),
            ]),
          ),
          const SizedBox(height: 16),
        ],
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: saving
                  ? null
                  : () => context.canPop()
                      ? context.pop()
                      : context.go(cancelFallbackRoute),
              child: const Text('Anulează'),
            ),
            const SizedBox(width: 12),
            saving
                ? const SizedBox(
                    width: 110,
                    child: Center(
                        child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: AppColors.purple))))
                : AppPrimaryButton(
                    label: isEditing ? 'Salvează' : createLabel,
                    icon: isEditing
                        ? Icons.save_outlined
                        : Icons.add_rounded,
                    onPressed: onSave,
                  ),
          ],
        ),
      ],
    );
  }
}

// ── Section card for form grouping ────────────────────────────────────────────

class ChildSectionCard extends StatelessWidget {
  const ChildSectionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.child,
    this.subtitle,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
              child: Icon(icon, size: 16, color: AppColors.purple),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700))),
          ]),
          if (subtitle != null) ...[
            const SizedBox(height: 6),
            Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
          ],
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

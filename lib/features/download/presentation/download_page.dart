import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';

/// Public marketing/download page reachable at `/download`.
///
/// No authentication required — the router redirect explicitly allowlists
/// this path for both signed-out and signed-in users so a parent or staff
/// member already inside the app can still hand the URL out without being
/// bounced to their dashboard.
///
/// Hosts a single Windows-installer download link plus a secondary CTA
/// that routes the visitor into the web app's login screen. Designed to
/// look like a clean product landing page consistent with the rest of
/// TTH Manager (same `AppColors.purple` accent, same scaffold background,
/// same card radii and outline style).
class DownloadPage extends StatelessWidget {
  const DownloadPage({super.key});

  /// Public URL of the Windows build.
  ///
  /// Uses GitHub's permanent `/releases/latest/download/<asset-name>`
  /// alias so this constant never needs to be bumped per release —
  /// GitHub redirects to the current "Latest" release automatically.
  /// The asset name is kept stable across releases (`TTH-Manager-
  /// Windows.zip`) for this reason.
  static const String _installerUrl =
      'https://github.com/angheltofan/TTH-Manager/releases/latest/download/TTH-Manager-Windows.zip';

  static const String _appVersion = 'Ultima versiune';
  static const String _platformNote =
      'Arhivă ZIP · Windows 10 și Windows 11 · extrage și rulează tth_manager_app.exe';

  Future<void> _downloadInstaller(BuildContext context) async {
    final uri = Uri.parse(_installerUrl);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Descărcarea nu a putut fi pornită. Reîncearcă.'),
        ),
      );
    }
  }

  void _openWebApp(BuildContext context) {
    context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 720;
            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: isWide ? 32 : 20,
                vertical: 32,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: _DownloadCard(
                    theme: theme,
                    isWide: isWide,
                    onDownload: () => _downloadInstaller(context),
                    onOpenWebApp: () => _openWebApp(context),
                    version: _appVersion,
                    platformNote: _platformNote,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DownloadCard extends StatelessWidget {
  const _DownloadCard({
    required this.theme,
    required this.isWide,
    required this.onDownload,
    required this.onOpenWebApp,
    required this.version,
    required this.platformNote,
  });

  final ThemeData theme;
  final bool isWide;
  final VoidCallback onDownload;
  final VoidCallback onOpenWebApp;
  final String version;
  final String platformNote;

  @override
  Widget build(BuildContext context) {
    final logoSize = isWide ? 112.0 : 88.0;
    final titleStyle = (isWide
            ? theme.textTheme.headlineMedium
            : theme.textTheme.headlineSmall)
        ?.copyWith(
      fontWeight: FontWeight.w800,
      letterSpacing: -0.4,
      color: theme.colorScheme.onSurface,
      height: 1.15,
    );

    return Container(
      padding: EdgeInsets.fromLTRB(
        isWide ? 36 : 24,
        isWide ? 40 : 28,
        isWide ? 36 : 24,
        isWide ? 32 : 24,
      ),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.28),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(
            'assets/branding/tth_logo.png',
            width: logoSize,
            height: logoSize,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 18),
          Text(
            'TTH Manager',
            textAlign: TextAlign.center,
            style: titleStyle,
          ),
          const SizedBox(height: 6),
          Text(
            'Aplicație de management pentru Tales & Tech HUB',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              fontWeight: FontWeight.w500,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 28),
          _PlatformSectionHeader(
            label: 'Windows',
            icon: Icons.window_rounded,
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onDownload,
              icon: const Icon(Icons.download_rounded, size: 20),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  'Descarcă pentru Windows',
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700),
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.purple,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            version,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            platformNote,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline.withValues(alpha: 0.85),
              fontSize: 11.5,
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onOpenWebApp,
              icon: const Icon(Icons.public_rounded, size: 18),
              label: const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  'Deschide aplicația web',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.purple,
                side: BorderSide(
                    color: AppColors.purple.withValues(alpha: 0.4)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Section heading shown above each platform's download CTA. Currently
/// only "Windows" is rendered, but the same widget will scale cleanly
/// when macOS / Linux / mobile installers are added later.
class _PlatformSectionHeader extends StatelessWidget {
  const _PlatformSectionHeader({
    required this.label,
    required this.icon,
  });

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurface.withValues(alpha: 0.78);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers/auth_providers.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      await ref.read(authRepositoryProvider).signIn(
            email: _emailController.text.trim(),
            password: _passwordController.text,
          );
      // Intentionally do NOT call `context.go('/dashboard')` here.
      //
      // The router's redirect guard reacts to the Supabase auth-state
      // event and to `currentProfileProvider` resolving — it sends the
      // user to `/parent` or `/dashboard` based on the actual role.
      // Hard-coding `/dashboard` here previously caused parent users
      // to briefly see the staff shell while the profile loaded.
      //
      // We keep `_loading = true` on success so the spinner stays
      // visible until the redirect swaps this page off-screen.
    } catch (e, stack) {
      if (kDebugMode) debugPrint('[Auth] signIn failed: $e\n$stack');
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_friendlyAuthError(e)),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  /// Maps low-level auth / transport exceptions to short Romanian
  /// messages the user can act on. The raw exception is still logged
  /// to the debug console for developer inspection but is never shown.
  ///
  /// Discrimination rules:
  ///   • `AuthRetryableFetchException` — transport-level failure (no
  ///     HTTP response). Typical on iOS Safari behind a content
  ///     blocker, on a captive-portal Wi-Fi, or when the device has no
  ///     working DNS. `statusCode` is null. Message: friendly
  ///     "verifică conexiunea".
  ///   • `AuthException` (`invalid_credentials`, `email_not_confirmed`)
  ///     — server returned an actual error. Distinct message.
  ///   • Any other `AuthException` — generic auth-server message.
  ///   • Anything else (unlikely) — generic fallback that never shows
  ///     the raw exception string.
  String _friendlyAuthError(Object e) {
    if (e is AuthRetryableFetchException) {
      return 'Nu s-a putut realiza conexiunea cu serverul. '
          'Verifică conexiunea la internet și încearcă din nou.';
    }
    if (e is AuthApiException) {
      final code = e.code ?? '';
      final message = e.message.toLowerCase();
      if (code == 'invalid_credentials' ||
          message.contains('invalid login credentials') ||
          message.contains('invalid credentials')) {
        return 'Email sau parolă incorectă.';
      }
      if (code == 'email_not_confirmed' ||
          message.contains('email not confirmed')) {
        return 'Contul nu este confirmat. Verifică email-ul primit la înregistrare.';
      }
      if (code == 'user_not_found' ||
          message.contains('user not found')) {
        return 'Nu există un cont cu acest email.';
      }
      if (e.statusCode == '429' || message.contains('rate limit')) {
        return 'Prea multe încercări. Așteaptă un minut și reîncearcă.';
      }
      // Generic Supabase auth error — keep it short + non-technical.
      return 'Autentificare eșuată. Verifică datele și încearcă din nou.';
    }
    if (e is AuthException) {
      return 'Autentificare eșuată. Verifică datele și încearcă din nou.';
    }
    // Any other error type — never leak the raw exception string.
    return 'A apărut o eroare neașteptată. Te rugăm să încerci din nou.';
  }

  @override
  Widget build(BuildContext context) {
    // resizeToAvoidBottomInset: false keeps the Scaffold from shrinking.
    // The SingleChildScrollView + viewInsets.bottom padding handles keyboard.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 24,
            bottom: bottomInset + 24,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Image.asset(
                        'assets/branding/tth_logo.png',
                        width: 80,
                        height: 80,
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(
                      child: Text(
                        'TTH Manager',
                        style:
                            Theme.of(context).textTheme.headlineMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    TextFormField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.emailAddress,
                      validator: (v) =>
                          v == null || v.isEmpty ? 'Introduceți emailul' : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      decoration: const InputDecoration(
                        labelText: 'Parolă',
                        border: OutlineInputBorder(),
                      ),
                      obscureText: true,
                      validator: (v) =>
                          v == null || v.isEmpty ? 'Introduceți parola' : null,
                    ),
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Autentificare'),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/supabase/supabase_client_provider.dart';
import '../core/widgets/app_shell.dart';
import '../features/auth/domain/app_profile.dart';
import '../features/assistant/presentation/assistant_page.dart';
import '../features/auth/presentation/auth_callback_page.dart';
import '../features/auth/presentation/login_page.dart';
import '../features/auth/presentation/parent_setup_page.dart';
import '../features/auth/presentation/set_password_page.dart';
import '../features/auth/providers/auth_providers.dart';
import '../features/children/presentation/child_attendance_calendar_page.dart';
import '../features/children/presentation/child_details_page.dart';
import '../features/children/presentation/child_form_page.dart';
import '../features/children/presentation/children_page.dart';
import '../features/dashboard/presentation/dashboard_page.dart';
import '../features/parent/presentation/parent_about_page.dart';
import '../features/parent/presentation/parent_dashboard_page.dart';
import '../features/parent/presentation/parent_profile_page.dart';
import '../features/parent/presentation/parent_shell.dart';
import '../features/payments_due/presentation/payments_due_page.dart';
import '../features/settings/presentation/settings_page.dart';
import '../features/notifications/presentation/notifications_page.dart';
import '../features/trainers/presentation/trainer_details_page.dart';
import '../features/trainers/presentation/trainers_page.dart';
import '../features/workshops/presentation/workshop_details_page.dart';
import '../features/demo_workshops/presentation/demo_workshop_details_page.dart';
import '../features/demo_workshops/presentation/demo_workshop_form_page.dart';
import '../features/download/presentation/download_page.dart';
import '../features/team_chat/presentation/team_chat_page.dart';
import '../features/workshops/presentation/workshop_form_page.dart';
import '../features/workshops/presentation/workshop_series_page.dart';

/// A [ChangeNotifier] that listens to Supabase auth-state changes and
/// notifies GoRouter to re-evaluate its redirect guard. Also exposes a
/// public [refresh] hook so the [routerProvider] can re-trigger redirect
/// evaluation once the async [currentProfileProvider] resolves a role.
class _AuthNotifier extends ChangeNotifier {
  _AuthNotifier(SupabaseClient client) {
    _isLoggedIn = client.auth.currentSession != null;
    _subscription = client.auth.onAuthStateChange.listen((event) {
      final loggedIn = event.session != null;
      if (loggedIn != _isLoggedIn) {
        _isLoggedIn = loggedIn;
        notifyListeners();
      }
    });
  }

  late final StreamSubscription<AuthState> _subscription;
  bool _isLoggedIn = false;
  bool get isLoggedIn => _isLoggedIn;

  /// Re-emit a change notification. Called by the [routerProvider] when the
  /// current profile role transitions, so the redirect guard can re-run.
  void refresh() => notifyListeners();

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}

final routerProvider = Provider<GoRouter>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final authNotifier = _AuthNotifier(client);
  ref.onDispose(authNotifier.dispose);

  // Re-evaluate the redirect guard when the profile role resolves or
  // changes (e.g. async fetch completes after login, account switch).
  // The auth-state stream already fires on sign-in/sign-out — this covers
  // the gap between "logged in" and "role known".
  ref.listen<AsyncValue<AppProfile?>>(currentProfileProvider, (prev, next) {
    final prevRole = prev?.valueOrNull?.role;
    final nextRole = next.valueOrNull?.role;
    if (prevRole != nextRole) authNotifier.refresh();
  });

  return GoRouter(
    initialLocation: '/login',
    refreshListenable: authNotifier,
    redirect: (context, state) {
      final loggedIn = authNotifier.isLoggedIn;
      final path = state.matchedLocation;
      final isLoginRoute = path == '/login';
      // The callback page processes Supabase invite/recovery URLs and
      // performs its own navigation once a session is established. It
      // must be reachable without a prior session, and must not be
      // bounced by the role redirects below either.
      final isCallbackRoute = path == '/auth/callback';
      // The set-password page is reached by any logged-in user (parent
      // accepting an invite, anyone after a password-recovery email).
      // It manages its own routing on submit, so the role gates below
      // must leave it alone.
      final isSetPasswordRoute = path == '/set-password';
      // The parent-setup page is the code-based fallback for the invite
      // flow (used when an email security scanner consumed the magic
      // link). It also handles its own post-submit navigation and must
      // be reachable both before AND after the OTP exchange logs the
      // user in.
      final isParentSetupRoute = path == '/parent-setup';
      // Public marketing/download page. Reachable by anyone, signed in
      // or not — both branches of the guard below skip it so a parent
      // already logged in can share the URL without being bounced back
      // to their dashboard.
      final isDownloadRoute = path == '/download';

      if (!loggedIn) {
        return (isLoginRoute ||
                isCallbackRoute ||
                isParentSetupRoute ||
                isDownloadRoute)
            ? null
            : '/login';
      }

      // Logged in. The callback, set-password, parent-setup and download
      // pages handle their own navigation; the role gates below ignore
      // them.
      if (isCallbackRoute) return null;
      if (isSetPasswordRoute) return null;
      if (isParentSetupRoute) return null;
      if (isDownloadRoute) return null;

      final profile = ref.read(currentProfileProvider).valueOrNull;
      final isParentRoute =
          path == '/parent' || path.startsWith('/parent/');

      // Profile not yet resolved → we don't know the role.
      //
      // Critical: do NOT default to the staff shell here. Doing so
      // briefly mounted [AppShell] for parent users after they signed
      // in (the "Admin/Trainer UI flash" before the Parent Portal
      // takes over). Instead, park the user on the login page until
      // [currentProfileProvider] resolves — the listener above re-runs
      // this redirect as soon as the role is known. The login page
      // shows its own loading spinner during that window.
      //
      // Already-loaded routes (a deep link straight into /parent or
      // /dashboard after a session was restored at cold start) are
      // also bounced back to /login while the role loads, so neither
      // shell can render with the wrong role. The cold-start case is
      // additionally covered by `startupBootstrapProvider` which keeps
      // the branded splash visible until the profile is ready.
      if (profile == null) {
        return isLoginRoute ? null : '/login';
      }

      final isParent = profile.isParent;

      if (isLoginRoute) {
        // Post-login destination depends on role.
        return isParent ? '/parent' : '/dashboard';
      }

      if (isParent && !isParentRoute) {
        // Parent must never reach admin/trainer screens.
        return '/parent';
      }
      if (!isParent && isParentRoute) {
        // Staff (or unknown non-parent role) bounced off /parent.
        return '/dashboard';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: '/auth/callback',
        builder: (context, state) => const AuthCallbackPage(),
      ),
      GoRoute(
        path: '/set-password',
        builder: (context, state) => const SetPasswordPage(),
      ),
      GoRoute(
        path: '/parent-setup',
        builder: (context, state) => const ParentSetupPage(),
      ),
      // Public download page — no shell, no auth required.
      GoRoute(
        path: '/download',
        builder: (context, state) => const DownloadPage(),
      ),
      // ── Parent portal ────────────────────────────────────────────────
      //
      // One persistent `ShellRoute` wraps every `/parent/*` page in
      // [ParentShell] → [ParentResponsiveScaffold]. Navigating between
      // Dashboard / Informații centru / Setări swaps only the `child`
      // slot — sidebar, top bar, bottom nav and the
      // `parentNotificationsRealtimeProvider` channel stay mounted, and
      // the long-lived `parentLinkedChildrenBaseProvider` /
      // `parentEnrollmentsProvider` cache survives navigation untouched.
      ShellRoute(
        // Parent shell deliberately uses `NoTransitionPage` for every
        // route instead of the default `MaterialPage`. The default
        // Material page transition fades the outgoing page over the
        // incoming one for ~300 ms, which on this shell reads as
        // "fragments from the previous page". `NoTransitionPage` swaps
        // the slot in a single frame.
        //
        // Each page carries a stable, unique `ValueKey`. GoRouter uses
        // the Page key to decide whether a route entry is the same
        // element as the previous tree's, so a per-route key ensures
        // the framework REPLACES the page subtree (rather than
        // attempting to reuse it across routes), eliminating any
        // chance of a stale element painting through the new page.
        builder: (context, state, child) => ParentShell(child: child),
        routes: [
          GoRoute(
            path: '/parent',
            pageBuilder: (context, state) => const NoTransitionPage(
              key: ValueKey('parent-dashboard'),
              child: ParentDashboardPage(
                key: PageStorageKey('parent-dashboard-content'),
              ),
            ),
          ),
          GoRoute(
            path: '/parent/info',
            pageBuilder: (context, state) => const NoTransitionPage(
              key: ValueKey('parent-info'),
              child: ParentAboutPage(
                key: PageStorageKey('parent-info-content'),
              ),
            ),
          ),
          GoRoute(
            path: '/parent/settings',
            pageBuilder: (context, state) => const NoTransitionPage(
              key: ValueKey('parent-settings'),
              child: ParentProfilePage(
                key: PageStorageKey('parent-settings-content'),
              ),
            ),
          ),
          GoRoute(
            path: '/parent/notifications',
            // Reuses the same NotificationsPage as the staff route — its
            // queries are already scoped to the current `recipient_id`
            // and contain no admin-only mutations.
            pageBuilder: (context, state) => const NoTransitionPage(
              key: ValueKey('parent-notifications'),
              child: NotificationsPage(
                key: PageStorageKey('parent-notifications-content'),
              ),
            ),
          ),
        ],
      ),
      // Aliases for the prior path names so existing browser bookmarks /
      // deep links still resolve.
      GoRoute(
        path: '/parent/about',
        redirect: (context, state) => '/parent/info',
      ),
      GoRoute(
        path: '/parent/profile',
        redirect: (context, state) => '/parent/settings',
      ),
      GoRoute(
        // The parent portal intentionally has no separate child-details
        // page — the dashboard child cards are the single child surface.
        // The route is kept registered so deep links and browser-history
        // entries from older builds resolve to a valid page instead of
        // 404-ing; everything redirects to `/parent`.
        path: '/parent/children/:id',
        redirect: (context, state) => '/parent',
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (context, state) => const DashboardPage(),
          ),
          GoRoute(
            path: '/payments-due',
            builder: (context, state) => const PaymentsDuePage(),
          ),
          GoRoute(
            path: '/workshops/new',
            builder: (context, state) => const WorkshopFormPage(),
          ),
          GoRoute(
            path: '/workshops/:id',
            builder: (context, state) => WorkshopDetailsPage(
              workshopId: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/workshops/:id/edit',
            builder: (context, state) => WorkshopFormPage(
              workshopId: state.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/workshop-series/:id',
            builder: (context, state) => WorkshopSeriesPage(
              seriesId: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/children',
            builder: (context, state) => const ChildrenPage(),
          ),
          GoRoute(
            path: '/children/new',
            builder: (context, state) => const ChildFormPage(),
          ),
          GoRoute(
            path: '/children/:id',
            builder: (context, state) => ChildDetailsPage(
              childId: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/children/:id/edit',
            builder: (context, state) => ChildFormPage(
              childId: state.pathParameters['id'],
            ),
          ),
          GoRoute(
            path: '/children/:id/attendance-calendar',
            builder: (context, state) => ChildAttendanceCalendarPage(
              childId: state.pathParameters['id']!,
            ),
          ),
          // TTH Assistant (staff-only, parent-blocked by the redirect
          // guard above + a defensive role check inside [AssistantPage]).
          GoRoute(
            path: '/assistant',
            builder: (context, state) => const AssistantPage(),
          ),
          // Trainer administration moved out of the sidebar. Now lives
          // under Setări → Echipa centrului. The flat `/trainers` URL
          // is kept as a redirect so older bookmarks resolve.
          GoRoute(
            path: '/trainers',
            redirect: (context, state) => '/settings/team',
          ),
          GoRoute(
            path: '/settings/team',
            builder: (context, state) => const TrainersPage(),
          ),
          GoRoute(
            path: '/trainers/:id',
            builder: (context, state) => TrainerDetailsPage(
              trainerId: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/settings/team/:id',
            builder: (context, state) => TrainerDetailsPage(
              trainerId: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsPage(),
          ),
          GoRoute(
            path: '/notifications',
            builder: (context, state) => const NotificationsPage(),
          ),
          GoRoute(
            path: '/demo-workshops/new',
            builder: (context, state) => const DemoWorkshopFormPage(),
          ),
          GoRoute(
            path: '/demo-workshops/:id',
            builder: (context, state) => DemoWorkshopDetailsPage(
              demoId: state.pathParameters['id']!,
            ),
          ),
          GoRoute(
            path: '/team-chat',
            builder: (context, state) => const TeamChatPage(),
          ),
        ],
      ),
    ],
  );
});

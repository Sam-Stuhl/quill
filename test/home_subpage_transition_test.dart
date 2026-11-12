import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quill/data/flavor_config.dart';
import 'package:quill/data/prefs.dart';
import 'package:quill/data/routes.dart';
import 'package:quill/main.dart';
import 'package:quill/pages/home/home.dart';

void main() {
  group('Home subpage transition', () {
    for (final brightness in Brightness.values)
      testWidgets(brightness.name, (tester) async {
        FlavorConfig.setup();
        stows.sentryConsent.value = .granted;
        stows.layoutSize.value = .phone;

        final router = GoRouter(
          initialLocation: App.initialLocation,
          routes: [
            GoRoute(
              path: RoutePaths.home,
              builder: (context, state) => HomePage(
                subpage:
                    state.pathParameters['subpage'] ?? HomePage.recentSubpage,
                path: state.uri.queryParameters['path'],
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          MaterialApp.router(
            title: 'Quill',
            routeInformationProvider: router.routeInformationProvider,
            routeInformationParser: router.routeInformationParser,
            routerDelegate: router.routerDelegate,
          ),
        );

        await tester.tap(find.byIcon(Icons.settings));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          [find.text('Welcome to Quill'), find.text('Logged out')],
          [findsOneWidget, findsOneWidget],
        );
      });
  });
}

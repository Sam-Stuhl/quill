import 'package:flutter_test/flutter_test.dart';
import 'package:golden_screenshot/golden_screenshot.dart';
import 'package:material_ui/material_ui.dart';
import 'package:quill/components/home/syncing_button.dart';
import 'package:quill/data/file_manager/file_manager.dart';
import 'package:quill/data/flavor_config.dart';
import 'package:quill/data/prefs.dart';
import 'package:quill/data/sentry/_sentry_init_foss.dart';
import 'package:quill/i18n/strings.g.dart';
import 'package:quill/pages/home/home.dart';

import 'screenshot_goldens_test.dart';
import 'utils/test_mock_channel_handlers.dart';
import 'utils/test_user.dart';

void main() {
  group('simplifiedHomeLayout', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    disableSentryForTesting();

    FlavorConfig.setup();
    SyncingButton.debugForceButtonActive = true;

    stows.lastStorageQuota.value = TestUser.getQuota();
    stows.username.value = 'myusername';
    stows.sentryConsent.value = .granted;
    stows.homeLayout.value = .simpleGrid;

    setUpAll(() async {
      await FileManager.init(shouldWatchRootDirectory: false);
      await setupDemoFiles();
    });

    testGoldens('golden', (tester) async {
      final device = GoldenSmallDevices.androidPhone.device;

      final widget = ScreenshotApp.withConditionalTitlebar(
        device: device,
        title: 'Quill',
        home: TranslationProvider(
          child: const HomePage(subpage: HomePage.recentSubpage, path: ''),
        ),
      );
      await tester.pumpWidget(widget);
      await tester.pump();

      await tester.loadAssets();
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/home_simplified_layout.png'),
      );
    });
  });
}

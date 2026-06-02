import 'package:flutter_test/flutter_test.dart';
import 'package:omi/services/frontend_template_router.dart';

void main() {
  group('FrontendTemplateRouter', () {
    final config = FrontendTemplateRoutingConfig.defaults().copyWith(
      enabled: true,
      workPrompt: 'Summarize this as work context.',
      personalPrompt: 'Summarize this as personal context.',
    );

    test('selects work profile Monday through Friday at the start time', () {
      final mondayAtEight = DateTime(2026, 5, 25, 8);

      expect(FrontendTemplateRouter.selectProfile(mondayAtEight, config), FrontendTemplateProfile.work);
    });

    test('selects work profile before the end time', () {
      final fridayBeforeFive = DateTime(2026, 5, 29, 16, 59);

      expect(FrontendTemplateRouter.selectProfile(fridayBeforeFive, config), FrontendTemplateProfile.work);
    });

    test('selects personal profile exactly at the end time', () {
      final fridayAtFive = DateTime(2026, 5, 29, 17);

      expect(FrontendTemplateRouter.selectProfile(fridayAtFive, config), FrontendTemplateProfile.personal);
    });

    test('selects personal profile on weekends', () {
      final saturdayAtNoon = DateTime(2026, 5, 30, 12);

      expect(FrontendTemplateRouter.selectProfile(saturdayAtNoon, config), FrontendTemplateProfile.personal);
    });

    test('falls back from startedAt to createdAt', () {
      final createdAt = DateTime(2026, 5, 25, 10);

      expect(FrontendTemplateRouter.conversationLocalTime(startedAt: null, createdAt: createdAt), createdAt);
    });

    test('uses startedAt when available', () {
      final createdAt = DateTime(2026, 5, 25, 22);
      final startedAt = DateTime(2026, 5, 25, 9);

      expect(FrontendTemplateRouter.conversationLocalTime(startedAt: startedAt, createdAt: createdAt), startedAt);
    });

    test('composes prompt with profile, local time, source, and user prompt', () {
      final prompt = FrontendTemplateRouter.buildPrompt(
        profile: FrontendTemplateProfile.work,
        conversationLocalTime: DateTime(2026, 5, 25, 8, 30),
        sourceName: 'omi',
        profilePrompt: 'Extract decisions and next actions.',
      );

      expect(prompt, contains('Routing profile: Work'));
      expect(prompt, contains('Conversation local time: Monday, 2026-05-25 08:30'));
      expect(prompt, contains('Conversation source: omi'));
      expect(prompt, contains('Extract decisions and next actions.'));
    });

    test('round trips config JSON', () {
      final original = config.copyWith(workStartMinutes: 9 * 60, workEndMinutes: 18 * 60);
      final decoded = FrontendTemplateRoutingConfig.fromJson(original.toJson());

      expect(decoded.enabled, isTrue);
      expect(decoded.workStartMinutes, 9 * 60);
      expect(decoded.workEndMinutes, 18 * 60);
      expect(decoded.workPrompt, 'Summarize this as work context.');
      expect(decoded.personalPrompt, 'Summarize this as personal context.');
    });

    test('round trips backend template app ids', () {
      final withApps = config.copyWith(workAppId: 'app-work-1', personalAppId: 'app-personal-2');
      final decoded = FrontendTemplateRoutingConfig.fromJson(withApps.toJson());

      expect(decoded.workAppId, 'app-work-1');
      expect(decoded.personalAppId, 'app-personal-2');
      expect(decoded.appIdFor(FrontendTemplateProfile.work), 'app-work-1');
      expect(decoded.appIdFor(FrontendTemplateProfile.personal), 'app-personal-2');
    });

    test('appIdFor returns null and usesTemplateFor is false when no template selected', () {
      final noApps = FrontendTemplateRoutingConfig.defaults();
      expect(noApps.appIdFor(FrontendTemplateProfile.work), isNull);
      expect(noApps.appIdFor(FrontendTemplateProfile.personal), isNull);
      expect(noApps.usesTemplateFor(FrontendTemplateProfile.work), isFalse);
    });

    test('a profile is configured with either a backend template or a prompt', () {
      // Work via template, Personal via prompt -> fully configured.
      final mixed = FrontendTemplateRoutingConfig.defaults()
          .copyWith(enabled: true, workAppId: 'app-1', personalPrompt: 'Personal summary.');
      expect(mixed.usesTemplateFor(FrontendTemplateProfile.work), isTrue);
      expect(mixed.isConfiguredFor(FrontendTemplateProfile.work), isTrue);
      expect(mixed.isConfiguredFor(FrontendTemplateProfile.personal), isTrue);
      expect(mixed.isFullyConfigured, isTrue);

      // Personal has neither template nor prompt -> not fully configured.
      final missingPersonal =
          FrontendTemplateRoutingConfig.defaults().copyWith(enabled: true, workPrompt: 'Work summary.');
      expect(missingPersonal.isConfiguredFor(FrontendTemplateProfile.personal), isFalse);
      expect(missingPersonal.isFullyConfigured, isFalse);
    });

    test('result cache freshness depends on profile, hash, and conversation time', () {
      final conversationTime = DateTime(2026, 5, 25, 9);
      final hash = FrontendTemplateRouter.expectedPromptHash(
        config: config,
        profile: FrontendTemplateProfile.work,
        conversationLocalTime: conversationTime,
        sourceName: 'omi',
      );
      final result = FrontendTemplateRoutingResult(
        conversationId: 'conversation-1',
        profile: FrontendTemplateProfile.work,
        promptHash: hash,
        content: 'Routed content',
        generatedAt: DateTime(2026, 5, 25, 9, 1),
        conversationStartedAt: conversationTime,
      );

      expect(
        result.isFreshFor(
          profile: FrontendTemplateProfile.work,
          promptHash: hash,
          conversationStartedAt: conversationTime,
        ),
        isTrue,
      );
      expect(
        result.isFreshFor(
          profile: FrontendTemplateProfile.personal,
          promptHash: hash,
          conversationStartedAt: conversationTime,
        ),
        isFalse,
      );
      expect(
        result.isFreshFor(
          profile: FrontendTemplateProfile.work,
          promptHash: 'different-hash',
          conversationStartedAt: conversationTime,
        ),
        isFalse,
      );
      expect(
        result.isFreshFor(
          profile: FrontendTemplateProfile.work,
          promptHash: hash,
          conversationStartedAt: conversationTime.add(const Duration(minutes: 1)),
        ),
        isFalse,
      );
    });

    test('prompt hash changes when routing schedule changes', () {
      final conversationTime = DateTime(2026, 5, 25, 9);
      final baselineHash = FrontendTemplateRouter.expectedPromptHash(
        config: config,
        profile: FrontendTemplateProfile.work,
        conversationLocalTime: conversationTime,
        sourceName: 'omi',
      );
      final shiftedWorkHoursHash = FrontendTemplateRouter.expectedPromptHash(
        config: config.copyWith(workStartMinutes: 7 * 60, workEndMinutes: 16 * 60),
        profile: FrontendTemplateProfile.work,
        conversationLocalTime: conversationTime,
        sourceName: 'omi',
      );

      expect(shiftedWorkHoursHash, isNot(baselineHash));
    });
  });
}

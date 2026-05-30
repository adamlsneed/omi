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
  });
}

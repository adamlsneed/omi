import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/frontend_template_router.dart';

void main() {
  group('Frontend template routing preferences', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await SharedPreferencesUtil.init();
    });

    test('defaults routing to disabled', () {
      final store = FrontendTemplateRoutingStore();

      expect(store.loadConfig().enabled, isFalse);
    });

    test('persists routing config JSON', () async {
      final store = FrontendTemplateRoutingStore();
      final config = FrontendTemplateRoutingConfig.defaults().copyWith(
        enabled: true,
        workPrompt: 'Work prompt',
        personalPrompt: 'Personal prompt',
      );

      await store.saveConfig(config);

      final saved = store.loadConfig();
      expect(saved.enabled, isTrue);
      expect(saved.workPrompt, 'Work prompt');
      expect(saved.personalPrompt, 'Personal prompt');
    });

    test('persists routed results keyed by conversation id', () async {
      final store = FrontendTemplateRoutingStore();
      final result = FrontendTemplateRoutingResult(
        conversationId: 'conversation-1',
        profile: FrontendTemplateProfile.work,
        promptHash: 'hash',
        content: 'Summary',
        generatedAt: DateTime(2026, 5, 25, 9, 1),
        conversationStartedAt: DateTime(2026, 5, 25, 9),
      );

      await store.saveResult(result);

      final raw = SharedPreferencesUtil().frontendTemplateRoutingResultsJson;
      expect(jsonDecode(raw), contains('conversation-1'));
      expect(store.resultForConversation('conversation-1')?.content, 'Summary');
    });

    test('ignores corrupt stored config', () async {
      SharedPreferencesUtil().frontendTemplateRoutingConfigJson = '{not valid json';

      expect(FrontendTemplateRoutingStore().loadConfig().enabled, isFalse);
    });
  });
}

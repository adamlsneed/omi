import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/pages/conversation_detail/conversation_detail_provider.dart';
import 'package:omi/providers/conversation_provider.dart';
import 'package:omi/services/frontend_template_router.dart';

ServerConversation _completedConversationAt(DateTime localTime) {
  return ServerConversation(
    id: 'conv-1',
    createdAt: localTime.toUtc(),
    startedAt: localTime.toUtc(),
    structured: Structured('Weekend chat', 'Overview.', emoji: '🧠'),
    status: ConversationStatus.completed,
  );
}

ConversationDetailProvider _providerFor(ServerConversation conversation) {
  final provider = ConversationDetailProvider();
  addTearDown(provider.dispose);
  provider.selectedDate = conversationLocalDayKey(conversation.createdAt);
  provider.setCachedConversation(conversation);
  return provider;
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  test('a profile with its own prompt is not blocked by the other profile using a template', () async {
    // Regression: the prompt gate required both profile prompts to be set, but the
    // settings page accepts "Work via template, Personal via prompt". Every Personal
    // conversation then surfaced the missing-prompts error and never generated.
    final config = FrontendTemplateRoutingConfig.defaults().copyWith(
      enabled: true,
      autoRunOnOpen: false,
      workAppId: 'app-1',
      personalPrompt: 'Personal summary.',
    );
    await FrontendTemplateRoutingStore().saveConfig(config);

    // A Saturday morning routes to the Personal profile.
    final provider = _providerFor(_completedConversationAt(DateTime(2026, 9, 5, 10)));
    await provider.loadOrGenerateRoutedSummary();

    expect(provider.routedSummaryError, isNull);
    expect(provider.routedSummaryLoading, isFalse);
  });

  test('a profile with neither prompt nor template reports missing prompts', () async {
    final config = FrontendTemplateRoutingConfig.defaults().copyWith(
      enabled: true,
      autoRunOnOpen: false,
      workAppId: 'app-1',
    );
    await FrontendTemplateRoutingStore().saveConfig(config);

    final provider = _providerFor(_completedConversationAt(DateTime(2026, 9, 5, 10)));
    await provider.loadOrGenerateRoutedSummary();

    expect(provider.routedSummaryError, ConversationDetailProvider.routedSummaryMissingPromptsError);
  });
}

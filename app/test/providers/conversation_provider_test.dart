import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/backend/schema/structured.dart';
import 'package:omi/providers/conversation_provider.dart';

ServerConversation _conversation(String id, ConversationStatus status) {
  return ServerConversation(
    id: id,
    createdAt: DateTime(2026, 7, 9, 12),
    structured: Structured('Test conversation', ''),
    status: status,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SharedPreferencesUtil.init();
  });

  group('processing conversations watch', () {
    test('polls a processing conversation and moves it to the list once completed', () {
      fakeAsync((async) {
        final provider = ConversationProvider();
        final fetchedIds = <String>[];
        var completeAfterCalls = 2;
        provider.conversationByIdFetcher = (id) async {
          fetchedIds.add(id);
          final done = fetchedIds.length >= completeAfterCalls;
          return _conversation(id, done ? ConversationStatus.completed : ConversationStatus.processing);
        };

        provider.addProcessingConversation(_conversation('c1', ConversationStatus.processing));
        async.flushMicrotasks();

        // First poll fires immediately and sees the conversation still processing.
        expect(fetchedIds, ['c1']);
        expect(provider.processingConversations.length, 1);
        expect(provider.conversations, isEmpty);

        // Next periodic tick sees it completed and moves it into the main list.
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(fetchedIds, ['c1', 'c1']);
        expect(provider.processingConversations, isEmpty);
        expect(provider.conversations.map((c) => c.id), ['c1']);
        expect(provider.groupedConversations.values.expand((c) => c).map((c) => c.id), contains('c1'));

        // Watch stops once nothing is processing: no further fetches.
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(fetchedIds.length, 2);
      });
    });

    test('keeps the conversation in the processing list while the server still reports processing', () {
      fakeAsync((async) {
        final provider = ConversationProvider();
        var fetchCount = 0;
        provider.conversationByIdFetcher = (id) async {
          fetchCount++;
          return _conversation(id, ConversationStatus.processing);
        };

        provider.addProcessingConversation(_conversation('c1', ConversationStatus.processing));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();

        expect(fetchCount, 4);
        expect(provider.processingConversations.length, 1);
        expect(provider.conversations, isEmpty);
      });
    });

    test('fetch errors leave the processing conversation in place and polling alive', () {
      fakeAsync((async) {
        final provider = ConversationProvider();
        var fetchCount = 0;
        provider.conversationByIdFetcher = (id) async {
          fetchCount++;
          if (fetchCount == 1) throw Exception('network down');
          return _conversation(id, ConversationStatus.completed);
        };

        provider.addProcessingConversation(_conversation('c1', ConversationStatus.processing));
        async.flushMicrotasks();
        expect(provider.processingConversations.length, 1);

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(fetchCount, 2);
        expect(provider.processingConversations, isEmpty);
        expect(provider.conversations.map((c) => c.id), ['c1']);
      });
    });

    test('does not poll the local phone-capture placeholder', () {
      fakeAsync((async) {
        final provider = ConversationProvider();
        var fetchCount = 0;
        provider.conversationByIdFetcher = (id) async {
          fetchCount++;
          return null;
        };

        provider.addProcessingConversation(_conversation('0', ConversationStatus.processing));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();

        expect(fetchCount, 0);
        expect(provider.processingConversations.length, 1);
      });
    });
  });
}

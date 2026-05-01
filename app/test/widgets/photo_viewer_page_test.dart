import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/widgets/photo_viewer_page.dart';
import 'package:omi/widgets/photos_grid.dart';

void main() {
  Widget buildApp(Widget child) {
    return MaterialApp(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    );
  }

  ConversationPhoto photo({String id = 'photo-1', String? base64}) {
    return ConversationPhoto(
      id: id,
      base64: base64 ?? base64Encode(<int>[1, 2, 3, 4]),
      createdAt: DateTime(2026),
      description: 'A photo',
    );
  }

  testWidgets('handles empty photo list without throwing', (tester) async {
    await tester.pumpWidget(buildApp(const PhotoViewerPage(photos: [], initialIndex: 0)));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byType(PhotoViewerPage), findsOneWidget);
  });

  testWidgets('clamps an out-of-range initial index', (tester) async {
    await tester.pumpWidget(
      buildApp(
        PhotoViewerPage(
          photos: [photo()],
          initialIndex: 25,
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('A photo'), findsOneWidget);
  });

  testWidgets('shows a fallback instead of throwing for invalid base64 data', (tester) async {
    await tester.pumpWidget(
      buildApp(
        PhotoViewerPage(
          photos: [photo(base64: 'not valid base64')],
          initialIndex: 0,
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
  });

  testWidgets('photo grid shows a fallback instead of throwing for invalid base64 data', (tester) async {
    await tester.pumpWidget(
      buildApp(
        Scaffold(
          body: PhotosGridComponent(
            photos: [photo(base64: 'not valid base64')],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:omi/l10n/app_localizations.dart';
import 'package:omi/pages/phone_calls/phone_setup_verify_page.dart';
import 'package:omi/providers/phone_call_provider.dart';

class _SlowPhoneCallProvider extends ChangeNotifier implements PhoneCallProvider {
  int checkCalls = 0;

  @override
  Future<bool> checkVerification(String phoneNumber) async {
    checkCalls += 1;
    await Future<void>.delayed(const Duration(seconds: 5));
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Widget buildApp(_SlowPhoneCallProvider provider) {
    return ChangeNotifierProvider<PhoneCallProvider>.value(
      value: provider,
      child: const MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: PhoneSetupVerifyPage(phoneNumber: '+15555550123'),
      ),
    );
  }

  testWidgets('does not start overlapping verification checks while a slow check is in flight', (tester) async {
    final provider = _SlowPhoneCallProvider();
    addTearDown(provider.dispose);

    await tester.pumpWidget(buildApp(provider));

    await tester.pump(const Duration(seconds: 7));

    expect(provider.checkCalls, 1);
  });
}

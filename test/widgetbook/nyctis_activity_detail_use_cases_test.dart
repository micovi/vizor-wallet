import 'package:flutter/material.dart' show MaterialApp;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcash_wallet/src/core/theme/app_theme.dart';
import 'package:zcash_wallet/widgetbook/nyctis_activity_detail_use_cases.dart';

Future<void> _pump(
  WidgetTester tester,
  WidgetBuilder builder,
  AppThemeData theme,
) async {
  await tester.binding.setSurfaceSize(const Size(900, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: AppTheme(
        data: theme,
        child: Builder(builder: builder),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const themes = [AppThemeData.dark, AppThemeData.light];
  const builders = <WidgetBuilder>[
    buildNyctisActivityDetailSentUseCase,
    buildNyctisActivityDetailReceivedUseCase,
    buildNyctisActivityDetailNetChangeUseCase,
    buildNyctisActivityDetailNoMessageUseCase,
  ];

  testWidgets('every Nyctis receipt use case renders in both themes', (
    tester,
  ) async {
    for (final theme in themes) {
      for (final builder in builders) {
        await _pump(tester, builder, theme);
        expect(tester.takeException(), isNull);
      }
    }
  });

  testWidgets('no use case grows a recipient, a status or a fee', (
    tester,
  ) async {
    for (final builder in builders) {
      await _pump(tester, builder, AppThemeData.dark);
      expect(find.text('To'), findsNothing);
      expect(find.text('Recipient'), findsNothing);
      expect(find.text('Completed'), findsNothing);
      expect(find.text('Status'), findsNothing);
      expect(find.text('Tx fee'), findsNothing);
      expect(find.text('Fee'), findsNothing);
    }
  });

  testWidgets('the send fixture shows an output it cannot read as a count', (
    tester,
  ) async {
    await _pump(
      tester,
      buildNyctisActivityDetailSentUseCase,
      AppThemeData.dark,
    );

    expect(find.text('Outputs readable'), findsOneWidget);
    expect(find.text('1 of 2'), findsOneWidget);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_up/main.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('MeshChat smoke test', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});

    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(prefs),
        child: const MeshChatApp(),
      ),
    );

    expect(find.text('MeshChat'), findsOneWidget);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Scan'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  });
}

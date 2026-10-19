import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tw_matrix_spike/main.dart';
import 'package:tw_matrix_spike/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());
  testWidgets('shows initial status', (WidgetTester tester) async {
    await tester.pumpWidget(const MatrixSpikeApp());
    expect(find.textContaining('Not logged in'), findsOneWidget);
  });
}

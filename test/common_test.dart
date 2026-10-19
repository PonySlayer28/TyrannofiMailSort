import 'package:flutter_test/flutter_test.dart';
import 'package:tyrannofi_app/widgets/common.dart';

void main() {
  test('counted says Regel once and Regeln otherwise', () {
    expect(counted(1, 'Regel', 'Regeln'), '1 Regel');
    expect(counted(76, 'Regel', 'Regeln'), '76 Regeln');
    expect(counted(0, 'Regel', 'Regeln'), '0 Regeln');
  });
}

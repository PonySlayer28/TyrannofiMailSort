import 'package:flutter_test/flutter_test.dart';
import 'package:tyrannofi_app/widgets/common.dart';

void main() {
  test('counted says rule once and rules otherwise', () {
    expect(counted(1, 'rule', 'rules'), '1 rule');
    expect(counted(76, 'rule', 'rules'), '76 rules');
    expect(counted(0, 'rule', 'rules'), '0 rules');
  });
}

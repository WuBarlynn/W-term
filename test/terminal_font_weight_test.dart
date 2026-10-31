import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('terminal style applies configured weight and preserves bold runs', () {
    const style = TerminalStyle(fontWeight: FontWeight.w500);
    expect(style.toTextStyle().fontWeight, FontWeight.w500);
    expect(style.toTextStyle(bold: true).fontWeight, FontWeight.bold);
    expect(style.copyWith(fontWeight: FontWeight.w600).fontWeight,
        FontWeight.w600);
  });
}

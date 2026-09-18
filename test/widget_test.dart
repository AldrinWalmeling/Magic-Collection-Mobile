import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:magic_collection/widgets/deck_view.dart';
import 'package:magic_collection/widgets/mana_curve_chart.dart';

// Smoke tests dos componentes compartilhados de deck (sem rede,
// sem banco, sem Firebase).

Widget _wrap(Widget child) =>
    MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('DeckViewToggle alterna lista/grade', (t) async {
    var grid = false;
    await t.pumpWidget(_wrap(DeckViewToggle(
      grid: grid,
      onChanged: (v) => grid = v,
    )));
    expect(find.text('Grade'), findsOneWidget);
    await t.tap(find.text('Grade'));
    await t.pump();
    expect(grid, isTrue);
  });

  testWidgets('GridColumnsToggle escolhe 2 ou 3', (t) async {
    var cols = 2;
    await t.pumpWidget(_wrap(GridColumnsToggle(
      columns: cols,
      onChanged: (v) => cols = v,
    )));
    await t.tap(find.text('3'));
    await t.pump();
    expect(cols, 3);
  });

  testWidgets('ManaCurveChart mostra 0..6+ e valores', (t) async {
    await t.pumpWidget(_wrap(ManaCurveChart(
      curve: {for (var i = 0; i <= 6; i++) i: i},
    )));
    expect(find.text('6+'), findsOneWidget);
    expect(find.text('5'), findsWidgets);
    expect(find.text('0'), findsWidgets);
  });

  testWidgets('CardGridTile mostra nome e quantidade', (t) async {
    await t.pumpWidget(_wrap(const CardGridTile(
      imageUrl: '',
      name: 'Relâmpago',
      qtyText: '4x',
    )));
    expect(find.text('Relâmpago'), findsOneWidget);
    expect(find.text('4x'), findsOneWidget);
  });
}

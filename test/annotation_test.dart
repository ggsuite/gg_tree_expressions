// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_golden/gg_golden.dart';
import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  group('Annotation', () {
    group('constructor', () {
      test('should keep rule key, variant index and value', () {
        const annotation = Annotation(
          ruleKey: 'hint',
          variantIndex: 2,
          value: [1, 2],
        );
        expect(annotation.ruleKey, 'hint');
        expect(annotation.variantIndex, 2);
        expect(annotation.value, [1, 2]);
      });

      test('should default the value to null', () {
        const annotation = Annotation(ruleKey: 'hint', variantIndex: 0);
        expect(annotation.value, isNull);
      });
    });

    group('toString()', () {
      test('should render rule key, variant index and value', () {
        const annotation = Annotation(
          ruleKey: 'hint',
          variantIndex: 1,
          value: 'tip',
        );
        expect(annotation.toString(), 'hint[1] = tip');
      });
    });

    group('toJson()', () {
      test('should serialize rule key, variant index and value', () {
        const annotation = Annotation(
          ruleKey: 'hint',
          variantIndex: 1,
          value: {'text': 'tip'},
        );
        expect(annotation.toJson(), {
          'ruleKey': 'hint',
          'variantIndex': 1,
          'value': {'text': 'tip'},
        });
      });

      test('should serialize a missing value as null', () {
        const annotation = Annotation(ruleKey: 'hint', variantIndex: 0);
        expect(annotation.toJson(), {
          'ruleKey': 'hint',
          'variantIndex': 0,
          'value': null,
        });
      });
    });

    group('example()', () {
      test('serializes the example annotation (golden)', () async {
        final json = Annotation.example().toJson();
        await writeGolden('annotation_example.json', json);

        expect(json, {
          'ruleKey': 'borderHelp',
          'variantIndex': 0,
          'value': {'unit': 'px', 'text': 'Width of the dialog border.'},
        });

        // It is what annotating with the example book yields.
        final help = RuleBook.example().ruleForKey('borderHelp')!;
        expect(help.variants[0].value, Annotation.example().value);
      });
    });
  });
}

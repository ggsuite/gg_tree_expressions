// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

void main() {
  group('ProvenanceEntry', () {
    group('toString()', () {
      test('should render a minimal rule entry', () {
        const e = ProvenanceEntry(
          location: '/dialog#borderWidth',
          kind: ProvenanceKind.rule,
          ruleKey: '§borderWidth',
          variantIndex: 2,
          value: 3.0,
        );
        expect(e.toString(), '/dialog#borderWidth ← §borderWidth[2] = 3.0');
      });

      test('should render a rich rule entry with all detail', () {
        const e = ProvenanceEntry(
          location: '/d#w',
          kind: ProvenanceKind.rule,
          ruleKey: '§w',
          variantIndex: 1,
          value: 3.0,
          selector: {'theme#id': 'dark'},
          inputs: {'screenWidth': 380.0},
          expression: 'screenWidth < 400.0 ? 3.0 : 2.0',
          aliasChain: ['§a', '§w'],
        );
        final s = e.toString();
        expect(s, contains('/d#w ← §w[1] = 3.0'));
        expect(s, contains('selector {theme#id: dark}'));
        expect(s, contains('inputs {screenWidth: 380.0}'));
        expect(s, contains('expr "screenWidth < 400.0 ? 3.0 : 2.0"'));
        expect(s, contains('via §a → §w'));
      });

      test('should skip empty selector/inputs and single-key chain', () {
        const e = ProvenanceEntry(
          location: '/n#v',
          kind: ProvenanceKind.rule,
          ruleKey: '§v',
          variantIndex: 0,
          value: 1.0,
          selector: {},
          inputs: {},
          expression: '1.0',
          aliasChain: ['§v'],
        );
        final s = e.toString();
        expect(s, contains('expr "1.0"'));
        expect(s, isNot(contains('selector')));
        expect(s, isNot(contains('inputs')));
        expect(s, isNot(contains('via')));
      });

      test('should render an inline entry', () {
        const e = ProvenanceEntry(
          location: '/n#twice',
          kind: ProvenanceKind.inline,
          value: 10,
        );
        expect(e.toString(), '/n#twice ← inline = 10');
      });

      test('should render an optional-removal entry', () {
        const e = ProvenanceEntry(
          location: '/n#opt',
          kind: ProvenanceKind.optionalRemoval,
          ruleKey: '§opt',
        );
        expect(e.toString(), '/n#opt ← §opt (optional) removed');
      });
    });

    group('toJson()', () {
      test('should serialize a rich rule entry', () {
        const e = ProvenanceEntry(
          location: '/d#w',
          kind: ProvenanceKind.rule,
          ruleKey: '§w',
          variantIndex: 1,
          value: 3.0,
          selector: {'theme#id': 'dark'},
          inputs: {'x': 380.0},
          expression: 'x',
          aliasChain: ['§w'],
        );
        expect(e.toJson(), {
          'location': '/d#w',
          'kind': 'rule',
          'ruleKey': '§w',
          'variantIndex': 1,
          'value': 3.0,
          'selector': {'theme#id': 'dark'},
          'inputs': {'x': 380.0},
          'expression': 'x',
          'aliasChain': ['§w'],
        });
      });

      test('should omit null rich fields (minimal rule)', () {
        const e = ProvenanceEntry(
          location: '/n#v',
          kind: ProvenanceKind.rule,
          ruleKey: '§v',
          variantIndex: 0,
          value: 5,
        );
        expect(e.toJson(), {
          'location': '/n#v',
          'kind': 'rule',
          'ruleKey': '§v',
          'variantIndex': 0,
          'value': 5,
        });
      });

      test('should omit ruleKey/variantIndex for inline', () {
        const e = ProvenanceEntry(
          location: '/n#i',
          kind: ProvenanceKind.inline,
          value: 2,
        );
        expect(e.toJson(), {'location': '/n#i', 'kind': 'inline', 'value': 2});
      });

      test('should omit value for an optional removal', () {
        const e = ProvenanceEntry(
          location: '/n#o',
          kind: ProvenanceKind.optionalRemoval,
          ruleKey: '§o',
        );
        expect(e.toJson(), {
          'location': '/n#o',
          'kind': 'optionalRemoval',
          'ruleKey': '§o',
        });
      });
    });
  });

  group('ResolutionReport', () {
    ProvenanceEntry entry(String location, String key) => ProvenanceEntry(
      location: location,
      kind: ProvenanceKind.rule,
      ruleKey: key,
      variantIndex: 0,
      value: 1,
    );

    test('should expose an unmodifiable entry list', () {
      final report = ResolutionReport(entries: [entry('/a#x', '§x')]);
      expect(report.entries, hasLength(1));
      expect(report.rich, isFalse);
      expect(
        () => report.entries.add(entry('/b#y', '§y')),
        throwsUnsupportedError,
      );
    });

    test('should filter entries by location (alias hops)', () {
      final report = ResolutionReport(
        entries: [
          entry('/a#x', '§x'),
          entry('/a#x', '§y'),
          entry('/b#z', '§z'),
        ],
      );
      expect(report.at('/a#x').map((e) => e.ruleKey), ['§x', '§y']);
      expect(report.at('/b#z').map((e) => e.ruleKey), ['§z']);
      expect(report.at('/nope'), isEmpty);
    });

    test('should dump minimal and rich modes', () {
      final minimal = ResolutionReport(entries: [entry('/a#x', '§x')]);
      expect(
        minimal.toString(),
        'ResolutionReport (1 entries, minimal):\n'
        '  /a#x ← §x[0] = 1',
      );

      final rich = ResolutionReport(entries: [entry('/a#x', '§x')], rich: true);
      expect(
        rich.toString(),
        startsWith('ResolutionReport (1 entries, rich):'),
      );
    });

    test('should serialize to JSON', () {
      final report = ResolutionReport(
        entries: [entry('/a#x', '§x')],
        rich: true,
      );
      expect(report.toJson(), {
        'rich': true,
        'entries': [
          {
            'location': '/a#x',
            'kind': 'rule',
            'ruleKey': '§x',
            'variantIndex': 0,
            'value': 1,
          },
        ],
      });
    });
  });
}

// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_golden/gg_golden.dart';
import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';
import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

/// Mimics a consumer's typed tree data: a zero-cost extension type
/// over `Json`. Guards that `resolveAtomic` works on such trees.
extension type _JsonNode(Json data) implements Json {}

void main() {
  Tree<Json> node(
    String key,
    Json data, [
    List<Tree<Json>> children = const [],
  ]) => Tree<Json>(key: key, data: data, children: children);

  TreeExpressionsException? catchException(void Function() call) {
    try {
      call();
    } on TreeExpressionsException catch (e) {
      return e;
    }
    return null;
  }

  String messageOfCall(void Function() call) =>
      catchException(call)?.message ?? '';

  Resolver resolver(Json bookJson) =>
      Resolver(ruleBook: RuleBook.fromJson(bookJson));

  Json ref(String key) => {'§': key};

  /// The architecture doc §4 example.
  final borderBook = {
    'borderWidth': [
      {'expression': '1.0'},
      {
        'selector': {'theme#id': 'dark'},
        'expression': '2.0',
      },
      {
        'selector': {'theme#id': 'dark', '#platform': 'mobile'},
        'inputs': {'screenWidth': 'screen#width'},
        'expression': 'screenWidth < 400.0 ? 3.0 : 2.0',
      },
    ],
  };

  Tree<Json> appTree() => node(
    'app',
    {'platform': 'mobile'},
    [
      node('theme', {'id': 'dark'}),
      node('screen', {'width': 380.0}),
      node(
        'dialog',
        {'borderWidth': ref('borderWidth')},
        [node('okButton', {})],
      ),
    ],
  );

  group('Resolver', () {
    group('constructor', () {
      test('should compile all rule expressions eagerly', () {
        final e = catchException(
          () => resolver({
            'bad': [
              {'expression': '1 +'},
            ],
          }),
        );
        expect(e, isA<ExpressionException>());
        expect(e!.message, contains('In rule "bad", variant 0:'));
        expect(e.message, contains('Syntax error'));
      });

      test('should compile only the expressions that exist', () {
        // A value that merely looks like broken CEL is data, not source.
        final cache = <String, CompiledExpression>{};
        Resolver(
          ruleBook: RuleBook.fromJson({
            'doc': [
              {'value': '1 +'},
              {'expression': '2.0'},
            ],
          }),
          expressionCache: cache,
        );
        expect(cache.keys, ['2.0']);
      });

      test('should still compile the when of a value variant eagerly', () {
        final e = catchException(
          () => resolver({
            'doc': [
              {'when': '1 +', 'value': 'x'},
            ],
          }),
        );
        expect(e, isA<ExpressionException>());
        expect(e!.message, contains('variant 0, "when"'));
      });

      test('should share an injected expression cache', () {
        final cache = <String, CompiledExpression>{};
        final book = RuleBook.fromJson({
          'w': [
            {'expression': '1.0 + 2.0'},
          ],
        });

        // First resolver populates the shared cache.
        Resolver(ruleBook: book, expressionCache: cache);
        expect(cache.keys, contains('1.0 + 2.0'));
        final compiled = cache['1.0 + 2.0'];

        // A second resolver reuses the same compiled expression and
        // still resolves correctly.
        final r2 = Resolver(ruleBook: book, expressionCache: cache);
        expect(identical(cache['1.0 + 2.0'], compiled), isTrue);
        final resolved = r2.resolve(node('n', {'v': ref('w')}), inPlace: true);
        expect(resolved.getOrNull<double>('./#v'), 3.0);
      });
    });

    group('resolveVerbose()', () {
      test('should report minimal provenance for a rule', () {
        final book = {
          'w': [
            {'expression': '1.0 + 2.0'},
          ],
        };
        final (resolved, report) = resolver(book)
            .resolveVerbose(node('root', {'v': ref('w')}), inPlace: true);
        expect(resolved.getOrNull<double>('./#v'), 3.0);
        expect(report.rich, isFalse);
        final e = report.entries.single;
        expect(e.location, '/#v');
        expect(e.kind, ProvenanceKind.rule);
        expect(e.ruleKey, 'w');
        expect(e.variantIndex, 0);
        expect(e.value, 3.0);
        expect(e.selector, isNull);
        expect(e.inputs, isNull);
        expect(e.expression, isNull);
        expect(e.aliasChain, isNull);
      });

      test('should report rich provenance for a rule (copy mode)', () {
        final (_, report) = resolver(borderBook)
            .resolveVerbose(appTree(), rich: true);
        expect(report.rich, isTrue);
        final e = report.at('/dialog#borderWidth').single;
        expect(e.kind, ProvenanceKind.rule);
        expect(e.ruleKey, 'borderWidth');
        expect(e.variantIndex, 2);
        expect(e.value, 3.0);
        expect(e.selector, {'theme#id': 'dark', '#platform': 'mobile'});
        expect(e.inputs, {'screenWidth': 380.0});
        expect(e.expression, 'screenWidth < 400.0 ? 3.0 : 2.0');
        expect(e.aliasChain, ['borderWidth']);
      });

      test('should report inline provenance (minimal and rich)', () {
        Tree<Json> tree() => node('root', {
          'x': {'§expression': '2 * 3'},
        });
        final (_, min) = resolver({}).resolveVerbose(tree(), inPlace: true);
        final eMin = min.entries.single;
        expect(eMin.kind, ProvenanceKind.inline);
        expect(eMin.ruleKey, isNull);
        expect(eMin.variantIndex, isNull);
        expect(eMin.value, 6);
        expect(eMin.expression, isNull);

        final (_, rich) = resolver({})
            .resolveVerbose(tree(), inPlace: true, rich: true);
        final e = rich.entries.single;
        expect(e.expression, '2 * 3');
        expect(e.inputs, isEmpty);
        expect(e.selector, isNull);
        expect(e.aliasChain, isEmpty);
      });

      test('should report optional-removal provenance (minimal/rich)', () {
        final book = {
          'opt': {
            'optional': true,
            'variants': [
              {
                'selector': {'#nope': true},
                'expression': '1',
              },
            ],
          },
        };
        final (rMin, repMin) = resolver(book)
            .resolveVerbose(node('root', {'m': ref('opt')}), inPlace: true);
        expect(rMin.getOrNull<dynamic>('./#m'), isNull);
        final e = repMin.entries.single;
        expect(e.kind, ProvenanceKind.optionalRemoval);
        expect(e.ruleKey, 'opt');
        expect(e.variantIndex, isNull);
        expect(e.value, isNull);
        expect(e.aliasChain, isNull);

        final (_, repRich) = resolver(book).resolveVerbose(
          node('root', {'m': ref('opt')}),
          inPlace: true,
          rich: true,
        );
        expect(repRich.entries.single.aliasChain, ['opt']);
      });

      test('should record one entry per alias hop with the chain', () {
        final book = {
          'a': [
            {'expression': "{'§': 'b'}"},
          ],
          'b': [
            {'expression': '42'},
          ],
        };
        final (resolved, report) = resolver(book).resolveVerbose(
          node('root', {'v': ref('a')}),
          inPlace: true,
          rich: true,
        );
        expect(resolved.getOrNull<dynamic>('./#v'), 42);

        final hops = report.at('/#v').toList();
        expect(hops.map((e) => e.ruleKey), ['a', 'b']);
        expect(hops.first.value, {'§': 'b'});
        expect(hops.first.aliasChain, ['a']);
        expect(hops.last.value, 42);
        expect(hops.last.aliasChain, ['a', 'b']);
      });
    });

    group('resolveAtomic()', () {
      final book = {
        'w': [
          {'expression': '1.0 + 2.0'},
        ],
      };

      test('should resolve in place, incl. children, and return it', () {
        final child = node('child', {'cv': ref('w')});
        final root = node('root', {'rv': ref('w')}, [child]);
        final result = resolver(book).resolveAtomic(root);
        expect(identical(result, root), isTrue);
        expect(root.getOrNull<double>('./#rv'), 3.0);
        // Child data was transplanted; the child node itself is kept.
        expect(identical(root.childByPath('child'), child), isTrue);
        expect(child.getOrNull<double>('./#cv'), 3.0);
      });

      test('should leave the tree untouched on error', () {
        final root = node('root', {'good': ref('w'), 'bad': ref('missing')});
        expect(
          () => resolver(book).resolveAtomic(root),
          throwsA(isA<UnknownRuleException>()),
        );
        // Nothing was written back: both references are still present.
        expect(root.getOrNull<Json>('./#good'), {'§': 'w'});
        expect(root.getOrNull<Json>('./#bad'), {'§': 'missing'});
      });

      test('should transplant optional removals', () {
        final optionalBook = {
          'opt': {
            'optional': true,
            'variants': [
              {
                'selector': {'#nope': true},
                'expression': '1',
              },
            ],
          },
        };
        final root = node('root', {'keep': 1, 'maybe': ref('opt')});
        resolver(optionalBook).resolveAtomic(root);
        expect(root.getOrNull<dynamic>('./#maybe'), isNull);
        expect(root.getOrNull<dynamic>('./#keep'), 1);
      });

      test('should require the tree root', () {
        final root = node('root', {}, [
          node('child', {'v': ref('w')}),
        ]);
        final e = catchException(
          () => resolver(book).resolveAtomic(root.childByPath('child')),
        );
        expect(e, isA<ResolveException>());
        expect(e!.message, contains('root'));
      });

      test('should work on an extension-type-over-Json tree', () {
        // A consumer's typed-tree shape: Tree<extension type over Json>.
        final tree = Tree<_JsonNode>(
          key: 'root',
          data: _JsonNode(<String, dynamic>{'v': ref('w')}),
        );
        final result = resolver(book).resolveAtomic(tree);
        expect(identical(result, tree), isTrue);
        expect(tree.getOrNull<double>('./#v'), 3.0);
      });

      test('should write back only the nodes whose data changed', () {
        final child = node('child', {
          'q': 1,
          'nested': {
            'list': [1, 2],
          },
          'a': 3,
        });
        final root = node('root', {'z': 1, 'm': ref('w'), 'c': 2}, [child]);

        final childData = child.data;
        final nested = child.data['nested'] as Map<String, dynamic>;
        final list = nested['list'];

        resolver(book).resolveAtomic(root);

        // The untouched node keeps its map and everything nested in it,
        // in the original key order.
        expect(identical(child.data, childData), isTrue);
        expect(identical(child.data['nested'], nested), isTrue);
        expect(identical(nested['list'], list), isTrue);
        expect(child.data.keys, ['q', 'nested', 'a']);

        // The changed node got its resolved value, at the same position.
        expect(root.data.keys, ['z', 'm', 'c']);
        expect(root.data['m'], 3.0);
      });

      test('should adopt deep changes and leave other branches alone', () {
        final grandchild = node('grandchild', {'v': ref('w'), 'a': 1});
        final sibling = node('sibling', {
          'b': {
            'n': [1],
          },
          'a': 1,
        });
        final root = node(
          'root',
          {'x': 0},
          [
            node('child', {'k': 1}, [grandchild]),
            sibling,
          ],
        );
        final siblingData = sibling.data;
        final siblingNested = sibling.data['b'];

        resolver(book).resolveAtomic(root);

        expect(grandchild.data.keys, ['v', 'a']);
        expect(grandchild.data['v'], 3.0);
        expect(identical(sibling.data, siblingData), isTrue);
        expect(identical(sibling.data['b'], siblingNested), isTrue);
        expect(sibling.data.keys, ['b', 'a']);
      });
    });

    group('resolve()', () {
      test('should resolve the architecture doc example', () {
        final resolved = resolver(borderBook).resolve(appTree());

        final dialog = resolved.childByPath('dialog');
        expect(dialog.getOrNull<double>('./#borderWidth'), 3.0);

        // Children read the resolved value via plain inheritance.
        final okButton = resolved.childByPath('dialog/okButton');
        expect(okButton.getOrNull<double>('#borderWidth'), 3.0);
      });

      test('should return a copy and keep the original intact', () {
        final app = appTree();
        final resolved = resolver(borderBook).resolve(app);
        expect(app.childByPath('dialog').getOrNull<Json>('./#borderWidth'), {
          '§': 'borderWidth',
        });
        expect(identical(resolved, app), isFalse);
      });

      test('should mutate the tree with inPlace', () {
        final app = appTree();
        final resolved = resolver(borderBook).resolve(app, inPlace: true);
        expect(identical(resolved, app), isTrue);
        expect(
          app.childByPath('dialog').getOrNull<double>('./#borderWidth'),
          3.0,
        );
      });

      test('should be idempotent', () {
        final resolved = resolver(borderBook).resolve(appTree());
        final again = resolver(borderBook).resolve(resolved);
        expect(deeplEquals(again.toJson(), resolved.toJson()), isTrue);
      });

      test('should support resolve → grow → resolve loops', () {
        final book = resolver({
          'w': [
            {'expression': '1.5'},
          ],
        });
        final tree = book.resolve(node('root', {'w': ref('w')}));
        expect(tree.getOrNull<double>('./#w'), 1.5);

        node('grown', {'w2': ref('w')}, const []).parent = tree;
        final again = book.resolve(tree, inPlace: true);
        expect(again.childByPath('grown').getOrNull<double>('./#w2'), 1.5);
      });

      test('should treat §-strings as plain data everywhere', () {
        // Strings are never references: values, selector literals,
        // and inputs all see them as ordinary data.
        final tree = node('root', {
          'law': '§ 5 Abs. 2',
          'label': 'note',
          'copy': ref('copyLabel'),
          'kind': ref('kind'),
        });
        final resolved = resolver({
          'copyLabel': [
            {
              'inputs': {'l': './#label'},
              'expression': 'l',
            },
          ],
          'kind': [
            {'expression': "'other'"},
            {
              'selector': {'./#label': 'note'},
              'expression': "'note'",
            },
          ],
        }).resolve(tree);
        expect(resolved.getOrNull<String>('./#law'), '§ 5 Abs. 2');
        expect(resolved.getOrNull<String>('./#label'), 'note');
        expect(resolved.getOrNull<String>('./#copy'), 'note');
        expect(resolved.getOrNull<String>('./#kind'), 'note');
      });

      test('should defer until selector context is resolved', () {
        final book = {
          ...borderBook,
          'themeId': [
            {'expression': "'dark'"},
          ],
        };
        final app = appTree();
        app.childByPath('theme').data['id'] = ref('themeId');
        final resolved = resolver(book).resolve(app);
        expect(
          resolved.childByPath('theme').getOrNull<dynamic>('./#id'),
          'dark',
        );
        expect(
          resolved.childByPath('dialog').getOrNull<dynamic>('./#borderWidth'),
          3.0,
        );
      });

      test('should defer until input values are resolved', () {
        // The dependents come first in data order, so they are
        // attempted (and deferred) before '#w' resolves.
        final tree = node('root', {
          'doubled': ref('double'),
          'twice': {
            '§expression': 'v * 2',
            '§inputs': {'v': '#w'},
          },
          'w': ref('five'),
        });
        final resolved = resolver({
          'five': [
            {'expression': '5'},
          ],
          'double': [
            {
              'inputs': {'v': '#w'},
              'expression': 'v * 2',
            },
          ],
        }).resolve(tree);
        expect(resolved.getOrNull<dynamic>('./#twice'), 10);
        expect(resolved.getOrNull<dynamic>('./#doubled'), 10);
      });

      test('should resolve markers nested in maps and lists', () {
        final tree = node('root', {
          'cfg': {
            'sizes': [ref('five'), 2],
            'inner': {'w': ref('five')},
          },
        });
        final resolved = resolver({
          'five': [
            {'expression': '5'},
          ],
        }).resolve(tree);
        expect(resolved.getOrNull<dynamic>('./#cfg'), {
          'sizes': [5, 2],
          'inner': {'w': 5},
        });
      });

      test('should reject non-root subtrees in copy mode', () {
        final app = appTree();
        final dialog = app.childByPath('dialog');
        final e = catchException(() => resolver(borderBook).resolve(dialog));
        expect(e, isA<ResolveException>());
        expect(e!.message, contains('subtree at "/dialog"'));
        expect(e.message, contains('inPlace: true'));
      });

      test('should resolve subtrees in place with full context', () {
        final app = appTree();
        final dialog = app.childByPath('dialog');
        resolver(borderBook).resolve(dialog, inPlace: true);
        expect(dialog.getOrNull<dynamic>('./#borderWidth'), 3.0);
      });

      test('should keep locations exact for result keys with "#"', () {
        final message = messageOfCall(
          () => resolver({
            'wrap': [
              {'expression': "{'a#b': {'§': 'inner'}}"},
            ],
            'inner': [
              {
                'selector': {'#never': 1},
                'expression': '1',
              },
            ],
          }).resolve(node('root', {'cfg': ref('wrap')})),
        );
        expect(message, contains('at "/#cfg/a#b"'));
      });

      test('should keep reference-like strings in results as data', () {
        final resolved = resolver({
          'label': [
            {'expression': "'nobody'"},
          ],
        }).resolve(node('root', {'x': ref('label')}));
        expect(resolved.getOrNull<String>('./#x'), 'nobody');
      });

      test('should reject markers matching no known form', () {
        final e = catchException(
          () => resolver({}).resolve(
            node('root', {
              'x': {'§expresion': '1.0'},
            }),
          ),
        );
        expect(e, isA<SchemaException>());
        expect(e!.message, contains('Invalid marker at "/#x"'));
        expect(e.message, contains('"§expresion"'));
        expect(e.message, contains('- reference:'));
      });

      test('should reject malformed references', () {
        for (final bad in [
          {'§': '9bad'},
          {'§': 'ok', 'extra': 1},
          {'§': 5},
        ]) {
          final e = catchException(
            () => resolver({}).resolve(node('root', {'x': bad})),
          );
          expect(e, isA<SchemaException>());
          expect(e!.message, contains('Invalid reference at "/#x"'));
        }
      });

      test('should resolve rule aliases', () {
        final tree = node('root', {'x': ref('alias')});
        final resolved = resolver({
          'alias': [
            {'expression': "{'§': 'target'}"},
          ],
          'target': [
            {'expression': '42'},
          ],
        }).resolve(tree);
        expect(resolved.getOrNull<dynamic>('./#x'), 42);
      });

      test('should resolve markers inside rule results', () {
        final tree = node('root', {'x': ref('wrap')});
        final resolved = resolver({
          'wrap': [
            {'expression': "{'inner': {'§': 'scalar'}, 'text': 'raw'}"},
          ],
          'scalar': [
            {'expression': '5'},
          ],
        }).resolve(tree);
        expect(resolved.getOrNull<dynamic>('./#x'), {
          'inner': 5,
          'text': 'raw',
        });
      });

      test('should detect circular rule aliases', () {
        final e = catchException(
          () => resolver({
            'a': [
              {'expression': "{'§': 'b'}"},
            ],
            'b': [
              {'expression': "{'§': 'a'}"},
            ],
          }).resolve(node('root', {'x': ref('a')})),
        );
        expect(e, isA<CircularAliasException>());
        expect(e!.message, contains('Circular rule alias at "/#x"'));
        expect(e.message, contains('a → b → a'));
        expect((e as CircularAliasException).chain, ['a', 'b', 'a']);
      });

      test('should stop expressions that regenerate themselves', () {
        const quine = "{'§expression': me, '§inputs': {'me': '#quine'}}";
        final tree = node('root', {
          'quine': quine,
          'x': {
            '§expression': quine,
            '§inputs': {'me': '#quine'},
          },
        });
        final e = catchException(() => resolver({}).resolve(tree));
        expect(e, isA<ResolveException>());
        expect(e!.message, contains('Resolution at "/#x" did not settle'));
        expect(e.message, contains('${Resolver.maxResolutionSteps} steps'));
      });

      test('should report unknown rules with suggestions', () {
        final e = catchException(
          () =>
              resolver(borderBook)
                  .resolve(node('root', {'x': ref('borderWith')})),
        );
        expect(e, isA<UnknownRuleException>());
        expect(e!.message, contains('Unknown rule "borderWith"'));
        expect(e.message, contains('Did you mean "borderWidth"?'));
        expect(e.message, contains('  - borderWidth'));
        final unknown = e as UnknownRuleException;
        expect(unknown.ruleKey, 'borderWith');
        expect(unknown.suggestions, ['borderWidth']);
      });

      test('should report unknown rules without close matches', () {
        final message = messageOfCall(
          () => resolver(borderBook).resolve(node('root', {'x': ref('zzz')})),
        );
        expect(message, contains('Unknown rule "zzz"'));
        expect(message, isNot(contains('Did you mean')));
      });

      test('should fail when no variant matches', () {
        final e = catchException(
          () => resolver({
            'sel': [
              {
                'selector': {'#platform': 'desktop'},
                'expression': '1',
              },
            ],
          }).resolve(node('root', {'platform': 'mobile', 'x': ref('sel')})),
        );
        expect(e, isA<NoVariantException>());
        expect(e!.message, contains('No variant of rule "sel"'));
        expect(e.message, contains('found "mobile"'));
        expect(e.message, contains('Add a base variant'));
      });

      test('should fail on ambiguous same-specificity matches', () {
        final e = catchException(
          () => resolver({
            'w': [
              {
                'selector': {'#a': 1},
                'expression': '1.0',
              },
              {
                'selector': {'#b': 2},
                'expression': '2.0',
              },
            ],
          }).resolve(node('root', {'a': 1, 'b': 2, 'v': ref('w')})),
        );
        expect(e, isA<AmbiguousVariantException>());
        final ambiguous = e! as AmbiguousVariantException;
        expect(ambiguous.ruleKey, 'w');
        expect(ambiguous.location, '/#v');
        expect(ambiguous.specificity, 1);
        expect(ambiguous.variantIndices, [0, 1]);
        expect(ambiguous.message, contains('the winner is ambiguous'));
      });

      test('should remove optional references that match nothing', () {
        final tree = node('root', {
          'platform': 'mobile',
          'a': ref('opt'),
          'xs': [ref('opt'), 2],
        });
        final resolved = resolver({
          'opt': {
            'optional': true,
            'variants': [
              {
                'selector': {'#platform': 'desktop'},
                'expression': '1',
              },
            ],
          },
        }).resolve(tree);
        expect(resolved.data.containsKey('a'), isFalse);
        expect(resolved.getOrNull<dynamic>('./#xs'), [null, 2]);
      });

      test('should validate declared result types', () {
        final book = {
          'n': {
            'resultType': 'number',
            'variants': [
              {'expression': "'nope'"},
            ],
          },
        };
        final message = messageOfCall(
          () => resolver(book).resolve(node('root', {'x': ref('n')})),
        );
        expect(message, contains('returned nope (String)'));
        expect(message, contains('resultType "number"'));

        final ok = resolver({
          'n': {
            'resultType': 'number',
            'variants': [
              {'expression': '1.0'},
            ],
          },
        }).resolve(node('root', {'x': ref('n')}));
        expect(ok.getOrNull<dynamic>('./#x'), 1.0);
      });

      test('should report stuck resolutions with all pending items', () {
        final tree = node('root', {
          'a': ref('aRule'),
          'b': {
            '§expression': 'x',
            '§inputs': {'x': '#a'},
          },
        });
        final e = catchException(
          () => resolver({
            'aRule': [
              {
                'selector': {'#b': 1},
                'expression': '1',
              },
            ],
          }).resolve(tree),
        );
        expect(e, isA<StuckException>());
        expect(e!.message, contains('Resolution is stuck: 2 item(s)'));
        expect(e.message, contains('reference "aRule" at "/#a"'));
        expect(e.message, contains('inline expression at "/#b"'));
        expect(e.message, contains('selector condition "#b" waits'));
        expect(e.message, contains('input "x" of the inline expression'));
        expect((e as StuckException).pending, hasLength(2));
      });

      test('should wrap deep-copy failures clearly', () {
        final tree = node('root', {'d': DateTime(2026)});
        final message = messageOfCall(() => resolver({}).resolve(tree));
        expect(message, contains('Cannot deep-copy the tree'));
        expect(message, contains('inPlace: true'));

        // The same tree resolves in place (no markers to touch).
        final resolved = resolver({}).resolve(tree, inPlace: true);
        expect(identical(resolved, tree), isTrue);
      });
    });

    group('resolve() — inputs', () {
      test('should apply defaults when queries resolve to nothing', () {
        final tree = node('root', {
          'm': ref('withMapDefault'),
          'l': ref('withListDefault'),
          's': ref('withScalarDefault'),
        });
        final resolved = resolver({
          'withMapDefault': [
            {
              'inputs': {
                'm': {
                  'query': '#missing',
                  'default': {'a': 1},
                },
              },
              'expression': 'm',
            },
          ],
          'withListDefault': [
            {
              'inputs': {
                'l': {
                  'query': '#missing',
                  'default': [1, 2],
                },
              },
              'expression': 'l[1]',
            },
          ],
          'withScalarDefault': [
            {
              'inputs': {
                's': {'query': '#missing', 'default': 4},
              },
              'expression': 's + 1',
            },
          ],
        }).resolve(tree);
        expect(resolved.getOrNull<dynamic>('./#m'), {'a': 1});
        expect(resolved.getOrNull<dynamic>('./#l'), 2);
        expect(resolved.getOrNull<dynamic>('./#s'), 5);
      });

      test('should fail on missing inputs without default', () {
        final e = catchException(
          () => resolver({
            'x': [
              {
                'inputs': {'w': '#missing'},
                'expression': 'w',
              },
            ],
          }).resolve(node('root', {'x': ref('x')})),
        );
        expect(e, isA<MissingInputException>());
        expect(e!.message, contains('Missing input "w" of rule "x"'));
        expect(e.message, contains('query "#missing" resolved to nothing'));
        expect((e as MissingInputException).inputName, 'w');
      });

      test('should wrap input shape errors with context', () {
        final e = catchException(
          () => resolver({
            'x': [
              {
                'inputs': {'w': './#num/deep'},
                'expression': 'w',
              },
            ],
          }).resolve(node('root', {'num': 5, 'x': ref('x')})),
        );
        expect(e, isA<QueryException>());
        expect(e!.message, contains('While binding input "w" of rule "x"'));
        expect(e.message, contains('is not a Map'));
      });

      test('should wrap evaluation errors with rule context', () {
        final e = catchException(
          () => resolver({
            'x': [
              {
                'inputs': {'w': '#w'},
                'expression': "w < 'text'",
              },
            ],
          }).resolve(node('root', {'w': 5, 'x': ref('x')})),
        );
        expect(e, isA<ExpressionException>());
        expect(
          e!.message,
          contains('While resolving rule "x" (variant 0) at "/#x"'),
        );
        expect(e.message, contains('not a subtype'));
      });
    });

    group('resolve() — inline expressions', () {
      test('should resolve plain inline expressions', () {
        final tree = node('root', {
          'x': {'§expression': '1.0 + 2.0'},
        });
        expect(resolver({}).resolve(tree).getOrNull<dynamic>('./#x'), 3.0);
      });

      test('should reject unknown keys in inline maps', () {
        final tree = node('root', {
          'x': {'§expression': '1.0', 'other': 1},
        });
        final e = catchException(() => resolver({}).resolve(tree));
        expect(e, isA<SchemaException>());
        expect(e!.message, contains('Invalid inline expression at "/#x"'));
        expect(e.message, contains('"other"'));
        expect(e.message, contains('  - §inputs'));
      });

      test('should reject invalid inline expressions', () {
        final tree = node('root', {
          'x': {'§expression': 5},
        });
        final message = messageOfCall(() => resolver({}).resolve(tree));
        expect(message, contains('Missing or empty "expression"'));
        expect(message, contains('inline expression at "/#x"'));
      });

      test('should wrap inline compile errors', () {
        final tree = node('root', {
          'x': {'§expression': '1 +'},
        });
        final message = messageOfCall(() => resolver({}).resolve(tree));
        expect(message, contains('In the inline expression at "/#x"'));
        expect(message, contains('Syntax error'));
      });

      test('should wrap inline evaluation errors', () {
        final tree = node('root', {
          'x': {'§expression': 'nope'},
        });
        final message = messageOfCall(() => resolver({}).resolve(tree));
        expect(message, contains('In the inline expression at "/#x"'));
        expect(message, contains('Unknown variable "nope"'));
      });
    });

    group('resolve() — when predicates', () {
      Json bookWithWhen() => {
        'w': [
          {'expression': '560.0'},
          {
            'when': 'h < 2000.0',
            'inputs': {'h': '#h'},
            'expression': '320.0',
          },
        ],
      };

      test('should apply a when-override over the base', () {
        final resolved = resolver(bookWithWhen())
            .resolve(node('root', {'h': 1500.0, 'v': ref('w')}));
        expect(resolved.getOrNull<double>('./#v'), 320.0);
      });

      test('should fall back to the base when the predicate is false', () {
        final resolved = resolver(bookWithWhen())
            .resolve(node('root', {'h': 2500.0, 'v': ref('w')}));
        expect(resolved.getOrNull<double>('./#v'), 560.0);
      });

      test('should defer a when that reads an unresolved value', () {
        final resolved = resolver({
          'height': [
            {'expression': '1500.0'},
          ],
          'w': [
            {'expression': '560.0'},
            {
              'when': 'h < 2000.0',
              'inputs': {'h': './#h'},
              'expression': '320.0',
            },
          ],
        }).resolve(node('root', {'h': ref('height'), 'v': ref('w')}));
        expect(resolved.getOrNull<double>('./#h'), 1500.0);
        expect(resolved.getOrNull<double>('./#v'), 320.0);
      });

      test('should reject a when that does not evaluate to a bool', () {
        final e = catchException(
          () => resolver({
            'w': [
              {'when': '1 + 1', 'expression': '1'},
            ],
          }).resolve(node('root', {'v': ref('w')})),
        );
        expect(e, isA<ExpressionException>());
        expect(e!.message, contains('must evaluate to a bool'));
      });

      test('should wrap a when evaluation error', () {
        // Compiles (valid syntax) but throws at eval: `ghost` is not
        // declared in inputs.
        final e = catchException(
          () => resolver({
            'w': [
              {'when': 'ghost > 1.0', 'expression': '1'},
            ],
          }).resolve(node('root', {'v': ref('w')})),
        );
        expect(e, isA<ExpressionException>());
        expect(e!.message, contains('While evaluating the "when"'));
      });

      test('should report a when compile error at construction', () {
        final e = catchException(
          () => resolver({
            'w': [
              {'when': '1 +', 'expression': '1'},
            ],
          }),
        );
        expect(e, isA<ExpressionException>());
        expect(e!.message, contains('variant 0, "when"'));
      });

      test('should fail on a missing when input without a default', () {
        final e = catchException(
          () => resolver({
            'w': [
              {
                'when': 'h < 1.0',
                'inputs': {'h': '#missing'},
                'expression': '1',
              },
            ],
          }).resolve(node('root', {'v': ref('w')})),
        );
        expect(e, isA<MissingInputException>());
      });

      test('should fail when two when-variants both apply', () {
        final e = catchException(
          () => resolver({
            'w': [
              {
                'when': 'h < 2000.0',
                'inputs': {'h': '#h'},
                'expression': '1',
              },
              {
                'when': 'wd > 1000.0',
                'inputs': {'wd': '#wd'},
                'expression': '2',
              },
            ],
          }).resolve(node('root', {'h': 1500.0, 'wd': 1200.0, 'v': ref('w')})),
        );
        expect(e, isA<AmbiguousVariantException>());
        expect(e!.message, contains('when "h < 2000.0"'));
        expect(e.message, contains('when "wd > 1000.0"'));
      });

      test('should ignore a dominated when-variant whose when errors', () {
        // Variant 0 (2 conditions, effSpec 4) outranks variant 1
        // (1 condition + when, effSpec 3). Variant 1's `when` is broken
        // (non-bool, and a missing input), but it is dominated and must
        // never be evaluated — resolution takes variant 0, no error.
        final resolved = resolver({
          'w': [
            {
              'selector': {'#a': 1, '#b': 2},
              'expression': '100.0',
            },
            {
              'selector': {'#a': 1},
              'when': '1 + 1',
              'inputs': {'h': '#missing'},
              'expression': '200.0',
            },
          ],
        }).resolve(node('root', {'a': 1, 'b': 2, 'v': ref('w')}));
        expect(resolved.getOrNull<double>('./#v'), 100.0);
      });
    });

    group('resolve() — value variants', () {
      Json docBook() => {
        'doc': [
          {
            'value': {
              'keys': ['width'],
            },
          },
          {
            'selector': {'#kind': 'door'},
            'value': ['door', 'docs'],
          },
        ],
      };

      test('should write the literal value of the winning variant', () {
        final resolved = resolver(docBook())
            .resolve(node('root', {'kind': 'door', 'x': ref('doc')}));
        expect(resolved.data['x'], ['door', 'docs']);

        final base = resolver(docBook())
            .resolve(node('root', {'x': ref('doc')}));
        expect(base.data['x'], {
          'keys': ['width'],
        });
      });

      test('should resolve scalar values, including falsy ones', () {
        final resolved =
            resolver({
              'off': [
                {'value': false},
              ],
              'zero': [
                {'value': 0},
              ],
              'empty': [
                {'value': ''},
              ],
            }).resolve(
              node('root', {
                'a': ref('off'),
                'b': ref('zero'),
                'c': ref('empty'),
              }),
            );
        expect(resolved.data, {'a': false, 'b': 0, 'c': ''});
      });

      test('should write an independent deep copy at every use', () {
        final r = resolver(docBook());
        final tree = node('root', {'x': ref('doc'), 'y': ref('doc')});
        final resolved = r.resolve(tree);

        final x = resolved.data['x'] as Map<String, dynamic>;
        (x['keys'] as List<dynamic>).add('height');

        // Neither the sibling, the book, nor a later resolve is affected.
        final pristine = {
          'keys': ['width'],
        };
        expect(resolved.data['y'], pristine);
        expect(r.ruleBook.toJson()['doc'], docBook()['doc']);
        expect(r.resolve(tree).data['x'], pristine);
      });

      test('should copy list values as well', () {
        final r = resolver({
          'list': [
            {
              'value': [
                'a',
                ['b'],
              ],
            },
          ],
        });
        final resolved = r.resolve(node('root', {'x': ref('list')}));
        ((resolved.data['x'] as List<dynamic>)[1] as List<dynamic>).add('c');
        expect(r.resolve(node('root', {'x': ref('list')})).data['x'], [
          'a',
          ['b'],
        ]);
      });

      test('should honour a when predicate on a value variant', () {
        final book = {
          'size': [
            {'value': 'normal'},
            {
              'when': 'h > 2000.0',
              'inputs': {'h': '#height'},
              'value': 'tall',
            },
          ],
        };
        final tall = resolver(book)
            .resolve(node('root', {'height': 2400.0, 'x': ref('size')}));
        final short = resolver(book)
            .resolve(node('root', {'height': 700.0, 'x': ref('size')}));
        expect(tall.data['x'], 'tall');
        expect(short.data['x'], 'normal');
      });

      test('should defer a value variant whose when reads a marker', () {
        // `x` comes first, so its `when` input is unresolved on round one.
        final resolved = resolver({
          'h': [
            {'value': 2400.0},
          ],
          'size': [
            {'value': 'normal'},
            {
              'when': 'h > 2000.0',
              'inputs': {'h': './#height'},
              'value': 'tall',
            },
          ],
        }).resolve(node('root', {'x': ref('size'), 'height': ref('h')}));
        expect(resolved.data['x'], 'tall');
      });

      test('should not bind inputs just for the value of a variant', () {
        // A value variant's `inputs` only feed `when`; there is none.
        final resolved = resolver({
          'doc': [
            {
              'inputs': {'ghost': '#missing'},
              'value': 'fine',
            },
          ],
        }).resolve(node('root', {'x': ref('doc')}));
        expect(resolved.data['x'], 'fine');
      });

      test('should validate resultType for value variants', () {
        final book = {
          'n': {
            'resultType': 'number',
            'variants': [
              {'value': 'nope'},
            ],
          },
        };
        final message = messageOfCall(
          () => resolver(book).resolve(node('root', {'x': ref('n')})),
        );
        expect(message, contains('returned nope (String)'));
        expect(message, contains('resultType "number"'));

        final ok = resolver({
          'n': {
            'resultType': 'map',
            'variants': [
              {
                'value': {'a': 1},
              },
            ],
          },
        }).resolve(node('root', {'x': ref('n')}));
        expect(ok.data['x'], {'a': 1});
      });

      test('should resolve value variants via resolveAtomic', () {
        final root = node('root', {'x': ref('doc')});
        resolver(docBook()).resolveAtomic(root);
        expect(root.data['x'], {
          'keys': ['width'],
        });
      });

      test('should report value provenance without an expression', () {
        final (_, minimal) = resolver(docBook())
            .resolveVerbose(node('root', {'kind': 'door', 'x': ref('doc')}));
        final eMin = minimal.entries.single;
        expect(eMin.kind, ProvenanceKind.rule);
        expect(eMin.ruleKey, 'doc');
        expect(eMin.variantIndex, 1);
        expect(eMin.value, ['door', 'docs']);
        expect(eMin.expression, isNull);

        final (_, rich) = resolver(docBook()).resolveVerbose(
          node('root', {'kind': 'door', 'x': ref('doc')}),
          rich: true,
        );
        final e = rich.entries.single;
        expect(e.value, ['door', 'docs']);
        expect(e.selector, {'#kind': 'door'});
        expect(e.expression, isNull);
        expect(e.inputs, isEmpty);
        expect(e.aliasChain, ['doc']);
        expect(e.toJson().containsKey('expression'), isFalse);
        expect(e.toString(), isNot(contains('expr')));
      });
    });

    group('resolve() — context inputs', () {
      final context = <String, dynamic>{
        'dimensions': {
          'basicShape': {
            'dimensions': {'h': 2000, 'w': 800},
          },
        },
        'sizes': [100, 200],
      };

      Resolver withContext(Json bookJson, [Json? ctx]) =>
          Resolver(ruleBook: RuleBook.fromJson(bookJson), context: ctx);

      Json heightBook() => {
        'doubled': [
          {
            'inputs': {
              'h': {'context': 'dimensions/basicShape/dimensions/h'},
            },
            'expression': 'h * 2',
          },
        ],
      };

      test('should bind a context value into an expression', () {
        final resolved = withContext(
          heightBook(),
          context,
        ).resolve(node('root', {'v': ref('doubled')}));
        expect(resolved.getOrNull<int>('./#v'), 4000);
      });

      test('should read dotted paths and list items', () {
        final resolved = withContext({
          'sum': [
            {
              'inputs': {
                'w': {'context': 'dimensions.basicShape.dimensions.w'},
                's': {'context': 'sizes[1]'},
              },
              'expression': 'w + s',
            },
          ],
        }, context).resolve(node('root', {'v': ref('sum')}));
        expect(resolved.getOrNull<int>('./#v'), 1000);
      });

      test('should feed a context value to a when predicate', () {
        Json book() => {
          'shelf': [
            {'expression': '560.0'},
            {
              'when': 'h < 2200',
              'inputs': {
                'h': {'context': 'dimensions/basicShape/dimensions/h'},
              },
              'expression': '320.0',
            },
          ],
        };
        final tree = node('root', {'v': ref('shelf')});
        expect(
          withContext(book(), context).resolve(tree).getOrNull<double>('./#v'),
          320.0,
        );

        final tall = <String, dynamic>{
          'dimensions': {
            'basicShape': {
              'dimensions': {'h': 2500},
            },
          },
        };
        expect(
          withContext(book(), tall).resolve(tree).getOrNull<double>('./#v'),
          560.0,
        );
      });

      test('should bind context inputs of inline expressions', () {
        final tree = node('root', {
          'x': {
            '§expression': 'h + 1',
            '§inputs': {
              'h': {'context': 'dimensions/basicShape/dimensions/h'},
            },
          },
        });
        final resolved = withContext({}, context).resolve(tree);
        expect(resolved.getOrNull<int>('./#x'), 2001);
      });

      test('should reject an invalid context input of an inline map', () {
        final tree = node('root', {
          'x': {
            '§expression': 'h',
            '§inputs': {
              'h': {'context': ''},
            },
          },
        });
        final e = catchException(() => withContext({}, context).resolve(tree));
        expect(e, isA<SchemaException>());
        expect(e!.message, contains('the path is empty'));
      });

      test('should apply the default when the path is missing', () {
        final book = {
          'v': [
            {
              'inputs': {
                'd': {'context': 'dimensions/nope', 'default': 7},
              },
              'expression': 'd',
            },
          ],
        };
        final tree = node('root', {'v': ref('v')});
        expect(
          withContext(book, context).resolve(tree).getOrNull<int>('./#v'),
          7,
        );
        // Also without any context, and through an incompatible shape.
        expect(withContext(book).resolve(tree).getOrNull<int>('./#v'), 7);
        final through = {
          'v': [
            {
              'inputs': {
                'd': {
                  'context': 'dimensions/basicShape/dimensions/h/deeper',
                  'default': 8,
                },
              },
              'expression': 'd',
            },
          ],
        };
        expect(
          withContext(through, context).resolve(tree).getOrNull<int>('./#v'),
          8,
        );
      });

      test('should copy a default so results never alias the book', () {
        final resolver = withContext({
          'v': [
            {
              'inputs': {
                'd': {
                  'context': 'nope',
                  'default': {'a': 1},
                },
              },
              'expression': 'd',
            },
          ],
        });
        final first = resolver.resolve(node('root', {'v': ref('v')}));
        (first.data['v'] as Map<String, dynamic>)['a'] = 99;
        final second = resolver.resolve(node('root', {'v': ref('v')}));
        expect(second.data['v'], {'a': 1});
      });

      test('should fail on a missing context path without default', () {
        final e = catchException(
          () => withContext(heightBook(), {
            'other': 1,
          }).resolve(node('root', {'v': ref('doubled')})),
        );
        expect(e, isA<MissingInputException>());
        expect(e!.message, contains('Missing input "h" of rule "doubled"'));
        expect(
          e.message,
          contains(
            'the context path "dimensions/basicShape/dimensions/h" '
            'resolved to nothing',
          ),
        );
        expect(e.message, isNot(contains('without a context')));
        final missing = e as MissingInputException;
        expect(missing.inputName, 'h');
        expect(missing.query, 'dimensions/basicShape/dimensions/h');
      });

      test('should say so when the resolver has no context at all', () {
        final e = catchException(
          () =>
              withContext(heightBook())
                  .resolve(node('root', {'v': ref('doubled')})),
        );
        expect(e, isA<MissingInputException>());
        expect(e!.message, contains('the context path'));
        expect(e.message, contains('created without a context'));
      });

      test('should keep the context separate from the tree data', () {
        // The tree key `h` is an unresolved marker; the context key `h`
        // is a different namespace and is read without deferral.
        final resolved = withContext(
          {
            'fromContext': [
              {
                'inputs': {
                  'h': {'context': 'h'},
                },
                'expression': 'h',
              },
            ],
            'one': [
              {'expression': '1'},
            ],
          },
          {'h': 7},
        ).resolve(node('root', {'h': ref('one'), 'v': ref('fromContext')}));
        expect(resolved.data['v'], 7);
        expect(resolved.data['h'], 1);
      });

      test('should bind copies, never the caller data itself', () {
        final ctx = <String, dynamic>{
          'cfg': {
            'a': 1,
            'xs': [1, 2],
          },
          'list': [
            {'n': 1},
          ],
        };
        final snapshot = deepCopy(ctx);
        final resolved = withContext({
          'cfg': [
            {
              'inputs': {
                'c': {'context': 'cfg'},
              },
              'expression': 'c',
            },
          ],
          'list': [
            {
              'inputs': {
                'l': {'context': 'list'},
              },
              'expression': 'l',
            },
          ],
        }, ctx).resolve(node('root', {'a': ref('cfg'), 'b': ref('list')}));

        expect(resolved.data['a'], ctx['cfg']);
        expect(identical(resolved.data['a'], ctx['cfg']), isFalse);
        expect(resolved.data['b'], ctx['list']);
        expect(identical(resolved.data['b'], ctx['list']), isFalse);

        // Mutating the result leaves the caller data alone.
        (resolved.data['a'] as Map<String, dynamic>)['a'] = 99;
        ((resolved.data['a'] as Map<String, dynamic>)['xs'] as List).add(3);
        (resolved.data['b'] as List).clear();
        expect(deeplEquals(ctx, snapshot), isTrue);
      });

      test('should never modify the context', () {
        final ctx = deepCopy(context);
        final resolver = withContext(heightBook(), ctx);
        resolver.resolve(node('root', {'v': ref('doubled')}), inPlace: true);
        resolver.resolveVerbose(node('root', {'v': ref('doubled')}));
        resolver.resolveAtomic(node('root', {'v': ref('doubled')}));
        expect(deeplEquals(ctx, context), isTrue);
      });

      test('should record context inputs as bound values (rich)', () {
        final (_, report) = withContext(
          heightBook(),
          context,
        ).resolveVerbose(node('root', {'v': ref('doubled')}), rich: true);
        final e = report.entries.single;
        expect(e.inputs, {'h': 2000});
        expect(e.value, 4000);
        expect(e.expression, 'h * 2');
      });

      test('should work with resolveRule', () {
        final resolver = withContext(heightBook(), context);
        final rule = resolver.ruleBook.ruleForKey('doubled')!;
        expect(resolver.resolveRule(node('root', {}), rule), 4000);
      });

      test('should work with annotate and annotateNode', () {
        final resolver = withContext({
          'height': [
            {
              'inputs': {
                'h': {'context': 'dimensions/basicShape/dimensions/h'},
              },
              'expression': 'h',
            },
          ],
        }, context);
        final tree = node('root', {}, [node('child', {})]);

        final annotated = resolver.annotate(tree);
        expect(annotated.keys, ['/', '/child']);
        expect(annotated['/child']!.single.value, 2000);

        final single = resolver.annotateNode(tree);
        expect(single.single.ruleKey, 'height');
        expect(single.single.value, 2000);
      });

      test('should reject a context containing a marker', () {
        for (final bad in <Json>[
          {'a': ref('r')},
          {
            'a': [
              {'§expression': '1'},
            ],
          },
        ]) {
          final e = catchException(() => withContext({}, bad));
          expect(e, isA<SchemaException>());
          expect(e!.message, contains('context contains a marker'));
        }
      });
    });

    group('resolve() — where (partial resolution)', () {
      Json whereBook() => {
        'one': [
          {'expression': '1'},
        ],
        'viaB': [
          {
            'inputs': {'x': './#b'},
            'expression': 'x + 1',
          },
        ],
        'viaC': [
          {
            'inputs': {'x': './#c'},
            'expression': 'x + 10',
          },
        ],
        'viaA': [
          {
            'inputs': {'x': './#a'},
            'expression': 'x + 1',
          },
        ],
        'boom': [
          {
            'inputs': {'m': './#missing'},
            'expression': 'm',
          },
        ],
      };

      Resolver whereResolver() => resolver(whereBook());

      MarkerFilter only(Set<String> keys) =>
          (node, key) => keys.contains(key);

      test('should resolve only the selected markers', () {
        final tree = node('root', {'a': ref('one'), 'b': ref('one')});
        final resolved = whereResolver().resolve(tree, where: only({'a'}));
        expect(resolved.data, {
          'a': 1,
          'b': {'§': 'one'},
        });
        // Copy mode: the original is untouched as usual.
        expect(tree.data['a'], {'§': 'one'});
      });

      test('should hand the node and the top-level key to the filter', () {
        final tree = node(
          'root',
          {
            'cfg': {
              'sizes': [
                ref('one'),
                {'deep': ref('one')},
              ],
            },
            'plain': 1,
          },
          [
            node('child', {
              'x': {'§expression': '1'},
            }),
          ],
        );
        final calls = <String>[];
        whereResolver().resolve(
          tree,
          where: (node, key) {
            calls.add('${node.path}|$key');
            return true;
          },
        );
        // One call per marker, with the top-level key — not the path.
        expect(calls, ['/|cfg', '/|cfg', '/child|x']);
      });

      test('should leave unselected markers untouched, same instances', () {
        final dormant = ref('one');
        final tree = node('root', {'a': ref('one'), 'b': dormant});
        whereResolver().resolve(tree, inPlace: true, where: only({'a'}));
        expect(tree.data['a'], 1);
        expect(identical(tree.data['b'], dormant), isTrue);
      });

      test('should resolve nothing when nothing is selected', () {
        // Even markers that would fail: they are never looked at.
        final tree = node('root', {
          'a': ref('one'),
          'bad': ref('noSuchRule'),
          'typo': {'§typo': 1},
        });
        final resolved = whereResolver().resolve(tree, where: only({}));
        expect(deeplEquals(resolved.toJson(), tree.toJson()), isTrue);
      });

      test('should not fail on unselected markers that would fail', () {
        final tree = node('root', {
          'a': ref('one'),
          'bad': ref('noSuchRule'),
          'typo': {'§typo': 1},
          'boom': ref('boom'),
        });
        final resolved = whereResolver().resolve(tree, where: only({'a'}));
        expect(resolved.data['a'], 1);
        expect(resolved.data['bad'], {'§': 'noSuchRule'});
        expect(resolved.data['typo'], {'§typo': 1});
        expect(resolved.data['boom'], {'§': 'boom'});
      });

      test('should match a full resolve when done in stages', () {
        Tree<Json> tree() => node(
          'root',
          {'a': ref('viaB'), 'b': ref('one'), 'c': ref('one')},
          [
            node('child', {'d': ref('one'), 'e': ref('one')}),
          ],
        );
        final full = whereResolver().resolve(tree());

        final staged = whereResolver().resolve(tree(), where: only({'a', 'd'}));
        // `a` pulled `b` in; `c` and `e` still wait.
        expect(staged.data, {
          'a': 2,
          'b': 1,
          'c': {'§': 'one'},
        });
        expect(staged.childByPath('child').data, {
          'd': 1,
          'e': {'§': 'one'},
        });

        final rest = whereResolver().resolve(staged);
        expect(deeplEquals(rest.toJson(), full.toJson()), isTrue);
      });

      group('pull-in of unselected blockers', () {
        test('should pull in an input that is an unselected marker', () {
          final tree = node('root', {
            'b': ref('viaC'),
            'c': ref('one'),
            'other': ref('one'),
          });
          final resolved = whereResolver().resolve(tree, where: only({'b'}));
          expect(resolved.data, {
            'b': 11,
            'c': 1,
            'other': {'§': 'one'},
          });
        });

        test('should pull in transitively', () {
          final tree = node('root', {
            'a': ref('viaB'),
            'b': ref('viaC'),
            'c': ref('one'),
            'd': ref('one'),
          });
          final resolved = whereResolver().resolve(tree, where: only({'a'}));
          expect(resolved.data, {
            'a': 12,
            'b': 11,
            'c': 1,
            'd': {'§': 'one'},
          });
        });

        test('should pull in what a selector condition waits for', () {
          final tree = node('root', {
            'mode': ref('modeOn'),
            'v': ref('w'),
            'other': ref('one'),
          });
          final resolved = resolver({
            'one': [
              {'expression': '1'},
            ],
            'modeOn': [
              {'expression': "'on'"},
            ],
            'w': [
              {'expression': '1'},
              {
                'selector': {'#mode': 'on'},
                'expression': '2',
              },
            ],
          }).resolve(tree, where: only({'v'}));
          expect(resolved.data, {
            'mode': 'on',
            'v': 2,
            'other': {'§': 'one'},
          });
        });

        test('should pull in what a when predicate waits for', () {
          final tree = node('root', {
            'h': ref('height'),
            'v': ref('w'),
            'other': ref('one'),
          });
          final resolved = resolver({
            'one': [
              {'expression': '1'},
            ],
            'height': [
              {'expression': '1500.0'},
            ],
            'w': [
              {'expression': '560.0'},
              {
                'when': 'h < 2000.0',
                'inputs': {'h': './#h'},
                'expression': '320.0',
              },
            ],
          }).resolve(tree, where: only({'v'}));
          expect(resolved.data, {
            'h': 1500.0,
            'v': 320.0,
            'other': {'§': 'one'},
          });
        });

        test('should pull in what an inline expression waits for', () {
          final tree = node('root', {
            'x': {
              '§expression': 'y + 1',
              '§inputs': {'y': './#y'},
            },
            'y': ref('one'),
            'z': ref('one'),
          });
          final resolved = whereResolver().resolve(tree, where: only({'x'}));
          expect(resolved.data, {
            'x': 2,
            'y': 1,
            'z': {'§': 'one'},
          });
        });

        test('should pull in nested markers below the blocker', () {
          // The input reads `#cfg`, which contains markers at cfg/a and
          // cfg/xs[0]; a lookalike sibling must stay.
          final tree = node('root', {
            'total': ref('sum'),
            'cfg': {
              'a': ref('one'),
              'b': 5,
              'xs': [ref('one'), 7],
            },
            'cfgX': ref('one'),
            'cfg2': {'z': ref('one')},
          });
          final resolved = resolver({
            'one': [
              {'expression': '1'},
            ],
            'sum': [
              {
                'inputs': {'c': './#cfg'},
                'expression': 'c.a + c.b + c.xs[0] + c.xs[1]',
              },
            ],
          }).resolve(tree, where: only({'total'}));
          expect(resolved.data, {
            'total': 14,
            'cfg': {
              'a': 1,
              'b': 5,
              'xs': [1, 7],
            },
            'cfgX': {'§': 'one'},
            'cfg2': {
              'z': {'§': 'one'},
            },
          });
        });

        test('should pull in list items below an indexed blocker', () {
          final tree = node('root', {
            'total': ref('sum'),
            'xs': [ref('one'), ref('one')],
            'ys': [ref('one')],
          });
          final resolved = resolver({
            'one': [
              {'expression': '1'},
            ],
            'sum': [
              {
                'inputs': {'xs': './#xs'},
                'expression': 'xs[0] + xs[1]',
              },
            ],
          }).resolve(tree, where: only({'total'}));
          expect(resolved.data, {
            'total': 2,
            'xs': [1, 1],
            'ys': [
              {'§': 'one'},
            ],
          });
        });

        test('should pull in only the marker an indexed path hits', () {
          // The blocker is `/#xs[0]`: the sibling item stays.
          final tree = node('root', {
            'v': ref('first'),
            'xs': [ref('one'), ref('one')],
          });
          final resolved = resolver({
            'one': [
              {'expression': '1'},
            ],
            'first': [
              {
                'inputs': {'x': './#xs[0]'},
                'expression': 'x + 1',
              },
            ],
          }).resolve(tree, where: only({'v'}));
          expect(resolved.data, {
            'v': 2,
            'xs': [
              1,
              {'§': 'one'},
            ],
          });
        });

        test('should pull in a whole node when its data is read', () {
          // `../#` reads the parent's entire data map: every marker
          // there blocks the read, none elsewhere does.
          final sibling = node('sibling', {'s': ref('one')});
          final root = node(
            'root',
            {'k1': ref('one'), 'k2': ref('one')},
            [
              node('child', {'total': ref('count')}),
              sibling,
            ],
          );
          final resolved = resolver({
            'one': [
              {'expression': '1'},
            ],
            'count': [
              {
                'inputs': {'p': '../#'},
                'expression': 'p.k1 + p.k2',
              },
            ],
          }).resolve(root, where: only({'total'}));
          expect(resolved.data, {'k1': 1, 'k2': 1});
          expect(resolved.childByPath('child').data['total'], 2);
          expect(resolved.childByPath('sibling').data['s'], {'§': 'one'});
        });

        test('should not confuse nodes that share a path prefix', () {
          // Blocker is `/a#w`; the dormant marker on node `ab` has the
          // same key but lives elsewhere.
          final root = node('root', {}, [
            node('a', {'w': ref('one')}),
            node('ab', {'w': ref('one')}),
            node('c', {'x': ref('readA')}),
          ]);
          final resolved = resolver({
            'one': [
              {'expression': '1'},
            ],
            'readA': [
              {
                'inputs': {'w': 'a#w'},
                'expression': 'w + 1',
              },
            ],
          }).resolve(root, where: only({'x'}));
          expect(resolved.childByPath('a').data['w'], 1);
          expect(resolved.childByPath('ab').data['w'], {'§': 'one'});
          expect(resolved.childByPath('c').data['x'], 2);
        });

        test('should pull in a blocker found via upward search', () {
          final root = node(
            'root',
            {'limit': ref('one')},
            [
              node('child', {'v': ref('readLimit')}),
            ],
          );
          final resolved = resolver({
            'one': [
              {'expression': '1'},
            ],
            'readLimit': [
              {
                'inputs': {'l': '#limit'},
                'expression': 'l + 1',
              },
            ],
          }).resolve(root, where: only({'v'}));
          expect(resolved.data['limit'], 1);
          expect(resolved.childByPath('child').data['v'], 2);
        });

        test('should surface errors of pulled-in markers', () {
          final tree = node('root', {'b': ref('viaC'), 'c': ref('boom')});
          final e = catchException(
            () => whereResolver().resolve(tree, where: only({'b'})),
          );
          expect(e, isA<MissingInputException>());
          expect(e!.message, contains('rule "boom"'));
        });
      });

      group('discovered markers', () {
        test('should keep markers produced by a selected one selected', () {
          // `alias` yields another reference at the same location; it
          // is resolved although `where` was asked only about `a`.
          final tree = node('root', {'a': ref('alias'), 'b': ref('one')});
          var calls = 0;
          final resolved =
              resolver({
                'one': [
                  {'expression': '1'},
                ],
                'alias': [
                  {'expression': "{'§': 'one'}"},
                ],
              }).resolve(
                tree,
                where: (node, key) {
                  calls++;
                  return key == 'a';
                },
              );
          expect(resolved.data, {
            'a': 1,
            'b': {'§': 'one'},
          });
          expect(calls, 2);
        });
      });

      group('termination and errors', () {
        test('should report a cycle among selected markers as stuck', () {
          // `c` is dormant but nobody waits for it.
          final tree = node('root', {
            'a': ref('viaB'),
            'b': ref('viaA'),
            'c': ref('one'),
          });
          final e = catchException(
            () => whereResolver().resolve(tree, where: only({'a', 'b'})),
          );
          expect(e, isA<StuckException>());
          expect(e!.message, contains('Resolution is stuck: 2 item(s)'));
        });

        test('should report a cycle through a pulled-in marker as stuck', () {
          // `a` waits for `b`, which is pulled in and waits for `a`.
          final tree = node('root', {'a': ref('viaB'), 'b': ref('viaA')});
          final e = catchException(
            () => whereResolver().resolve(tree, where: only({'a'})),
          );
          expect(e, isA<StuckException>());
          expect(e!.message, contains('Resolution is stuck: 2 item(s)'));
        });

        test(
          'should fail for selected markers exactly as without a filter',
          () {
            final unknown = node('root', {'a': ref('noSuchRule')});
            expect(
              catchException(
                () => whereResolver().resolve(unknown, where: only({'a'})),
              ),
              isA<UnknownRuleException>(),
            );

            final missing = node('root', {'a': ref('boom')});
            expect(
              catchException(
                () => whereResolver().resolve(missing, where: only({'a'})),
              ),
              isA<MissingInputException>(),
            );
          },
        );

        test('should get stuck on a blocker outside a resolved subtree', () {
          // The dormant-free subtree resolve cannot see the ancestor's
          // marker, so there is nothing to pull in.
          final child = node('child', {'v': ref('readLimit')});
          node('root', {'limit': ref('one')}, [child]);
          final e = catchException(
            () => resolver({
              'one': [
                {'expression': '1'},
              ],
              'readLimit': [
                {
                  'inputs': {'l': '#limit'},
                  'expression': 'l',
                },
              ],
            }).resolve(child, inPlace: true, where: only({'v'})),
          );
          expect(e, isA<StuckException>());
        });
      });

      group('with the other entry points', () {
        test('resolveVerbose() should report only what was resolved', () {
          final tree = node('root', {
            'b': ref('viaC'),
            'c': ref('one'),
            'other': ref('one'),
          });
          final (resolved, report) = whereResolver().resolveVerbose(
            tree,
            where: only({'b'}),
            rich: true,
          );
          expect(resolved.data['other'], {'§': 'one'});
          // `c` was pulled in and resolved first, then `b`.
          expect(report.entries.map((e) => e.location), ['/#c', '/#b']);
          expect(report.at('/#other'), isEmpty);
        });

        test('resolveAtomic() should leave unselected markers untouched', () {
          final child = node('child', {'c': ref('one')});
          final childMarker = child.data['c'];
          final tree = node(
            'root',
            {'a': ref('one'), 'b': ref('one')},
            [child],
          );
          final result = whereResolver().resolveAtomic(
            tree,
            where: only({'a'}),
          );
          expect(identical(result, tree), isTrue);
          expect(tree.data, {
            'a': 1,
            'b': {'§': 'one'},
          });
          // A node without selected markers is not written back at all.
          expect(identical(child.data['c'], childMarker), isTrue);
        });

        test('resolveAtomic() should stay all-or-nothing with a filter', () {
          final tree = node('root', {'good': ref('one'), 'bad': ref('boom')});
          expect(
            () => whereResolver().resolveAtomic(
              tree,
              where: only({'good', 'bad'}),
            ),
            throwsA(isA<MissingInputException>()),
          );
          expect(tree.data['good'], {'§': 'one'});
          expect(tree.data['bad'], {'§': 'boom'});
        });
      });
    });

    group('resolveRule()', () {
      final rule = Rule.fromJson('w', [
        {
          'inputs': {'w': '#width'},
          'expression': 'w * 2.0',
        },
      ]);

      test('should evaluate a rule at a node', () {
        final result = resolver({})
            .resolveRule(node('root', {'width': 2.0}), rule);
        expect(result, 4.0);
      });

      test('should return a fresh copy of a value variant', () {
        final valueRule = Rule.fromJson('doc', [
          {
            'value': {
              'keys': ['width'],
            },
          },
        ]);
        final first =
            resolver({}).resolveRule(node('root', {}), valueRule)!
                as Map<String, dynamic>;
        (first['keys'] as List<dynamic>).add('height');
        expect(resolver({}).resolveRule(node('root', {}), valueRule), {
          'keys': ['width'],
        });
      });

      test('should evaluate a when-gated variant', () {
        final gated = Rule.fromJson('w', [
          {'expression': '0'},
          {
            'when': 'h < 2000.0',
            'inputs': {'h': '#h'},
            'expression': '1',
          },
        ]);
        final result = resolver({})
            .resolveRule(node('root', {'h': 1500.0}), gated);
        expect(result, 1);
      });

      test('should throw on ambiguous same-specificity matches', () {
        final ambiguousRule = Rule.fromJson('w', [
          {
            'selector': {'#a': 1},
            'expression': '1',
          },
          {
            'selector': {'#b': 2},
            'expression': '2',
          },
        ]);
        final e = catchException(
          () =>
              resolver({})
                  .resolveRule(node('root', {'a': 1, 'b': 2}), ambiguousRule),
        );
        expect(e, isA<AmbiguousVariantException>());
        expect(e!.message, contains('with the same specificity (1)'));
        expect(e.message, contains('the winner is ambiguous'));
      });

      test('should throw when selection is blocked', () {
        final blockedRule = Rule.fromJson('w', [
          {
            'selector': {'#u': 1},
            'expression': '1',
          },
        ]);
        final message = messageOfCall(
          () =>
              resolver({})
                  .resolveRule(node('root', {'u': ref('x')}), blockedRule),
        );
        expect(message, contains('Cannot resolve rule "w" at node "/"'));
        expect(message, contains('selector condition "#u" waits'));
      });

      test('should throw when inputs are blocked', () {
        final message = messageOfCall(
          () =>
              resolver({}).resolveRule(node('root', {'width': ref('x')}), rule),
        );
        expect(message, contains('Cannot resolve rule "w" at node "/"'));
        expect(message, contains('input "w" of rule "w"'));
      });

      test('should return null for optional rules without match', () {
        final optional = Rule.fromJson('w', {
          'optional': true,
          'variants': [
            {
              'selector': {'#never': 1},
              'expression': '1',
            },
          ],
        });
        expect(resolver({}).resolveRule(node('root', {}), optional), isNull);
      });

      test('should throw for non-optional rules without match', () {
        final strict = Rule.fromJson('w', [
          {
            'selector': {'#never': 1},
            'expression': '1',
          },
        ]);
        final message = messageOfCall(
          () => resolver({}).resolveRule(node('root', {}), strict),
        );
        expect(message, contains('No variant of rule "w" matches at "/"'));
      });
    });

    // End-to-end golden: resolving [RuleBook.example] over a
    // representative tree. Snapshots both the resolved tree and the
    // rich report, so any change to selection, inputs/defaults, inline
    // expressions, optional removal, or deferral surfaces as a diff.
    group('example (golden)', () {
      // `title` sits before `gap` so its inline expression reads an
      // unresolved reference first and is deferred until `gap` resolves.
      Tree<Json> exampleTree() => node(
        'app',
        {'platform': 'mobile', 'style': 'plain'},
        [
          node('theme', {'id': 'dark'}),
          node('screen', {'width': 380.0}),
          node('dialog', {
            'borderWidth': ref('borderWidth'),
            'title': {
              '§expression': 'gap * 2.0',
              '§inputs': {'gap': './#gap'},
            },
            'gap': ref('gap'),
            'decoration': ref('decoration'),
          }),
        ],
      );

      test('resolves the example book over a representative tree', () async {
        final book = RuleBook.example();

        final resolved = Resolver(ruleBook: book).resolve(exampleTree());
        await writeGolden('resolved_tree.json', resolved.toJson());

        final (_, report) = Resolver(ruleBook: book)
            .resolveVerbose(exampleTree(), rich: true);
        await writeGolden('resolution_report.json', report.toJson());

        // Spot-check the outcomes captured by the goldens.
        final dialog = resolved.childByPath('dialog');
        expect(dialog.get<double>('./#borderWidth'), 3.0);
        expect(dialog.get<double>('./#gap'), 8.0);
        expect(dialog.get<double>('./#title'), 16.0);
        expect(dialog.getOrNull<Object>('./#decoration'), isNull);
      });
    });

    group('when (golden)', () {
      // One resolve showing the three `when` patterns: a base +
      // when-override (`shelfCount`), and an OR predicate (`compact`).
      // Sibling nodes hit different branches.
      Json whenBook() => {
        'shelfCount': [
          {'expression': '1'},
          {
            'when': 'h > 2000.0',
            'inputs': {'h': './#height'},
            'expression': '4',
          },
        ],
        'compact': [
          {'expression': 'false'},
          {
            'when': 'h < 800.0 || w > 1200.0',
            'inputs': {'h': './#height', 'w': './#width'},
            'expression': 'true',
          },
        ],
      };

      Tree<Json> cabinetTree() => node('app', {}, [
        node('tall', {
          'height': 2400.0,
          'width': 600.0,
          'shelves': ref('shelfCount'),
          'isCompact': ref('compact'),
        }),
        node('short', {
          'height': 700.0,
          'width': 600.0,
          'shelves': ref('shelfCount'),
          'isCompact': ref('compact'),
        }),
        node('wide', {
          'height': 1500.0,
          'width': 1400.0,
          'shelves': ref('shelfCount'),
          'isCompact': ref('compact'),
        }),
      ]);

      test('resolves when-gated variants over a representative tree', () async {
        final resolved = Resolver(ruleBook: RuleBook.fromJson(whenBook()))
            .resolve(cabinetTree());
        await writeGolden('resolved_when_tree.json', resolved.toJson());

        // Rich report now carries the winning variant's `when`.
        final (_, report) = Resolver(ruleBook: RuleBook.fromJson(whenBook()))
            .resolveVerbose(cabinetTree(), rich: true);
        await writeGolden('resolution_report_when.json', report.toJson());

        // Spot-check the branches the goldens capture.
        Tree<Json> child(String k) => resolved.childByPath(k);
        expect(child('tall').get<int>('./#shelves'), 4); // h>2000 override
        expect(child('short').get<int>('./#shelves'), 1); // base fallback
        expect(child('wide').get<int>('./#shelves'), 1); // base fallback
        expect(child('tall').get<bool>('./#isCompact'), isFalse);
        expect(child('short').get<bool>('./#isCompact'), isTrue); // h<800
        expect(child('wide').get<bool>('./#isCompact'), isTrue); // w>1200
      });
    });

    group('annotate()', () {
      // Book: a static `value`, a computed `expression`, a gated `value`.
      Json annotationBook() => {
        'role': [
          {'value': 'node'},
          {
            'selector': {'#kind': 'dialog'},
            'value': 'container',
          },
        ],
        'keys': [
          {
            'selector': {'#kind': 'dialog'},
            'value': {
              'targets': ['width', 'height'],
              'text': 'Size keys a rule may set.',
            },
          },
        ],
        'area': [
          {
            'selector': {'#kind': 'panel'},
            'inputs': {'w': './#width', 'h': './#height'},
            'expression': 'w * h',
          },
        ],
        'wide': [
          {
            'when': 'w > 500.0',
            'inputs': {
              'w': {'query': './#width', 'default': 0.0},
            },
            'value': true,
          },
        ],
      };

      Tree<Json> uiTree() => node('app', {}, [
        node(
          'dialog',
          {'kind': 'dialog', 'width': 800.0},
          [
            node('okButton', {'kind': 'button'}),
          ],
        ),
        node('sidebar', {'kind': 'panel', 'width': 300.0, 'height': 400.0}),
      ]);

      Map<String, List<Map<String, dynamic>>> asJson(
        Map<String, List<Annotation>> annotations,
      ) => {
        for (final MapEntry(:key, :value) in annotations.entries)
          key: [for (final a in value) a.toJson()],
      };

      test('annotates a small tree with a small book (golden)', () async {
        final annotations = resolver(annotationBook()).annotate(uiTree());
        await writeGolden('annotations.json', asJson(annotations));

        expect(annotations.keys, [
          '/',
          '/dialog',
          '/dialog/okButton',
          '/sidebar',
        ]);
        expect(annotations['/dialog']!.map((a) => a.ruleKey), [
          'role',
          'keys',
          'wide',
        ]);
        expect(annotations['/sidebar']!.last.value, 120000.0);
      });

      test('should pick base or override per node', () {
        final result = resolver(annotationBook()).annotate(uiTree());

        // Visit order: top-down, root first.
        expect(result.keys, ['/', '/dialog', '/dialog/okButton', '/sidebar']);

        Object? role(String path) =>
            result[path]!.singleWhere((a) => a.ruleKey == 'role').toJson();
        expect(role('/'), {
          'ruleKey': 'role',
          'variantIndex': 0,
          'value': 'node',
        });
        expect(role('/dialog'), {
          'ruleKey': 'role',
          'variantIndex': 1,
          'value': 'container',
        });
        expect(role('/dialog/okButton'), {
          'ruleKey': 'role',
          'variantIndex': 0,
          'value': 'node',
        });
      });

      test('should list a nodes annotations in rule book order', () {
        final result = resolver(annotationBook()).annotate(uiTree());
        expect(result['/dialog']!.map((a) => a.ruleKey), [
          'role',
          'keys',
          'wide',
        ]);
        expect(result['/sidebar']!.map((a) => a.ruleKey), ['role', 'area']);
      });

      test('should evaluate expression variants with bound inputs', () {
        final result = resolver(annotationBook()).annotate(uiTree());
        final area = result['/sidebar']!.singleWhere(
          (a) => a.ruleKey == 'area',
        );
        expect(area.value, 120000.0);
        expect(area.variantIndex, 0);
      });

      test('should apply when variants', () {
        final result = resolver(annotationBook()).annotate(uiTree());
        // 800 > 500 applies; 300 and the default 0.0 do not.
        expect(result['/dialog']!.any((a) => a.ruleKey == 'wide'), isTrue);
        expect(result['/sidebar']!.any((a) => a.ruleKey == 'wide'), isFalse);
        expect(
          result['/dialog/okButton']!.any((a) => a.ruleKey == 'wide'),
          isFalse,
        );
      });

      test('should omit nodes nothing applies to, optional or not', () {
        // Neither rule has a base variant; the first is not optional.
        final result = resolver({
          'keys': [
            {
              'selector': {'#kind': 'dialog'},
              'value': 'dialog keys',
            },
          ],
          'hint': {
            'optional': true,
            'variants': [
              {
                'selector': {'#kind': 'nope'},
                'value': 'never',
              },
            ],
          },
        }).annotate(uiTree());
        expect(asJson(result), {
          '/dialog': [
            {'ruleKey': 'keys', 'variantIndex': 0, 'value': 'dialog keys'},
          ],
        });
      });

      test('should return an empty map when nothing applies anywhere', () {
        expect(resolver({}).annotate(uiTree()), isEmpty);
      });

      test('should throw on ambiguous same-specificity matches', () {
        final e = catchException(
          () => resolver({
            'role': [
              {'value': 'a'},
              {'value': 'b'},
            ],
          }).annotate(uiTree()),
        );
        expect(e, isA<AmbiguousVariantException>());
        final ambiguous = e! as AmbiguousVariantException;
        expect(ambiguous.ruleKey, 'role');
        expect(ambiguous.location, '/');
        expect(ambiguous.variantIndices, [0, 1]);
        expect(ambiguous.message, contains('the winner is ambiguous'));
      });

      test('should validate resultType of value and expression results', () {
        final valueBook = {
          'n': {
            'resultType': 'number',
            'variants': [
              {'value': 'nope'},
            ],
          },
        };
        final message = messageOfCall(
          () => resolver(valueBook).annotate(node('root', {})),
        );
        expect(message, contains('Rule "n" (variant 0) at "/" returned nope'));
        expect(message, contains('resultType "number"'));

        final expressionBook = {
          'n': {
            'resultType': 'number',
            'variants': [
              {'expression': "'nope'"},
            ],
          },
        };
        expect(
          catchException(
            () => resolver(expressionBook).annotate(node('root', {})),
          ),
          isA<ResolveException>(),
        );
      });

      test('should fail on a missing input of an expression variant', () {
        final e = catchException(
          () => resolver({
            'x': [
              {
                'inputs': {'w': '#missing'},
                'expression': 'w',
              },
            ],
          }).annotate(node('root', {})),
        );
        expect(e, isA<MissingInputException>());
        expect(e!.message, contains('Missing input "w" of rule "x"'));
      });

      test('should wrap expression evaluation errors', () {
        final e = catchException(
          () => resolver({
            'x': [
              {'expression': 'ghost'},
            ],
          }).annotate(node('root', {})),
        );
        expect(e, isA<ExpressionException>());
        expect(
          e!.message,
          contains('While resolving rule "x" (variant 0) at "/"'),
        );
      });

      test('should not read inputs of a value variant without a when', () {
        final result = resolver({
          'doc': [
            {
              'inputs': {'ghost': '#missing'},
              'value': 'fine',
            },
          ],
        }).annotate(node('root', {}));
        expect(asJson(result), {
          '/': [
            {'ruleKey': 'doc', 'variantIndex': 0, 'value': 'fine'},
          ],
        });
      });

      group('on a tree with unresolved markers', () {
        test('should throw when a selector reads a marker', () {
          final e = catchException(
            () =>
                resolver(annotationBook())
                    .annotate(node('root', {'kind': ref('other')})),
          );
          expect(e, isA<ResolveException>());
          expect(e, isNot(isA<StuckException>()));
          expect(
            e!.message,
            contains('Cannot annotate rule "role" at node "/"'),
          );
          expect(e.message, contains('the query "#kind" waits for the'));
          expect(e.message, contains('unresolved value at "/#kind"'));
          expect(e.message, contains('annotate() expects a resolved tree'));
        });

        test('should throw when an input reads a marker', () {
          final message = messageOfCall(
            () => resolver({
              'x': [
                {
                  'inputs': {'w': '#width'},
                  'expression': 'w',
                },
              ],
            }).annotate(node('root', {'width': ref('other')})),
          );
          expect(message, contains('Cannot annotate rule "x" at node "/"'));
          expect(message, contains('input "w" of rule "x" (variant 0)'));
          expect(message, contains('waits for the unresolved value at'));
          expect(message, contains('annotate() expects a resolved tree'));
        });

        test('should throw when a when-input reads a marker', () {
          final message = messageOfCall(
            () => resolver({
              'x': [
                {
                  'when': 'w > 1.0',
                  'inputs': {'w': '#width'},
                  'value': true,
                },
              ],
            }).annotate(node('root', {'width': ref('other')})),
          );
          expect(message, contains('Cannot annotate rule "x" at node "/"'));
          expect(message, contains('annotate() expects a resolved tree'));
        });

        test('should annotate once the tree is resolved', () {
          final r = resolver({
            ...annotationBook(),
            'kindRule': [
              {'value': 'dialog'},
            ],
          });
          final tree = node('root', {'kind': ref('kindRule')});
          expect(() => r.annotate(tree), throwsA(isA<ResolveException>()));

          final annotated = r.annotate(r.resolve(tree));
          expect(annotated['/']!.map((a) => a.ruleKey), [
            'role',
            'keys',
            'kindRule',
          ]);
        });
      });

      test('should not mutate the tree', () {
        final tree = uiTree();
        final before = tree.toJson();
        final result = resolver(annotationBook()).annotate(tree);
        ((result['/dialog']!.singleWhere((a) => a.ruleKey == 'keys').value!
                    as Map<String, dynamic>)['targets']
                as List<dynamic>)
            .add('depth');
        expect(deeplEquals(tree.toJson(), before), isTrue);
      });

      test('should return independent copies of value variants', () {
        final r = resolver(annotationBook());
        Map<String, dynamic> keys() =>
            r
                    .annotate(uiTree())['/dialog']!
                    .singleWhere((a) => a.ruleKey == 'keys')
                    .value!
                as Map<String, dynamic>;

        final first = keys();
        (first['targets'] as List<dynamic>).add('depth');
        first['text'] = 'changed';

        final pristine = {
          'targets': ['width', 'height'],
          'text': 'Size keys a rule may set.',
        };
        expect(keys(), pristine);
        expect(r.ruleBook.toJson()['keys'], annotationBook()['keys']);
      });

      test('should work on a subtree and still see its ancestors', () {
        final tree = node(
          'app',
          {'kind': 'dialog'},
          [
            node('inner', {}, [node('leaf', {})]),
          ],
        );
        final result = resolver({
          'role': [
            {'value': 'plain'},
            {
              'selector': {'#kind': 'dialog'},
              'value': 'inherited',
            },
          ],
        }).annotate(tree.childByPath('inner'));

        expect(result.keys, ['/inner', '/inner/leaf']);
        expect(result['/inner']!.single.value, 'inherited');
        expect(result['/inner/leaf']!.single.value, 'inherited');
      });

      test('should not interfere with resolve on the same resolver', () {
        final r = resolver({
          ...borderBook,
          'role': [
            {'value': 'node'},
          ],
        });
        final resolved = r.resolve(appTree());
        expect(r.annotate(resolved).keys, contains('/dialog/okButton'));

        // Annotating leaves no trace in the verbose report.
        final (again, report) = r.resolveVerbose(appTree());
        expect(report.entries, hasLength(1));
        expect(again.childByPath('dialog').data['borderWidth'], 3.0);
      });
    });

    group('annotateNode()', () {
      final book = {
        'role': [
          {'value': 'node'},
          {
            'selector': {'#kind': 'dialog'},
            'value': 'container',
          },
        ],
      };

      test('should annotate exactly the given node', () {
        final tree = node('app', {'kind': 'dialog'}, [node('child', {})]);
        final r = resolver(book);

        final atRoot = r.annotateNode(tree);
        expect(atRoot.map((a) => a.toJson()), [
          {'ruleKey': 'role', 'variantIndex': 1, 'value': 'container'},
        ]);

        // The child inherits `kind` through the ancestor chain.
        expect(
          r.annotateNode(tree.childByPath('child')).single.value,
          'container',
        );
      });

      test('should return an empty list when nothing applies', () {
        final r = resolver({
          'keys': [
            {
              'selector': {'#kind': 'dialog'},
              'value': 'x',
            },
          ],
        });
        expect(r.annotateNode(node('root', {})), isEmpty);
      });

      test('should throw on unresolved markers like annotate', () {
        final e = catchException(
          () => resolver(book).annotateNode(node('root', {'kind': ref('k')})),
        );
        expect(e, isA<ResolveException>());
        expect(e!.message, contains('annotate() expects a resolved tree'));
      });
    });
  });
}

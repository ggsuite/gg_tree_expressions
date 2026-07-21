// @license
// Copyright (c) 2026 ggsuite
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
        final (resolved, report) = resolver(
          book,
        ).resolveVerbose(node('root', {'v': ref('w')}), inPlace: true);
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
        final (_, report) = resolver(
          borderBook,
        ).resolveVerbose(appTree(), rich: true);
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

        final (_, rich) = resolver(
          {},
        ).resolveVerbose(tree(), inPlace: true, rich: true);
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
        final (rMin, repMin) = resolver(
          book,
        ).resolveVerbose(node('root', {'m': ref('opt')}), inPlace: true);
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
          () => resolver(
            borderBook,
          ).resolve(node('root', {'x': ref('borderWith')})),
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
        final resolved = resolver(
          bookWithWhen(),
        ).resolve(node('root', {'h': 1500.0, 'v': ref('w')}));
        expect(resolved.getOrNull<double>('./#v'), 320.0);
      });

      test('should fall back to the base when the predicate is false', () {
        final resolved = resolver(
          bookWithWhen(),
        ).resolve(node('root', {'h': 2500.0, 'v': ref('w')}));
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

    group('resolveRule()', () {
      final rule = Rule.fromJson('w', [
        {
          'inputs': {'w': '#width'},
          'expression': 'w * 2.0',
        },
      ]);

      test('should evaluate a rule at a node', () {
        final result = resolver(
          {},
        ).resolveRule(node('root', {'width': 2.0}), rule);
        expect(result, 4.0);
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
        final result = resolver(
          {},
        ).resolveRule(node('root', {'h': 1500.0}), gated);
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
          () => resolver(
            {},
          ).resolveRule(node('root', {'a': 1, 'b': 2}), ambiguousRule),
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
          () => resolver(
            {},
          ).resolveRule(node('root', {'u': ref('x')}), blockedRule),
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

        final (_, report) = Resolver(
          ruleBook: book,
        ).resolveVerbose(exampleTree(), rich: true);
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
        final resolved = Resolver(
          ruleBook: RuleBook.fromJson(whenBook()),
        ).resolve(cabinetTree());
        await writeGolden('resolved_when_tree.json', resolved.toJson());

        // Rich report now carries the winning variant's `when`.
        final (_, report) = Resolver(
          ruleBook: RuleBook.fromJson(whenBook()),
        ).resolveVerbose(cabinetTree(), rich: true);
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
  });
}

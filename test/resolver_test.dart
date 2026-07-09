// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';
import 'package:gg_tree_expressions/gg_tree_expressions.dart';
import 'package:test/test.dart';

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
    '§borderWidth': [
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
        {'borderWidth': ref('§borderWidth')},
        [node('okButton', {})],
      ),
    ],
  );

  group('Resolver', () {
    group('constructor', () {
      test('should compile all rule expressions eagerly', () {
        final e = catchException(
          () => resolver({
            '§bad': [
              {'expression': '1 +'},
            ],
          }),
        );
        expect(e, isA<ExpressionException>());
        expect(e!.message, contains('In rule "§bad", variant 0:'));
        expect(e.message, contains('Syntax error'));
      });

      test('should share an injected expression cache', () {
        final cache = <String, CompiledExpression>{};
        final book = RuleBook.fromJson({
          '§w': [
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
        final resolved = r2.resolve(node('n', {'v': ref('§w')}), inPlace: true);
        expect(resolved.getOrNull<double>('./#v'), 3.0);
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
          '§': '§borderWidth',
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
          '§w': [
            {'expression': '1.5'},
          ],
        });
        final tree = book.resolve(node('root', {'w': ref('§w')}));
        expect(tree.getOrNull<double>('./#w'), 1.5);

        node('grown', {'w2': ref('§w')}, const []).parent = tree;
        final again = book.resolve(tree, inPlace: true);
        expect(again.childByPath('grown').getOrNull<double>('./#w2'), 1.5);
      });

      test('should treat §-strings as plain data everywhere', () {
        // Strings are never references: values, selector literals,
        // and inputs all see them as ordinary data.
        final tree = node('root', {
          'law': '§ 5 Abs. 2',
          'label': '§note',
          'copy': ref('§copyLabel'),
          'kind': ref('§kind'),
        });
        final resolved = resolver({
          '§copyLabel': [
            {
              'inputs': {'l': './#label'},
              'expression': 'l',
            },
          ],
          '§kind': [
            {'expression': "'other'"},
            {
              'selector': {'./#label': '§note'},
              'expression': "'note'",
            },
          ],
        }).resolve(tree);
        expect(resolved.getOrNull<String>('./#law'), '§ 5 Abs. 2');
        expect(resolved.getOrNull<String>('./#label'), '§note');
        expect(resolved.getOrNull<String>('./#copy'), '§note');
        expect(resolved.getOrNull<String>('./#kind'), 'note');
      });

      test('should defer until selector context is resolved', () {
        final book = {
          ...borderBook,
          '§themeId': [
            {'expression': "'dark'"},
          ],
        };
        final app = appTree();
        app.childByPath('theme').data['id'] = ref('§themeId');
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
          'doubled': ref('§double'),
          'twice': {
            '§expression': 'v * 2',
            '§inputs': {'v': '#w'},
          },
          'w': ref('§five'),
        });
        final resolved = resolver({
          '§five': [
            {'expression': '5'},
          ],
          '§double': [
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
            'sizes': [ref('§five'), 2],
            'inner': {'w': ref('§five')},
          },
        });
        final resolved = resolver({
          '§five': [
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
            '§wrap': [
              {'expression': "{'a#b': {'§': '§inner'}}"},
            ],
            '§inner': [
              {
                'selector': {'#never': 1},
                'expression': '1',
              },
            ],
          }).resolve(node('root', {'cfg': ref('§wrap')})),
        );
        expect(message, contains('at "/#cfg/a#b"'));
      });

      test('should keep reference-like strings in results as data', () {
        final resolved = resolver({
          '§label': [
            {'expression': "'§nobody'"},
          ],
        }).resolve(node('root', {'x': ref('§label')}));
        expect(resolved.getOrNull<String>('./#x'), '§nobody');
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
          {'§': 'noPrefix'},
          {'§': '§ok', 'extra': 1},
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
        final tree = node('root', {'x': ref('§alias')});
        final resolved = resolver({
          '§alias': [
            {'expression': "{'§': '§target'}"},
          ],
          '§target': [
            {'expression': '42'},
          ],
        }).resolve(tree);
        expect(resolved.getOrNull<dynamic>('./#x'), 42);
      });

      test('should resolve markers inside rule results', () {
        final tree = node('root', {'x': ref('§wrap')});
        final resolved = resolver({
          '§wrap': [
            {'expression': "{'inner': {'§': '§scalar'}, 'text': '§raw'}"},
          ],
          '§scalar': [
            {'expression': '5'},
          ],
        }).resolve(tree);
        expect(resolved.getOrNull<dynamic>('./#x'), {
          'inner': 5,
          'text': '§raw',
        });
      });

      test('should detect circular rule aliases', () {
        final e = catchException(
          () => resolver({
            '§a': [
              {'expression': "{'§': '§b'}"},
            ],
            '§b': [
              {'expression': "{'§': '§a'}"},
            ],
          }).resolve(node('root', {'x': ref('§a')})),
        );
        expect(e, isA<CircularAliasException>());
        expect(e!.message, contains('Circular rule alias at "/#x"'));
        expect(e.message, contains('§a → §b → §a'));
        expect((e as CircularAliasException).chain, ['§a', '§b', '§a']);
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
          ).resolve(node('root', {'x': ref('§borderWith')})),
        );
        expect(e, isA<UnknownRuleException>());
        expect(e!.message, contains('Unknown rule "§borderWith"'));
        expect(e.message, contains('Did you mean "§borderWidth"?'));
        expect(e.message, contains('  - §borderWidth'));
        final unknown = e as UnknownRuleException;
        expect(unknown.ruleKey, '§borderWith');
        expect(unknown.suggestions, ['§borderWidth']);
      });

      test('should report unknown rules without close matches', () {
        final message = messageOfCall(
          () => resolver(borderBook).resolve(node('root', {'x': ref('§zzz')})),
        );
        expect(message, contains('Unknown rule "§zzz"'));
        expect(message, isNot(contains('Did you mean')));
      });

      test('should fail when no variant matches', () {
        final e = catchException(
          () => resolver({
            '§sel': [
              {
                'selector': {'#platform': 'desktop'},
                'expression': '1',
              },
            ],
          }).resolve(node('root', {'platform': 'mobile', 'x': ref('§sel')})),
        );
        expect(e, isA<NoVariantException>());
        expect(e!.message, contains('No variant of rule "§sel"'));
        expect(e.message, contains('found "mobile"'));
        expect(e.message, contains('Add a base variant'));
      });

      test('should remove optional references that match nothing', () {
        final tree = node('root', {
          'platform': 'mobile',
          'a': ref('§opt'),
          'xs': [ref('§opt'), 2],
        });
        final resolved = resolver({
          '§opt': {
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
          '§n': {
            'resultType': 'number',
            'variants': [
              {'expression': "'nope'"},
            ],
          },
        };
        final message = messageOfCall(
          () => resolver(book).resolve(node('root', {'x': ref('§n')})),
        );
        expect(message, contains('returned nope (String)'));
        expect(message, contains('resultType "number"'));

        final ok = resolver({
          '§n': {
            'resultType': 'number',
            'variants': [
              {'expression': '1.0'},
            ],
          },
        }).resolve(node('root', {'x': ref('§n')}));
        expect(ok.getOrNull<dynamic>('./#x'), 1.0);
      });

      test('should report stuck resolutions with all pending items', () {
        final tree = node('root', {
          'a': ref('§aRule'),
          'b': {
            '§expression': 'x',
            '§inputs': {'x': '#a'},
          },
        });
        final e = catchException(
          () => resolver({
            '§aRule': [
              {
                'selector': {'#b': 1},
                'expression': '1',
              },
            ],
          }).resolve(tree),
        );
        expect(e, isA<StuckException>());
        expect(e!.message, contains('Resolution is stuck: 2 item(s)'));
        expect(e.message, contains('reference "§aRule" at "/#a"'));
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
          'm': ref('§withMapDefault'),
          'l': ref('§withListDefault'),
          's': ref('§withScalarDefault'),
        });
        final resolved = resolver({
          '§withMapDefault': [
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
          '§withListDefault': [
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
          '§withScalarDefault': [
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
            '§x': [
              {
                'inputs': {'w': '#missing'},
                'expression': 'w',
              },
            ],
          }).resolve(node('root', {'x': ref('§x')})),
        );
        expect(e, isA<MissingInputException>());
        expect(e!.message, contains('Missing input "w" of rule "§x"'));
        expect(e.message, contains('query "#missing" resolved to nothing'));
        expect((e as MissingInputException).inputName, 'w');
      });

      test('should wrap input shape errors with context', () {
        final e = catchException(
          () => resolver({
            '§x': [
              {
                'inputs': {'w': './#num/deep'},
                'expression': 'w',
              },
            ],
          }).resolve(node('root', {'num': 5, 'x': ref('§x')})),
        );
        expect(e, isA<QueryException>());
        expect(e!.message, contains('While binding input "w" of rule "§x"'));
        expect(e.message, contains('is not a Map'));
      });

      test('should wrap evaluation errors with rule context', () {
        final e = catchException(
          () => resolver({
            '§x': [
              {
                'inputs': {'w': '#w'},
                'expression': "w < 'text'",
              },
            ],
          }).resolve(node('root', {'w': 5, 'x': ref('§x')})),
        );
        expect(e, isA<ExpressionException>());
        expect(
          e!.message,
          contains('While resolving rule "§x" (variant 0) at "/#x"'),
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

    group('resolveRule()', () {
      final rule = Rule.fromJson('§w', [
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

      test('should throw when selection is blocked', () {
        final blockedRule = Rule.fromJson('§w', [
          {
            'selector': {'#u': 1},
            'expression': '1',
          },
        ]);
        final message = messageOfCall(
          () => resolver(
            {},
          ).resolveRule(node('root', {'u': ref('§x')}), blockedRule),
        );
        expect(message, contains('Cannot resolve rule "§w" at node "/"'));
        expect(message, contains('selector condition "#u" waits'));
      });

      test('should throw when inputs are blocked', () {
        final message = messageOfCall(
          () => resolver(
            {},
          ).resolveRule(node('root', {'width': ref('§x')}), rule),
        );
        expect(message, contains('Cannot resolve rule "§w" at node "/"'));
        expect(message, contains('input "w" of rule "§w"'));
      });

      test('should return null for optional rules without match', () {
        final optional = Rule.fromJson('§w', {
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
        final strict = Rule.fromJson('§w', [
          {
            'selector': {'#never': 1},
            'expression': '1',
          },
        ]);
        final message = messageOfCall(
          () => resolver({}).resolveRule(node('root', {}), strict),
        );
        expect(message, contains('No variant of rule "§w" matches at "/"'));
      });
    });
  });
}

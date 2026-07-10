// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Stopwatch-based performance harness for gg_tree_expressions.
//
// Lives in benchmark/ (ignored by gg). Code stays inside main() or
// private helpers so the repo-wide lints pass without doc burden, and
// writes only to stdout — never stderr (gg deadlocks on undrained
// child stderr).
//
// Run JIT:  dart run benchmark/main.dart jit
// Run AOT:  dart compile exe benchmark/main.dart -o build/bench.exe
//           build/bench.exe aot
// Optional 2nd arg = run-count scale (default 1.0).

import 'dart:io';
import 'dart:math';

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';
import 'package:gg_tree_expressions/gg_tree_expressions.dart';

// Consumes benchmark results so the AOT optimizer cannot elide the
// timed work. Printed once at the end.
int _sink = 0;

/// Runs the full benchmark suite and prints Markdown tables to stdout.
void main(List<String> args) {
  final label = args.isNotEmpty ? args[0] : 'jit';
  final scale = args.length > 1 ? double.parse(args[1]) : 1.0;
  final runs = max(20, (20 * scale).round());
  final warmup = max(5, (5 * scale).round());

  _printHeader(label);

  _section('End-to-end resolve() — median / p90 (µs)');
  print(
    '| profile | shape | copy median | copy p90 | '
    'inPlace median | inPlace p90 |',
  );
  print('|---|---|--:|--:|--:|--:|');
  for (final profile in _profiles()) {
    _runEndToEnd(profile, warmup: warmup, runs: runs);
  }
  print('');

  _section('Grow loop — resolve → grow → resolve ×3, resolve µs only');
  print('| profile | resolves | median | p90 |');
  print('|---|--:|--:|--:|');
  _runGrowLoop(warmup: warmup, runs: runs);
  print('');

  _section('Resolver construction — cold vs shared-cache warm (µs)');
  print('| book | rules | variants | cold median | cold p90 | warm median |');
  print('|---|--:|--:|--:|--:|--:|');
  _runConstruction(warmup: warmup, runs: runs);
  print('');

  _section('Micro-benchmarks — median / p90 (ns per op)');
  print('| micro | median | p90 |');
  print('|---|--:|--:|');
  _runMicros(warmup: warmup, runs: runs);
  print('');

  print('<!-- sink=$_sink -->');
}

// ...........................................................................
// Reporting helpers

void _printHeader(String label) {
  print('# gg_tree_expressions benchmark — $label');
  print('');
  print('- Dart: `${Platform.version}`');
  print(
    '- OS: `${Platform.operatingSystem} '
    '${Platform.operatingSystemVersion}`',
  );
  print('- CPUs: `${Platform.numberOfProcessors}`');
  print('');
}

void _section(String title) {
  print('## $title');
  print('');
}

String _f(double v) => v.toStringAsFixed(1);

// ...........................................................................
// Timing primitives

class _Stats {
  _Stats(this.median, this.p90, this.min);
  final double median;
  final double p90;
  final double min;
}

_Stats _statsOf(List<double> xs) {
  final s = [...xs]..sort();
  double at(double q) => s[(q * (s.length - 1)).round()];
  return _Stats(at(0.5), at(0.9), s.first);
}

/// Times [body] over [runs] samples after [warmup] samples. [prep]
/// runs outside the timed region (used to hand inPlace a fresh,
/// still-unresolved working tree each run).
_Stats _bench<T>(
  T Function() prep,
  void Function(T) body, {
  required int warmup,
  required int runs,
}) {
  for (var i = 0; i < warmup; i++) {
    body(prep());
  }
  final xs = <double>[];
  for (var i = 0; i < runs; i++) {
    final input = prep();
    final sw = Stopwatch()..start();
    body(input);
    sw.stop();
    xs.add(sw.elapsedMicroseconds.toDouble());
  }
  return _statsOf(xs);
}

/// Times a tiny [op] by running it [inner] times per sample and
/// dividing, reporting nanoseconds per op.
_Stats _benchMicro(
  void Function() op, {
  required int inner,
  required int warmup,
  required int runs,
}) {
  for (var i = 0; i < warmup; i++) {
    for (var j = 0; j < inner; j++) {
      op();
    }
  }
  final xs = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch()..start();
    for (var j = 0; j < inner; j++) {
      op();
    }
    sw.stop();
    xs.add(sw.elapsedMicroseconds * 1000.0 / inner);
  }
  return _statsOf(xs);
}

// ...........................................................................
// Profiles

class _Profile {
  _Profile(this.name, this.shape, this.book, this.tree, {this.copyable = true});
  final String name;
  final String shape;
  final RuleBook book;
  final Tree<Json> tree;

  /// deepChain/growLoop trees are described inPlace-only.
  final bool copyable;
}

List<_Profile> _profiles() => [
  _slotTreeLike('slotTreeLike/255', depth: 7, branching: 2, rules: 30),
  _slotTreeLike('slotTreeLike/1093', depth: 6, branching: 3, rules: 30),
  _denseRefs('denseRefs/511', depth: 8, branching: 2),
  _deepChain('deepChain/8', length: 8),
  _deepChain('deepChain/32', length: 32),
  _wideBook('wideBook/500', rules: 500, fatVariants: 16, refs: 100),
  _bigValues('bigValues/1000', entries: 1000, refs: 8),
];

void _runEndToEnd(_Profile p, {required int warmup, required int runs}) {
  final resolver = Resolver(ruleBook: p.book);
  final nodes = p.tree.lsNodes().length;
  final shape = '${p.shape} ($nodes nodes)';

  _Stats? copy;
  if (p.copyable) {
    copy = _bench<Tree<Json>>(
      () => p.tree,
      (t) => _sink ^= resolver.resolve(t).key.length,
      warmup: warmup,
      runs: runs,
    );
  }

  final inPlace = _bench<Tree<Json>>(
    () => p.tree.deepCopy(),
    (t) => _sink ^= resolver.resolve(t, inPlace: true).key.length,
    warmup: warmup,
    runs: runs,
  );

  final cm = copy == null ? '—' : _f(copy.median);
  final cp = copy == null ? '—' : _f(copy.p90);
  print(
    '| ${p.name} | $shape | $cm | $cp | '
    '${_f(inPlace.median)} | ${_f(inPlace.p90)} |',
  );
}

// ...........................................................................
// Profile builders

_Profile _slotTreeLike(
  String name, {
  required int depth,
  required int branching,
  required int rules,
}) {
  final book = RuleBook.fromJson(_slotBook(rules));
  final rnd = Random(0x51013 + depth);
  var index = 0;
  Json rootData() => <String, dynamic>{
    'kind': 'normal',
    'platform': 'mobile',
    'settings': <String, dynamic>{
      'dims': <String, dynamic>{'width': 600.0, 'height': 720.0},
      'factor': 1.1,
    },
  };
  Json dataFor(int d) {
    final data = d == 0 ? rootData() : <String, dynamic>{'depth': d};
    if (rnd.nextDouble() < 0.10) {
      data['pw'] = <String, dynamic>{'§': '§r${rnd.nextInt(rules)}'};
    }
    return data;
  }

  final tree = _buildTree(
    depth: depth,
    branching: branching,
    keyFor: () => 'n${index++}',
    dataFor: dataFor,
  );
  return _Profile(name, 'depth $depth, ~10% refs, $rules rules', book, tree);
}

_Profile _denseRefs(String name, {required int depth, required int branching}) {
  const rules = 20;
  final book = RuleBook.fromJson(_slotBook(rules));
  final rnd = Random(0xDE45E);
  var index = 0;
  Json dataFor(int d) {
    final data = <String, dynamic>{
      if (d == 0) ...{
        'settings': <String, dynamic>{
          'dims': <String, dynamic>{'width': 600.0, 'height': 720.0},
          'factor': 1.1,
        },
      },
    };
    // A ref or an inline expression on every node.
    if (rnd.nextBool()) {
      data['v'] = <String, dynamic>{'§': '§r${rnd.nextInt(rules)}'};
    } else {
      data['v'] = <String, dynamic>{
        '§expression': 'x * 2.0',
        '§inputs': <String, dynamic>{
          'x': <String, dynamic>{'query': '#settings/factor', 'default': 1.0},
        },
      };
    }
    return data;
  }

  final tree = _buildTree(
    depth: depth,
    branching: branching,
    keyFor: () => 'n${index++}',
    dataFor: dataFor,
  );
  return _Profile(name, 'ref/inline on every node', book, tree);
}

_Profile _deepChain(String name, {required int length}) {
  final book = RuleBook.fromJson(<String, dynamic>{
    '§chain': [
      <String, dynamic>{
        'inputs': <String, dynamic>{
          'child': <String, dynamic>{'query': './c#chainValue', 'default': 0},
        },
        'expression': 'child + 1',
      },
    ],
  });

  Tree<Json> node(int remaining) => Tree<Json>(
    key: remaining == length ? 'root' : 'c',
    data: <String, dynamic>{
      'chainValue': <String, dynamic>{'§': '§chain'},
    },
    children: [if (remaining > 1) node(remaining - 1)],
  );

  return _Profile(
    name,
    'linear chain, each reads child',
    book,
    node(length),
    copyable: false,
  );
}

_Profile _wideBook(
  String name, {
  required int rules,
  required int fatVariants,
  required int refs,
}) {
  final book = <String, dynamic>{};
  // A handful of "fat" rules with many multi-condition variants — the
  // ones the tree actually references, stressing Rule.select.
  const fatCount = 5;
  for (var r = 0; r < fatCount; r++) {
    final variants = <dynamic>[
      <String, dynamic>{'expression': '$r.0'},
    ];
    for (var v = 0; v < fatVariants; v++) {
      variants.add(<String, dynamic>{
        'selector': <String, dynamic>{
          '#a': 'a$v',
          '#b': 'b${v % 4}',
          '#c': v.isEven,
        },
        'expression': '${r * 100 + v}.0',
      });
    }
    book['§w$r'] = variants;
  }
  // Padding rules with distinct expressions (construction cost).
  for (var r = fatCount; r < rules; r++) {
    book['§w$r'] = [
      <String, dynamic>{'expression': '$r.0 + 0.$r'},
    ];
  }

  final rnd = Random(0x1DEB0);
  var index = 0;
  final tree = _buildTree(
    depth: 6,
    branching: 2,
    keyFor: () => 'n${index++}',
    dataFor: (d) {
      // Data that makes some fat variant match (all are still checked).
      final data = <String, dynamic>{
        'a': 'a${rnd.nextInt(fatVariants)}',
        'b': 'b${rnd.nextInt(4)}',
        'c': rnd.nextBool(),
      };
      if (rnd.nextDouble() < refs / 127.0) {
        data['v'] = <String, dynamic>{'§': '§w${rnd.nextInt(fatCount)}'};
      }
      return data;
    },
  );
  return _Profile(
    name,
    '$rules rules, $fatVariants variants×3 conds',
    RuleBook.fromJson(book),
    tree,
  );
}

_Profile _bigValues(String name, {required int entries, required int refs}) {
  final blob = <String, dynamic>{
    for (var i = 0; i < entries; i++)
      'e$i': <String, dynamic>{'x': i, 'y': 'v$i', 'z': i.isEven},
  };
  final book = RuleBook.fromJson(<String, dynamic>{
    '§big': [
      <String, dynamic>{
        'inputs': <String, dynamic>{'b': '#blob'},
        // Reads one member; the cost under test is the containsMarker
        // deep-walk over the bound big value, not the expression.
        'expression': "b['e0']['x'] + 1",
      },
    ],
  });

  final children = <Tree<Json>>[];
  for (var i = 0; i < refs; i++) {
    children.add(
      Tree<Json>(
        key: 'n$i',
        data: <String, dynamic>{
          'v': <String, dynamic>{'§': '§big'},
        },
      ),
    );
  }
  final tree = Tree<Json>(
    key: 'root',
    data: <String, dynamic>{'blob': blob},
    children: children,
  );
  return _Profile(name, '$refs refs, blob of $entries entries', book, tree);
}

void _runGrowLoop({required int warmup, required int runs}) {
  const rules = 20;
  final book = RuleBook.fromJson(_slotBook(rules));
  final resolver = Resolver(ruleBook: book);
  final rnd = Random(0x9807);
  var index = 0;
  final base = _buildTree(
    depth: 6,
    branching: 2,
    keyFor: () => 'g${index++}',
    dataFor: (d) {
      final data = d == 0
          ? <String, dynamic>{
              'settings': <String, dynamic>{
                'dims': <String, dynamic>{'width': 600.0, 'height': 720.0},
                'factor': 1.1,
              },
            }
          : <String, dynamic>{'depth': d};
      if (rnd.nextDouble() < 0.10) {
        data['pw'] = <String, dynamic>{'§': '§r${rnd.nextInt(rules)}'};
      }
      return data;
    },
  );

  final graftRnd = Random(0x6ADD);
  // Grafts fresh ref-carrying leaves onto existing leaves, so the next
  // resolve re-collects the whole tree but only the new refs are work.
  void graft(Tree<Json> work, String tag) {
    final leaves = work.lsNodes().where((n) => n.children.isEmpty).toList();
    for (var i = 0; i < 8 && leaves.isNotEmpty; i++) {
      final leaf = leaves[graftRnd.nextInt(leaves.length)];
      leaf.addChildren([
        Tree<Json>(
          key: '$tag$i',
          data: <String, dynamic>{
            'pw': <String, dynamic>{'§': '§r${graftRnd.nextInt(rules)}'},
          },
        ),
      ]);
    }
  }

  void oneRun(Stopwatch sw) {
    final work = base.deepCopy();
    sw.start();
    resolver.resolve(work, inPlace: true);
    sw.stop();
    graft(work, 'a');
    sw.start();
    resolver.resolve(work, inPlace: true);
    sw.stop();
    graft(work, 'b');
    sw.start();
    _sink ^= resolver.resolve(work, inPlace: true).key.length;
    sw.stop();
  }

  for (var i = 0; i < warmup; i++) {
    oneRun(Stopwatch());
  }
  final xs = <double>[];
  for (var i = 0; i < runs; i++) {
    final sw = Stopwatch();
    oneRun(sw);
    xs.add(sw.elapsedMicroseconds.toDouble());
  }
  final s = _statsOf(xs);
  print('| growLoop/x3 | 3 | ${_f(s.median)} | ${_f(s.p90)} |');
}

// ...........................................................................
// Construction

void _runConstruction({required int warmup, required int runs}) {
  final books = <String, Json>{
    'slotBook/30': _slotBook(30),
    'wideBook/500': _wideBookJson(500, 16),
  };
  for (final MapEntry(:key, :value) in books.entries) {
    final parsed = RuleBook.fromJson(value);
    var ruleCount = 0;
    var variantCount = 0;
    for (final k in parsed.keys) {
      ruleCount++;
      variantCount += parsed.ruleForKey(k)!.variants.length;
    }
    final cold = _bench<RuleBook>(
      () => parsed,
      (b) => _sink ^= Resolver(ruleBook: b).ruleBook.keys.length,
      warmup: warmup,
      runs: runs,
    );

    // Warm: a shared, pre-filled cache — the Resolver-per-fit consumer
    // scenario (one cache, many resolvers over the same book).
    final shared = <String, CompiledExpression>{};
    Resolver(ruleBook: parsed, expressionCache: shared);
    final warm = _bench<RuleBook>(
      () => parsed,
      (b) => _sink ^= Resolver(
        ruleBook: b,
        expressionCache: shared,
      ).ruleBook.keys.length,
      warmup: warmup,
      runs: runs,
    );

    print(
      '| $key | $ruleCount | $variantCount | '
      '${_f(cold.median)} | ${_f(cold.p90)} | ${_f(warm.median)} |',
    );
  }
}

// ...........................................................................
// Micro-benchmarks

void _runMicros({required int warmup, required int runs}) {
  // A small fixed tree with inherited settings and a child.
  final root = Tree<Json>(
    key: 'root',
    data: <String, dynamic>{
      'a': 7,
      'kind': 'normal',
      'list': <dynamic>[10, 20, 30],
      'settings': <String, dynamic>{
        'dims': <String, dynamic>{'width': 600.0},
        'factor': 1.1,
      },
    },
    children: [
      Tree<Json>(
        key: 'mid',
        data: <String, dynamic>{'b': 3},
        children: [
          Tree<Json>(key: 'leaf', data: <String, dynamic>{'c': 5}),
        ],
      ),
    ],
  );
  final leaf = root.childByPath('mid/leaf');

  void micro(String label, int inner, void Function() op) {
    final s = _benchMicro(op, inner: inner, warmup: warmup, runs: runs);
    print('| $label | ${_f(s.median)} | ${_f(s.p90)} |');
  }

  void read(String label, Tree<Json> node, String query) => micro(
    'readQuery $label ("$query")',
    2000,
    () => _sink ^= _consume(readQuery(node, query)),
  );

  read('own', leaf, './#c');
  read('inherited', leaf, '#a');
  read('multi-seg inherited', leaf, '#settings/dims/width');
  read('child', root, 'mid#b');
  read('indexed', root, '#list[1]');
  read('absolute', leaf, '/#a');

  // Selector.match — matching and non-matching.
  final selMatch = Selector.fromJson(<String, dynamic>{
    '#kind': 'normal',
    '#a': 7,
  }, context: 'bench');
  final selMiss = Selector.fromJson(<String, dynamic>{
    '#kind': 'special',
    '#a': 7,
  }, context: 'bench');
  micro(
    'Selector.match (hit)',
    2000,
    () => _sink ^= selMatch.match(leaf).hashCode,
  );
  micro(
    'Selector.match (miss)',
    2000,
    () => _sink ^= selMiss.match(leaf).hashCode,
  );

  // CompiledExpression.evaluate — compile once, evaluate many.
  final expr = CompiledExpression.compile('w < 400.0 ? 3.0 : 2.0');
  micro(
    'CompiledExpression.evaluate',
    2000,
    () => _sink ^= expr.evaluate(<String, Object?>{'w': 380.0}).hashCode,
  );

  // containsMarker on a large marker-free value (worst case: full walk).
  final bigValue = <String, dynamic>{
    for (var i = 0; i < 1000; i++)
      'e$i': <String, dynamic>{'x': i, 'y': 'v$i', 'z': i.isEven},
  };
  micro(
    'containsMarker (1000-entry value)',
    50,
    () => _sink ^= containsMarker(bigValue) ? 1 : 0,
  );
}

int _consume(ReadResult r) => switch (r) {
  ReadValue(:final value) => value.hashCode,
  ReadMissing() => 1,
  ReadBlocked(:final blocker) => blocker.length,
};

// ...........................................................................
// Shared generators

Tree<Json> _buildTree({
  required int depth,
  required int branching,
  required String Function() keyFor,
  required Json Function(int depthLevel) dataFor,
}) {
  Tree<Json> build(int level) => Tree<Json>(
    key: level == 0 ? 'root' : keyFor(),
    data: dataFor(level),
    children: [
      if (level < depth)
        for (var i = 0; i < branching; i++) build(level + 1),
    ],
  );
  return build(0);
}

Json _slotBook(int rules) {
  final book = <String, dynamic>{};
  for (var i = 0; i < rules; i++) {
    book['§r$i'] = [
      <String, dynamic>{
        'inputs': <String, dynamic>{
          'w': '#settings/dims/width',
          'f': <String, dynamic>{'query': '#settings/factor', 'default': 1.0},
        },
        'expression': 'w * f + $i.0',
      },
      <String, dynamic>{
        'selector': <String, dynamic>{'#kind': 'special'},
        'inputs': <String, dynamic>{'w': '#settings/dims/width'},
        'expression': 'w * 2.0',
      },
    ];
  }
  return book;
}

Json _wideBookJson(int rules, int fatVariants) {
  final book = <String, dynamic>{};
  const fatCount = 5;
  for (var r = 0; r < fatCount; r++) {
    final variants = <dynamic>[
      <String, dynamic>{'expression': '$r.0'},
    ];
    for (var v = 0; v < fatVariants; v++) {
      variants.add(<String, dynamic>{
        'selector': <String, dynamic>{
          '#a': 'a$v',
          '#b': 'b${v % 4}',
          '#c': v.isEven,
        },
        'expression': '${r * 100 + v}.0',
      });
    }
    book['§w$r'] = variants;
  }
  for (var r = fatCount; r < rules; r++) {
    book['§w$r'] = [
      <String, dynamic>{'expression': '$r.0 + 0.$r'},
    ];
  }
  return book;
}

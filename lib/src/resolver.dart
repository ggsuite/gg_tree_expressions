// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';

import 'compiled_expression.dart';
import 'rule.dart';
import 'rule_book.dart';
import 'rule_ref.dart';
import 'rule_variant.dart';
import 'tree_expressions_exception.dart';
import 'tree_reader.dart';

/// Resolves all rule references and inline expressions in a tree.
///
/// One [resolve] call replaces every reference by the value its
/// rule's expression evaluates to in the context of the node holding
/// the reference. Order does not matter: items whose selectors or
/// inputs read still-unresolved values are deferred and retried. A
/// resolved tree contains no markers, so [resolve] is idempotent and
/// re-runnable (resolve → grow the tree → resolve again).
class Resolver {
  /// Creates a resolver and compiles all rule book expressions.
  ///
  /// Compilation problems are reported immediately with their rule
  /// key and variant index.
  ///
  /// Pass an [expressionCache] to share compiled expressions across
  /// resolvers. A compiled expression is a pure function of its source
  /// string, so a consumer that builds one resolver per fit/article can
  /// hand every resolver the same cache and pay the (ANTLR) compile
  /// cost once per distinct expression instead of once per resolver.
  Resolver({
    required this.ruleBook,
    Map<String, CompiledExpression>? expressionCache,
  }) : _cache = expressionCache ?? <String, CompiledExpression>{} {
    for (final key in ruleBook.keys) {
      final rule = ruleBook.ruleForKey(key)!;
      for (var i = 0; i < rule.variants.length; i++) {
        final expression = rule.variants[i].expression;
        try {
          CompiledExpression.compile(expression, cache: _cache);
        } on TreeExpressionsException catch (e) {
          throw ExpressionException([
            'In rule "$key", variant $i:',
            ...e.messages,
          ], expression: expression);
        }
      }
    }
  }

  /// The merged rule book answering all references.
  final RuleBook ruleBook;

  final Map<String, CompiledExpression> _cache;

  /// Re-enqueue limit per tree location; exceeding it means an
  /// expression keeps regenerating itself.
  static const int maxResolutionSteps = 64;

  // ...........................................................................
  /// Resolves all markers in [tree].
  ///
  /// By default the tree is deep-copied and the copy is returned;
  /// the original keeps its references and can be re-resolved later
  /// against changed context. Copy mode requires the tree root —
  /// a detached subtree copy would silently lose inherited context.
  /// With [inPlace] the tree is mutated directly; this also resolves
  /// a subtree within its full tree. On error the working tree may
  /// be partially resolved.
  Tree<T> resolve<T extends Json>(Tree<T> tree, {bool inPlace = false}) {
    if (!inPlace && !tree.isRoot) {
      throw ResolveException([
        'resolve() would deep-copy the subtree at "${tree.path}" '
            'without its ancestors — selectors and inputs would '
            'silently lose their inherited context.',
        'Resolve the root instead (tree.root), or resolve the '
            'subtree within its tree using inPlace: true.',
      ]);
    }

    final working = inPlace ? tree : _deepCopy(tree);

    var pending = _collect(working);
    while (pending.isNotEmpty) {
      var progressed = false;
      final deferred = <_WorkItem>[];
      final discovered = <_WorkItem>[];

      for (final item in pending) {
        if (_step(item, discovered)) {
          progressed = true;
        } else {
          deferred.add(item);
        }
      }

      if (!progressed) throw _stuck(deferred);
      pending = [...deferred, ...discovered];
    }
    return working;
  }

  // ...........................................................................
  /// Evaluates one [rule] at [node] without touching the tree.
  ///
  /// Meant for tooling and tests. Returns null when no variant
  /// matches and the rule is optional; throws when the rule cannot
  /// be resolved right now (blocked on unresolved values).
  Object? resolveRule(Tree<Json> node, Rule rule) {
    final context = 'rule "${rule.key}" at node "${node.path}"';
    switch (rule.select(node)) {
      case SelectBlocked(:final query, :final blocker):
        throw ResolveException([
          'Cannot resolve $context:',
          'selector condition "$query" waits for the unresolved '
              'value at "$blocker".',
        ]);
      case SelectNone(:final reasons):
        if (rule.isOptional) return null;
        throw _noVariantMatched(rule, node.path, reasons);
      case SelectMatch(:final variant, :final index):
        final inputs = _bindInputs(variant, node, rule.key, index);
        if (inputs is _Blocked) {
          throw ResolveException(['Cannot resolve $context:', inputs.reason]);
        }
        return _evaluate(
          variant,
          inputs as Map<String, Object?>,
          rule,
          index,
          node.path,
        );
    }
  }

  // ...........................................................................
  // Collect

  List<_WorkItem> _collect(Tree<Json> tree) {
    final items = <_WorkItem>[];
    tree.visit((node) {
      for (final MapEntry(:key, :value) in node.data.entries.toList()) {
        _scanValue(
          node: node,
          container: node.data,
          keyOrIndex: key,
          value: value,
          dataPath: key,
          chain: const [],
          steps: 0,
          out: items,
        );
      }
    });
    return items;
  }

  void _scanValue({
    required Tree<Json> node,
    required Object container,
    required Object keyOrIndex,
    required Object? value,
    required String dataPath,
    required List<String> chain,
    required int steps,
    required List<_WorkItem> out,
  }) {
    if (isMarker(value)) {
      out.add(
        _WorkItem(
          node: node,
          container: container,
          keyOrIndex: keyOrIndex,
          value: value as Object,
          dataPath: dataPath,
          location: '${node.path}#$dataPath',
          chain: chain,
          steps: steps,
        ),
      );
      return;
    }
    if (value is Map) {
      for (final entry in value.entries.toList()) {
        _scanValue(
          node: node,
          container: value,
          keyOrIndex: entry.key as Object,
          value: entry.value,
          dataPath: '$dataPath/${entry.key}',
          chain: chain,
          steps: steps,
          out: out,
        );
      }
    } else if (value is List) {
      for (var i = 0; i < value.length; i++) {
        _scanValue(
          node: node,
          container: value,
          keyOrIndex: i,
          value: value[i],
          dataPath: '$dataPath[$i]',
          chain: chain,
          steps: steps,
          out: out,
        );
      }
    }
  }

  // ...........................................................................
  // Worklist steps

  /// Processes one item. Returns true when it was resolved, false
  /// when it must be retried in the next round.
  bool _step(_WorkItem item, List<_WorkItem> discovered) {
    final map = item.value as Map<dynamic, dynamic>;
    if (isReference(map)) {
      return _stepReference(item, _referencedKey(item, map), discovered);
    }
    if (isInlineExpression(map)) {
      return _stepInline(item, discovered);
    }

    final offending = map.keys
        .where((k) => k is String && k.startsWith('§'))
        .map((k) => '"$k"')
        .join(', ');
    throw SchemaException([
      'Invalid marker at "${item.location}": the key(s) $offending '
          'match no known form.',
      '',
      'Maps with §-keys are reserved. Allowed forms:',
      '  - reference:         {"$referenceKey": "§ruleName"}',
      '  - inline expression: {"$inlineExpressionKey": "…", '
          '"$inlineInputsKey": {…}}',
    ]);
  }

  /// Validates the reference form and extracts the rule key.
  String _referencedKey(_WorkItem item, Map<dynamic, dynamic> map) {
    final key = map[referenceKey];
    if (map.length != 1 || key is! String || !isRuleKey(key)) {
      throw SchemaException([
        'Invalid reference at "${item.location}": $map',
        'A reference is a map with the single key "$referenceKey" '
            'holding a rule key, e.g. {"$referenceKey": '
            '"§borderWidth"}.',
      ]);
    }
    return key;
  }

  bool _stepReference(_WorkItem item, String key, List<_WorkItem> discovered) {
    if (item.chain.contains(key)) {
      final chain = [...item.chain, key];
      throw CircularAliasException(
        [
          'Circular rule alias at "${item.location}":',
          '  ${chain.join(' → ')}',
        ],
        chain: chain,
        location: item.location,
      );
    }

    final rule = ruleBook.ruleForKey(key);
    if (rule == null) {
      final suggestions = ruleBook.suggestionsFor(key);
      throw UnknownRuleException(
        [
          'Unknown rule "$key" referenced at "${item.location}".',
          if (suggestions.isNotEmpty)
            'Did you mean ${suggestions.map((s) => '"$s"').join(', ')}?',
          '',
          'Available rules:',
          ...ruleBook.keys.map((k) => '  - $k'),
        ],
        ruleKey: key,
        location: item.location,
        suggestions: suggestions,
      );
    }

    switch (rule.select(item.node)) {
      case SelectBlocked(:final query, :final blocker):
        item.blockReason =
            'selector condition "$query" waits for the '
            'unresolved value at "$blocker"';
        return false;
      case SelectNone(:final reasons):
        if (rule.isOptional) {
          _remove(item);
          return true;
        }
        throw _noVariantMatched(rule, item.location, reasons);
      case SelectMatch(:final variant, :final index):
        final inputs = _bindInputs(variant, item.node, key, index);
        if (inputs is _Blocked) {
          item.blockReason = inputs.reason;
          return false;
        }
        final result = _evaluate(
          variant,
          inputs as Map<String, Object?>,
          rule,
          index,
          item.location,
        );
        _writeAndRescan(item, result, [...item.chain, key], discovered);
        return true;
    }
  }

  bool _stepInline(_WorkItem item, List<_WorkItem> discovered) {
    final map = item.value as Map<dynamic, dynamic>;
    const allowed = {inlineExpressionKey, inlineInputsKey};
    final unknown = map.keys.where((k) => !allowed.contains(k));
    if (unknown.isNotEmpty) {
      throw SchemaException([
        'Invalid inline expression at "${item.location}": unknown '
            'key(s) ${unknown.map((k) => '"$k"').join(', ')}.',
        '',
        'Allowed keys:',
        ...allowed.map((k) => '  - $k'),
      ]);
    }

    final context = 'the inline expression at "${item.location}"';
    final variant = RuleVariant.fromJson({
      'expression': map[inlineExpressionKey],
      if (map[inlineInputsKey] != null) 'inputs': map[inlineInputsKey],
    }, context: context);

    final inputs = _bindInputs(variant, item.node, null, null);
    if (inputs is _Blocked) {
      item.blockReason = inputs.reason;
      return false;
    }

    final CompiledExpression expression;
    try {
      expression = CompiledExpression.compile(
        variant.expression,
        cache: _cache,
      );
    } on TreeExpressionsException catch (e) {
      throw ExpressionException([
        'In $context:',
        ...e.messages,
      ], expression: variant.expression);
    }

    final Object? result;
    try {
      result = expression.evaluate(inputs as Map<String, Object?>);
    } on TreeExpressionsException catch (e) {
      throw ExpressionException([
        'In $context:',
        ...e.messages,
      ], expression: variant.expression);
    }

    _writeAndRescan(item, result, item.chain, discovered);
    return true;
  }

  // ...........................................................................
  // Input binding & evaluation

  /// Binds the variant's inputs at [node]. Returns the activation
  /// map, or a [_Blocked] when a query reads an unresolved value.
  Object _bindInputs(
    RuleVariant variant,
    Tree<Json> node,
    String? ruleKey,
    int? variantIndex,
  ) {
    String describe(String input) => ruleKey == null
        ? 'input "$input" of the inline expression'
        : 'input "$input" of rule "$ruleKey" (variant $variantIndex)';

    final bound = <String, Object?>{};
    for (final MapEntry(key: name, value: input) in variant.inputs.entries) {
      final ReadResult result;
      try {
        result = readQuery(node, input.query);
      } on QueryException catch (e) {
        throw QueryException(
          ['While binding ${describe(name)}:', ...e.messages],
          query: e.query,
          nodePath: e.nodePath,
        );
      }

      switch (result) {
        case ReadBlocked(:final blocker):
          return _Blocked(
            '${describe(name)} ("${input.query}") waits for the '
            'unresolved value at "$blocker"',
          );
        case ReadMissing():
          if (!input.hasDefault) {
            throw MissingInputException(
              [
                'Missing ${describe(name)} at node "${node.path}":',
                'the query "${input.query}" resolved to nothing and '
                    'no default is declared.',
              ],
              inputName: name,
              query: input.query,
            );
          }
          bound[name] = _copied(input.defaultValue);
        case ReadValue(:final value):
          bound[name] = value;
      }
    }
    return bound;
  }

  Object? _evaluate(
    RuleVariant variant,
    Map<String, Object?> inputs,
    Rule rule,
    int variantIndex,
    String location,
  ) {
    final Object? result;
    try {
      result = CompiledExpression.compile(
        variant.expression,
        cache: _cache,
      ).evaluate(inputs);
    } on TreeExpressionsException catch (e) {
      throw ExpressionException([
        'While resolving rule "${rule.key}" (variant $variantIndex) '
            'at "$location":',
        ...e.messages,
      ], expression: variant.expression);
    }

    final resultType = rule.resultType;
    if (resultType != null && !resultType.accepts(result)) {
      throw ResolveException([
        'Rule "${rule.key}" (variant $variantIndex) at "$location" '
            'returned $result (${result.runtimeType}) but declares '
            'resultType "${resultType.jsonValue}".',
      ]);
    }
    return result;
  }

  // ...........................................................................
  // Writing

  void _write(_WorkItem item, Object? result) {
    final container = item.container;
    if (container is Map) {
      container[item.keyOrIndex] = result;
    } else {
      (container as List)[item.keyOrIndex as int] = result;
    }
  }

  void _remove(_WorkItem item) {
    final container = item.container;
    if (container is Map) {
      container.remove(item.keyOrIndex);
    } else {
      (container as List)[item.keyOrIndex as int] = null;
    }
  }

  /// Writes [result] and enqueues any markers it contains (rule
  /// aliasing and nested references), guarded against expressions
  /// that regenerate themselves forever.
  void _writeAndRescan(
    _WorkItem item,
    Object? result,
    List<String> chain,
    List<_WorkItem> discovered,
  ) {
    _write(item, result);
    if (!containsMarker(result)) return;

    if (item.steps + 1 > maxResolutionSteps) {
      throw ResolveException([
        'Resolution at "${item.location}" did not settle after '
            '$maxResolutionSteps steps.',
        'An expression there keeps producing new references or '
            'inline expressions.',
      ]);
    }
    _scanValue(
      node: item.node,
      container: item.container,
      keyOrIndex: item.keyOrIndex,
      value: result,
      dataPath: item.dataPath,
      chain: chain,
      steps: item.steps + 1,
      out: discovered,
    );
  }

  // ...........................................................................
  // Helpers & diagnostics

  Tree<T> _deepCopy<T extends Json>(Tree<T> tree) {
    try {
      return tree.deepCopy();
    } catch (e) {
      throw ResolveException([
        'Cannot deep-copy the tree for resolution:',
        messageOf(e),
        'Trees holding non-JSON data values cannot be copied. '
            'Resolve with inPlace: true or remove those values.',
      ]);
    }
  }

  Object? _copied(Object? value) {
    if (value is Map) return deepCopy(value.cast<String, dynamic>());
    if (value is List) return deepCopyList(value);
    return value;
  }

  NoVariantException _noVariantMatched(
    Rule rule,
    String location,
    List<String> reasons,
  ) => NoVariantException(
    [
      'No variant of rule "${rule.key}" matches at "$location":',
      ...reasons.map((r) => '  - $r'),
      'Add a base variant (without selector) or mark the rule as '
          'optional.',
    ],
    ruleKey: rule.key,
    location: location,
    reasons: reasons,
  );

  StuckException _stuck(List<_WorkItem> deferred) {
    final pending = [
      for (final item in deferred)
        '${item.describeValue} at "${item.location}": '
            '${item.blockReason ?? 'blocked'}',
    ];
    return StuckException([
      'Resolution is stuck: ${deferred.length} item(s) remain but '
          'the last round made no progress.',
      '',
      'Pending items:',
      ...pending.map((p) => '  - $p'),
      '',
      'This indicates rules waiting on each other in a cycle, or '
          'references to values that never resolve.',
    ], pending: pending);
  }
}

// .............................................................................
/// Signals that input binding must wait for another resolution.
class _Blocked {
  _Blocked(this.reason);
  final String reason;
}

// .............................................................................
/// One unresolved location in the working tree.
class _WorkItem {
  _WorkItem({
    required this.node,
    required this.container,
    required this.keyOrIndex,
    required this.value,
    required this.dataPath,
    required this.location,
    required this.chain,
    required this.steps,
  });

  final Tree<Json> node;
  final Object container;
  final Object keyOrIndex;
  final Object value;

  /// The data path inside the node, e.g. `'cfg/sizes[0]'`. Kept
  /// separately — map keys may themselves contain `'#'`.
  final String dataPath;
  final String location;

  /// Rule keys already applied at this location (cycle detection).
  final List<String> chain;

  /// How often this location was re-enqueued.
  final int steps;

  String? blockReason;

  /// Names the item in stuck diagnostics.
  String get describeValue => isReference(value)
      ? 'reference "${(value as Map<dynamic, dynamic>)[referenceKey]}"'
      : 'inline expression';
}

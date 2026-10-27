// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';

import 'annotation.dart';
import 'compiled_expression.dart';
import 'resolution_report.dart';
import 'rule.dart';
import 'rule_book.dart';
import 'rule_ref.dart';
import 'rule_variant.dart';
import 'selector.dart';
import 'tree_expressions_exception.dart';
import 'tree_reader.dart';

/// Resolves all rule references and inline expressions in a tree.
///
/// Items that read unresolved values are retried later. [annotate]
/// applies every rule to every node instead.
class Resolver {
  /// Creates a resolver and compiles all expressions of [ruleBook].
  ///
  /// [expressionCache] shares compiled expressions across resolvers.
  /// [context] is read-only, marker-free data for `context` inputs.
  Resolver({
    required this.ruleBook,
    Map<String, CompiledExpression>? expressionCache,
    Json? context,
  }) : _cache = expressionCache ?? <String, CompiledExpression>{},
       _context = context {
    if (context != null && containsMarker(context)) {
      throw SchemaException([
        'The resolver context contains a marker (a map with a '
            '"$referenceKey"-prefixed key).',
        'The context is plain read-only data and is never resolved.',
      ]);
    }

    for (final key in ruleBook.keys) {
      final rule = ruleBook.ruleForKey(key)!;
      for (var i = 0; i < rule.variants.length; i++) {
        final expression = rule.variants[i].expression;
        if (expression != null) {
          try {
            CompiledExpression.compile(expression, cache: _cache);
          } on TreeExpressionsException catch (e) {
            throw ExpressionException([
              'In rule "$key", variant $i:',
              ...e.messages,
            ], expression: expression);
          }
        }

        final when = rule.variants[i].when;
        if (when != null) {
          try {
            CompiledExpression.compile(when, cache: _cache);
          } on TreeExpressionsException catch (e) {
            throw ExpressionException([
              'In rule "$key", variant $i, "when":',
              ...e.messages,
            ], expression: when);
          }
        }
      }
    }
  }

  /// The merged rule book answering all references.
  final RuleBook ruleBook;

  final Map<String, CompiledExpression> _cache;

  final Json? _context;

  /// Maximum re-enqueues per tree location.
  static const int maxResolutionSteps = 64;

  // ...........................................................................
  /// Resolves all markers in [tree].
  ///
  /// Returns a resolved copy of the root; with [inPlace], mutates [tree],
  /// which may be a subtree. [where] selects the markers to resolve.
  Tree<T> resolve<T extends Json>(
    Tree<T> tree, {
    bool inPlace = false,
    MarkerFilter? where,
  }) => _resolve(tree, inPlace, null, where);

  // ...........................................................................
  /// Resolves [tree] like [resolve] and reports what produced each value.
  ///
  /// [rich] adds selector, `when`, priority, inputs, expression and alias
  /// chain to each entry.
  (Tree<T>, ResolutionReport) resolveVerbose<T extends Json>(
    Tree<T> tree, {
    bool inPlace = false,
    bool rich = false,
    MarkerFilter? where,
  }) {
    final recorder = _Recorder(rich);
    final resolved = _resolve(tree, inPlace, recorder, where);
    return (resolved, ResolutionReport(entries: recorder.entries, rich: rich));
  }

  // ...........................................................................
  /// Resolves the root [tree] in place, leaving it untouched on error.
  ///
  /// Writes back only the data of nodes that changed.
  Tree<T> resolveAtomic<T extends Json>(Tree<T> tree, {MarkerFilter? where}) {
    final resolved = _resolve(tree, false, null, where);
    _adoptData(tree, resolved);
    return tree;
  }

  /// Copies the data of changed nodes from [resolved] onto [original].
  void _adoptData<T extends Json>(Tree<T> original, Tree<T> resolved) {
    if (!deeplEquals(original.data, resolved.data)) {
      original.data
        ..clear()
        ..addAll(resolved.data);
    }
    final originalChildren = original.children.toList();
    final resolvedChildren = resolved.children.toList();
    assert(
      originalChildren.length == resolvedChildren.length,
      'resolution changed the tree structure',
    );
    for (var i = 0; i < originalChildren.length; i++) {
      _adoptData(originalChildren[i], resolvedChildren[i]);
    }
  }

  Tree<T> _resolve<T extends Json>(
    Tree<T> tree,
    bool inPlace,
    _Recorder? recorder,
    MarkerFilter? where,
  ) {
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

    // Unselected markers stay dormant until a selected one waits for them.
    var pending = <_WorkItem>[];
    final dormant = <_WorkItem>[];
    for (final item in _collect(working)) {
      final selected = where == null || where(item.node, item.topKey);
      (selected ? pending : dormant).add(item);
    }

    while (pending.isNotEmpty) {
      var progressed = false;
      final deferred = <_WorkItem>[];
      final discovered = <_WorkItem>[];

      for (final item in pending) {
        if (_step(item, discovered, recorder)) {
          progressed = true;
        } else {
          deferred.add(item);
        }
      }

      final pulled = _pullBlockers(deferred, dormant);
      if (!progressed && pulled.isEmpty) throw _stuck(deferred);
      pending = [...deferred, ...discovered, ...pulled];
    }
    return working;
  }

  /// Removes the [dormant] items at or below a blocker of [deferred]
  /// and returns them.
  List<_WorkItem> _pullBlockers(
    List<_WorkItem> deferred,
    List<_WorkItem> dormant,
  ) {
    final pulled = <_WorkItem>[];
    dormant.removeWhere((candidate) {
      final blocks = deferred.any(
        (item) => _isAtOrBelow(candidate.location, item.blocker),
      );
      if (blocks) pulled.add(candidate);
      return blocks;
    });
    return pulled;
  }

  // ...........................................................................
  /// Evaluates [rule] at [node] without touching the tree.
  ///
  /// Returns null for an optional rule without match; throws when blocked.
  Object? resolveRule(Tree<Json> node, Rule rule) {
    final context = 'rule "${rule.key}" at node "${node.path}"';
    switch (_select(rule, node)) {
      case SelectBlocked(:final query, :final blocker):
        throw ResolveException([
          'Cannot resolve $context:',
          'selector condition "$query" waits for the unresolved '
              'value at "$blocker".',
        ]);
      case final SelectAmbiguous ambiguous:
        throw _ambiguousVariant(rule, node.path, ambiguous);
      case SelectNone(:final reasons):
        if (rule.isOptional) return null;
        throw _noVariantMatched(rule, node.path, reasons);
      case SelectMatch(:final variant, :final index):
        final inputs = _bindResultInputs(variant, node, rule.key, index);
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
  /// Evaluates every rule of [ruleBook] at every node of [tree].
  ///
  /// Returns the annotations by node path. Expects a resolved tree and
  /// never mutates it.
  Map<String, List<Annotation>> annotate<T extends Json>(Tree<T> tree) {
    final result = <String, List<Annotation>>{};
    tree.visit((node) {
      final annotations = annotateNode(node);
      if (annotations.isNotEmpty) result[node.path] = annotations;
    });
    return result;
  }

  // ...........................................................................
  /// Like [annotate], for [node] only.
  List<Annotation> annotateNode(Tree<Json> node) => [
    for (final key in ruleBook.keys)
      ?_annotateRule(ruleBook.ruleForKey(key)!, node),
  ];

  Annotation? _annotateRule(Rule rule, Tree<Json> node) {
    final context = 'rule "${rule.key}" at node "${node.path}"';
    switch (_select(rule, node)) {
      case SelectBlocked(:final query, :final blocker):
        throw _unresolvedTree(
          context,
          'the query "$query" waits for the unresolved value at '
          '"$blocker"',
        );
      case final SelectAmbiguous ambiguous:
        throw _ambiguousVariant(rule, node.path, ambiguous);
      case SelectNone():
        return null;
      case SelectMatch(:final variant, :final index):
        final inputs = _bindResultInputs(variant, node, rule.key, index);
        if (inputs is _Blocked) throw _unresolvedTree(context, inputs.reason);
        return Annotation(
          ruleKey: rule.key,
          variantIndex: index,
          value: _evaluate(
            variant,
            inputs as Map<String, Object?>,
            rule,
            index,
            node.path,
          ),
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
          topKey: key,
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
    required String topKey,
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
          topKey: topKey,
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
          topKey: topKey,
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
          topKey: topKey,
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

  /// Processes [item]; returns false when it must be retried.
  bool _step(_WorkItem item, List<_WorkItem> discovered, _Recorder? recorder) {
    final map = item.value as Map<dynamic, dynamic>;
    if (isReference(map)) {
      return _stepReference(
        item,
        _referencedKey(item, map),
        discovered,
        recorder,
      );
    }
    if (isInlineExpression(map)) {
      return _stepInline(item, discovered, recorder);
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
      '  - reference:         {"$referenceKey": "ruleName"}',
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
            '"borderWidth"}.',
      ]);
    }
    return key;
  }

  bool _stepReference(
    _WorkItem item,
    String key,
    List<_WorkItem> discovered,
    _Recorder? recorder,
  ) {
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

    switch (_select(rule, item.node)) {
      case SelectBlocked(:final query, :final blocker):
        item.block(
          'selector condition "$query" waits for the '
          'unresolved value at "$blocker"',
          blocker,
        );
        return false;
      case final SelectAmbiguous ambiguous:
        throw _ambiguousVariant(rule, item.location, ambiguous);
      case SelectNone(:final reasons):
        if (rule.isOptional) {
          _recordRemoval(recorder, item, key);
          _remove(item);
          return true;
        }
        throw _noVariantMatched(rule, item.location, reasons);
      case SelectMatch(:final variant, :final index):
        final inputs = _bindResultInputs(variant, item.node, key, index);
        if (inputs is _Blocked) {
          item.block(inputs.reason, inputs.blocker);
          return false;
        }
        final bound = inputs as Map<String, Object?>;
        final result = _evaluate(variant, bound, rule, index, item.location);
        final chain = [...item.chain, key];
        _recordRule(recorder, item, key, index, variant, bound, result, chain);
        _writeAndRescan(item, result, chain, discovered);
        return true;
    }
  }

  bool _stepInline(
    _WorkItem item,
    List<_WorkItem> discovered,
    _Recorder? recorder,
  ) {
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
      item.block(inputs.reason, inputs.blocker);
      return false;
    }
    final bound = inputs as Map<String, Object?>;

    final source = variant.expression!;
    final CompiledExpression expression;
    try {
      expression = CompiledExpression.compile(source, cache: _cache);
    } on TreeExpressionsException catch (e) {
      throw ExpressionException([
        'In $context:',
        ...e.messages,
      ], expression: source);
    }

    final Object? result;
    try {
      result = expression.evaluate(bound);
    } on TreeExpressionsException catch (e) {
      throw ExpressionException([
        'In $context:',
        ...e.messages,
      ], expression: source);
    }

    _recordInline(recorder, item, variant, bound, result);
    _writeAndRescan(item, result, item.chain, discovered);
    return true;
  }

  // ...........................................................................
  // Provenance recording

  void _recordRule(
    _Recorder? recorder,
    _WorkItem item,
    String key,
    int index,
    RuleVariant variant,
    Map<String, Object?> inputs,
    Object? result,
    List<String> chain,
  ) {
    if (recorder == null) return;
    recorder.entries.add(
      ProvenanceEntry(
        location: item.location,
        kind: ProvenanceKind.rule,
        ruleKey: key,
        variantIndex: index,
        value: result,
        selector: recorder.rich
            ? Map<String, Object>.of(variant.selector.conditions)
            : null,
        when: recorder.rich ? variant.when : null,
        priority: recorder.rich ? variant.priority : null,
        inputs: recorder.rich ? Map<String, Object?>.of(inputs) : null,
        expression: recorder.rich ? variant.expression : null,
        aliasChain: recorder.rich ? List<String>.unmodifiable(chain) : null,
      ),
    );
  }

  void _recordInline(
    _Recorder? recorder,
    _WorkItem item,
    RuleVariant variant,
    Map<String, Object?> inputs,
    Object? result,
  ) {
    if (recorder == null) return;
    recorder.entries.add(
      ProvenanceEntry(
        location: item.location,
        kind: ProvenanceKind.inline,
        value: result,
        inputs: recorder.rich ? Map<String, Object?>.of(inputs) : null,
        expression: recorder.rich ? variant.expression : null,
        aliasChain: recorder.rich
            ? List<String>.unmodifiable(item.chain)
            : null,
      ),
    );
  }

  void _recordRemoval(_Recorder? recorder, _WorkItem item, String key) {
    if (recorder == null) return;
    recorder.entries.add(
      ProvenanceEntry(
        location: item.location,
        kind: ProvenanceKind.optionalRemoval,
        ruleKey: key,
        aliasChain: recorder.rich
            ? List<String>.unmodifiable([...item.chain, key])
            : null,
      ),
    );
  }

  // ...........................................................................
  // Input binding & evaluation

  /// Binds [variant]'s inputs at [node], or returns a [_Blocked].
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
        result = input.isContext
            ? readContext(_context, input.context!)
            : readQuery(node, input.query!);
      } on QueryException catch (e) {
        throw QueryException(
          ['While binding ${describe(name)}:', ...e.messages],
          query: e.query,
          nodePath: e.nodePath,
        );
      }

      switch (result) {
        // Only tree reads block.
        case ReadBlocked(:final blocker):
          return _Blocked(
            '${describe(name)} ("${input.query}") waits for the '
            'unresolved value at "$blocker"',
            query: input.query!,
            blocker: blocker,
          );
        case ReadMissing():
          if (!input.hasDefault) {
            final source = input.isContext
                ? 'the context path "${input.context}"'
                : 'the query "${input.query}"';
            throw MissingInputException(
              [
                'Missing ${describe(name)} at node "${node.path}":',
                '$source resolved to nothing and no default is declared.',
                if (input.isContext && _context == null)
                  'The resolver was created without a context.',
              ],
              inputName: name,
              query: input.query ?? input.context!,
            );
          }
          bound[name] = _copied(input.defaultValue);
        case ReadValue(:final value):
          bound[name] = input.isContext ? _copied(value) : value;
      }
    }
    return bound;
  }

  /// Binds [variant]'s inputs unless it is a value variant.
  Object _bindResultInputs(
    RuleVariant variant,
    Tree<Json> node,
    String ruleKey,
    int variantIndex,
  ) => variant.hasValue
      ? <String, Object?>{}
      : _bindInputs(variant, node, ruleKey, variantIndex);

  Object? _evaluate(
    RuleVariant variant,
    Map<String, Object?> inputs,
    Rule rule,
    int variantIndex,
    String location,
  ) {
    final Object? result;
    if (variant.hasValue) {
      result = _copied(variant.value);
    } else {
      try {
        result = CompiledExpression.compile(
          variant.expression!,
          cache: _cache,
        ).evaluate(inputs);
      } on TreeExpressionsException catch (e) {
        throw ExpressionException([
          'While resolving rule "${rule.key}" (variant $variantIndex) '
              'at "$location":',
          ...e.messages,
        ], expression: variant.expression!);
      }
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

  SelectResult _select(Rule rule, Tree<Json> node) => rule.select(
    node,
    evaluateWhen: (variant, atNode, index) =>
        _evaluateWhen(rule, index, variant, atNode),
  );

  /// Evaluates [variant]'s `when` predicate at [node].
  ///
  /// Returns [MatchBlocked] for a blocked input; throws an
  /// [ExpressionException] for a non-bool result.
  MatchResult _evaluateWhen(
    Rule rule,
    int index,
    RuleVariant variant,
    Tree<Json> node,
  ) {
    final bound = _bindInputs(variant, node, rule.key, index);
    if (bound is _Blocked) return MatchBlocked(bound.query, bound.blocker);

    final context =
        'the "when" of rule "${rule.key}" (variant $index) at '
        '"${node.path}"';
    final Object? result;
    try {
      result = CompiledExpression.compile(
        variant.when!,
        cache: _cache,
      ).evaluate(bound as Map<String, Object?>);
    } on TreeExpressionsException catch (e) {
      throw ExpressionException([
        'While evaluating $context:',
        ...e.messages,
      ], expression: variant.when!);
    }

    if (result is! bool) {
      throw ExpressionException([
        '$context returned $result (${result.runtimeType}) but a "when" '
            'predicate must evaluate to a bool.',
      ], expression: variant.when!);
    }

    return result
        ? const MatchSuccess()
        : MatchFailure.reason('"when" predicate "${variant.when}" is false');
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

  /// Writes [result] and enqueues the markers it contains.
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
      topKey: item.topKey,
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

  AmbiguousVariantException _ambiguousVariant(
    Rule rule,
    String location,
    SelectAmbiguous ambiguous,
  ) {
    final SelectAmbiguous(:specificity, :priority, :matches) = ambiguous;
    final priorityPart = priority == 0 ? '' : ' and priority ($priority)';
    return AmbiguousVariantException(
      [
        '${matches.length} variants of rule "${rule.key}" match at '
            '"$location" with the same specificity ($specificity)'
            '$priorityPart — the winner is ambiguous:',
        ...matches.map((m) {
          final when = m.variant.when;
          final whenPart = when == null ? '' : ', when "$when"';
          return '  - variant ${m.index}: selector '
              '${m.variant.selector.toJson()}$whenPart';
        }),
        'Make the selectors (or `when` predicates) specific enough that '
            'exactly one variant applies.',
      ],
      ruleKey: rule.key,
      location: location,
      specificity: specificity,
      priority: priority,
      variantIndices: [for (final m in matches) m.index],
    );
  }

  ResolveException _unresolvedTree(String context, String blocker) =>
      ResolveException([
        'Cannot annotate $context:',
        '$blocker.',
        'annotate() expects a resolved tree — call resolve() first.',
      ]);

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
/// Returns true to resolve a marker at [node] under top-level data [key].
typedef MarkerFilter = bool Function(Tree<Json> node, String key);

// .............................................................................
/// True when [location] is [blocker] or lies below it.
///
/// Both have the form `'<nodePath>#<dataPath>'`.
bool _isAtOrBelow(String location, String blocker) =>
    location.startsWith(blocker) &&
    (location.length == blocker.length ||
        blocker.endsWith('#') ||
        '/['.contains(location[blocker.length]));

// .............................................................................
/// Input binding that waits for an unresolved value.
class _Blocked {
  _Blocked(this.reason, {this.query = '', this.blocker = ''});
  final String reason;

  /// The blocked input's query and the location it waits for.
  final String query;
  final String blocker;
}

// .............................................................................
/// Collects provenance entries during a verbose resolve.
class _Recorder {
  _Recorder(this.rich);

  /// Whether to capture the rich fields.
  final bool rich;

  /// The entries in resolution order.
  final List<ProvenanceEntry> entries = [];
}

// .............................................................................
/// One unresolved location in the working tree.
class _WorkItem {
  _WorkItem({
    required this.node,
    required this.container,
    required this.keyOrIndex,
    required this.value,
    required this.topKey,
    required this.dataPath,
    required this.location,
    required this.chain,
    required this.steps,
  });

  final Tree<Json> node;
  final Object container;
  final Object keyOrIndex;
  final Object value;

  /// The top-level data key holding the marker, e.g. `'cfg'`.
  final String topKey;

  /// The data path inside the node, e.g. `'cfg/sizes[0]'`.
  final String dataPath;
  final String location;

  /// Rule keys already applied at this location.
  final List<String> chain;

  /// How often this location was re-enqueued.
  final int steps;

  String? blockReason;

  /// The location of the value this item last waited for.
  String blocker = '';

  /// Records why and on which location the item was deferred.
  void block(String reason, String blocker) {
    blockReason = reason;
    this.blocker = blocker;
  }

  /// Names the item in stuck diagnostics.
  String get describeValue => isReference(value)
      ? 'reference "${(value as Map<dynamic, dynamic>)[referenceKey]}"'
      : 'inline expression';
}

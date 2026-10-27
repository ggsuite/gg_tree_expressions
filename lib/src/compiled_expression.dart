// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Uses cel engine internals.
// ignore_for_file: implementation_imports

import 'package:antlr4/antlr4.dart' hide Parser;
import 'package:cel/cel.dart';
import 'package:cel/gen/CELLexer.dart';
import 'package:cel/gen/CELParser.dart';
import 'package:cel/src/cel/expr.dart';
import 'package:cel/src/common/types/list.dart';
import 'package:cel/src/common/types/provider.dart';
import 'package:cel/src/common/types/ref/provider.dart';
import 'package:cel/src/common/types/ref/value.dart';
import 'package:cel/src/parser/parser.dart' as cel_parser;

import 'tree_expressions_exception.dart';
import 'tree_reader.dart';

/// A CEL expression compiled once and evaluated with many input bindings.
///
/// Parses without stderr output, rejects syntax errors and unknown
/// functions at [compile] and evaluates with JSON-safe values.
class CompiledExpression {
  CompiledExpression._(this.source, this._program, this._chains);

  /// Compiles [source], reusing [cache] when given.
  ///
  /// Throws a [TreeExpressionsException] on syntax errors, unknown
  /// functions, unary minus on non-literals, field access on a computed
  /// value and bytes literals.
  factory CompiledExpression.compile(
    String source, {
    Map<String, CompiledExpression>? cache,
  }) {
    final cached = cache?[source];
    if (cached != null) return cached;

    final Ast ast;
    try {
      ast = Ast(_parse(source));
    } on TreeExpressionsException {
      rethrow;
    } catch (e) {
      throw ExpressionException([
        'Cannot parse expression "$source":',
        messageOf(e),
      ], expression: source);
    }

    if (_containsParseError(ast.expression)) {
      throw ExpressionException([
        'Syntax error in expression "$source".',
        'Note: unary minus on non-literals (e.g. "-x") and the '
            'literal string "<<error>>" are also reported this way.',
      ], expression: source);
    }

    final unknownFunction = _findUnknownFunction(ast.expression);
    if (unknownFunction != null) {
      throw ExpressionException([
        'Unknown function "$unknownFunction" in expression "$source".',
        'Available functions: ${_knownFunctions.join(', ')}.',
        'There is no min/max/size, no type conversions, and no '
            'macros — use the ternary (a < b ? a : b) or pre-compute '
            'via inputs.',
      ], expression: source);
    }

    final Program program;
    try {
      program = _environment.makeProgram(ast);
    } catch (e) {
      throw ExpressionException([
        'Unsupported expression "$source":',
        messageOf(e),
        if (_readsFieldOfComputedValue(ast.expression))
          'Note: field access on a computed value is not supported — '
              'use ["key"], e.g. m[0]["key"] instead of m[0].key.',
      ], expression: source);
    }

    final result = CompiledExpression._(
      source,
      program,
      _memberChains(ast.expression),
    );
    cache?[source] = result;
    return result;
  }

  /// The expression source.
  final String source;

  final Program _program;

  /// The member reads of inputs, e.g. `['m', 'a', 'b']` for `m.a.b`.
  final List<List<String>> _chains;

  static final Environment _environment = _JsonEnvironment();

  // ...........................................................................
  /// Evaluates the expression with [inputs] bound as CEL variables.
  Object? evaluate(Map<String, Object?> inputs) {
    final Object? raw;
    try {
      raw = _program.evaluate(Map<String, dynamic>.of(inputs));
    } catch (e) {
      throw ExpressionException([
        'Evaluation of expression "$source" failed:',
        ..._conciseEngineError(e, inputs),
      ], expression: source);
    }

    return _toJsonResult(raw);
  }

  // ...........................................................................
  /// Converts an engine result to JSON-compatible Dart values.
  Object? _toJsonResult(Object? raw) {
    if (raw is Map) {
      final json = <String, dynamic>{};
      for (final MapEntry(:key, :value) in raw.entries) {
        if (key is! String) {
          throw ExpressionException([
            'Expression "$source" returned a map with the non-string '
                'key $key (${key.runtimeType}).',
            'Results are written into tree data — map keys must be '
                'strings.',
          ], expression: source);
        }
        json[key] = _toJsonResult(value);
      }
      return json;
    }
    if (raw is List) {
      return [for (final e in raw) _toJsonResult(e)];
    }
    return raw;
  }

  // ...........................................................................
  /// Explains an engine error, naming the inputs involved.
  List<String> _conciseEngineError(Object error, Map<String, Object?> inputs) {
    final text = error.toString();
    final unknown = _unknownVariable(text, inputs);
    if (unknown != null) return [unknown];
    return [?_failedMemberRead(text, inputs), messageOf(error)];
  }

  // ...........................................................................
  /// The message for an unknown variable, or null for other errors.
  static String? _unknownVariable(String error, Map<String, Object?> inputs) {
    final match = _unknownVariablePattern.firstMatch(error);
    if (match == null) return null;
    final available = inputs.keys.isEmpty
        ? '(none)'
        : inputs.keys.map((k) => '"$k"').join(', ');
    return 'Unknown variable "${match.group(1)}". Declare it in the '
        '"inputs" of the variant. Available inputs: $available.';
  }

  static final _unknownVariablePattern = RegExp(
    r'Could not find MaybeAttribute\(\[AbsoluteAttribute\((\.?\w+)',
  );

  // ...........................................................................
  /// The message naming the inputs whose `.field` read failed, or null.
  String? _failedMemberRead(String error, Map<String, Object?> inputs) {
    final match = _memberReadPattern.firstMatch(error);
    if (match == null) return null;
    final key =
        match.group(1) ?? match.group(2) ?? match.group(3) ?? match.group(4);
    final names = {
      for (final chain in _chains)
        if (_firstBrokenKey(chain, inputs) == key) '"${chain.first}"',
    };
    return names.isEmpty
        ? null
        : 'Failed to read a member of input ${names.join(' or ')} — '
              'a key is missing, or a value on the path is null or not a '
              'map.';
  }

  /// Matches the key in the engine's errors for a failed `.field` read.
  static final _memberReadPattern = RegExp(
    r'no_such_field: the map has no key (\w+)\.'
    r'|Trying to read value of key (\w+) on null'
    r'|Tried calling: \[\]\("(\w+)"\)'
    r'|method not found: \x27\[\]\x27[\s\S]*?Arguments: \["(\w+)"\]',
  );

  // ...........................................................................
  /// The key at which [chain] first fails to read from [inputs], or null.
  static String? _firstBrokenKey(
    List<String> chain,
    Map<String, Object?> inputs,
  ) {
    if (!inputs.containsKey(chain.first)) return null;
    Object? value = inputs[chain.first];
    for (final key in chain.skip(1)) {
      if (value is! Map || !value.containsKey(key)) return key;
      value = value[key];
    }
    return null;
  }

  // ...........................................................................
  /// Parses [source] without stderr output; throws on syntax errors.
  static Expr _parse(String source) {
    final collector = _SyntaxErrorCollector();

    final lexer = CELLexer(InputStream.fromString(source));
    lexer.removeErrorListeners();
    lexer.addErrorListener(collector);

    final parser = CELParser(CommonTokenStream(lexer));
    parser.removeErrorListeners();
    parser.addErrorListener(collector);
    parser.buildParseTree = true;

    final tree = parser.start();
    if (collector.errors.isNotEmpty) {
      throw ExpressionException([
        'Syntax error in expression "$source":',
        ...collector.errors.map((e) => '  - $e'),
      ], expression: source);
    }
    return cel_parser.visit(tree);
  }

  // ...........................................................................
  /// Detects the `'<<error>>'` literals the parser emits for syntax errors.
  static bool _containsParseError(Expr expr) => switch (expr) {
    StringLiteralExpr(:final value) => value == '<<error>>',
    CallExpr(:final target, :final args) =>
      (target != null && _containsParseError(target)) ||
          args.any(_containsParseError),
    SelectExpr(:final operand) => _containsParseError(operand),
    ListExpr(:final elements) => elements.any(_containsParseError),
    MapExpr(:final entries) => entries.any(
      (e) => _containsParseError(e.key) || _containsParseError(e.value),
    ),
    _ => false,
  };

  /// The engine's callable non-operator functions.
  static const _knownFunctions = [
    'contains', 'startsWith', 'endsWith', //
    'matches',
  ];

  static final RegExp _identifierName = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');

  // ...........................................................................
  /// Returns a called function the engine does not know, or null.
  static String? _findUnknownFunction(Expr expr) => switch (expr) {
    CallExpr(:final function, :final target, :final args) =>
      _identifierName.hasMatch(function) && !_knownFunctions.contains(function)
          ? function
          : (target != null ? _findUnknownFunction(target) : null) ??
                args
                    .map(_findUnknownFunction)
                    .firstWhere((f) => f != null, orElse: () => null),
    SelectExpr(:final operand) => _findUnknownFunction(operand),
    ListExpr(:final elements) =>
      elements
          .map(_findUnknownFunction)
          .firstWhere((f) => f != null, orElse: () => null),
    MapExpr(:final entries) =>
      entries
          .map(
            (e) => _findUnknownFunction(e.key) ?? _findUnknownFunction(e.value),
          )
          .firstWhere((f) => f != null, orElse: () => null),
    _ => null,
  };

  // ...........................................................................
  /// The identifier member chains of [expr]: `m.a.b` gives `['m', 'a', 'b']`.
  static List<List<String>> _memberChains(Expr expr) {
    final fields = <String>[];
    var operand = expr;
    while (operand is SelectExpr) {
      fields.insert(0, operand.field);
      operand = operand.operand;
    }
    if (fields.isNotEmpty && operand is IdentExpr) {
      return [
        [operand.name, ...fields],
      ];
    }
    return [for (final child in _children(operand)) ..._memberChains(child)];
  }

  // ...........................................................................
  /// True when a field is read from a computed value, e.g. `m[0].key`.
  static bool _readsFieldOfComputedValue(Expr expr) => switch (expr) {
    SelectExpr(:final operand)
        when operand is! SelectExpr && operand is! IdentExpr =>
      true,
    _ => _children(expr).any(_readsFieldOfComputedValue),
  };

  // ...........................................................................
  /// The direct subexpressions of [expr].
  static List<Expr> _children(Expr expr) => switch (expr) {
    CallExpr(:final target, :final args) => [?target, ...args],
    SelectExpr(:final operand) => [operand],
    ListExpr(:final elements) => elements,
    MapExpr(:final entries) => [
      for (final e in entries) ...[e.key, e.value],
    ],
    _ => const [],
  };
}

// .............................................................................
/// An environment whose programs use [_JsonTypeAdapter].
class _JsonEnvironment extends Environment {
  _JsonEnvironment() : super.standard();

  @override
  TypeAdapter get adapter => _jsonAdapter;

  static final TypeAdapter _jsonAdapter = _JsonTypeAdapter();
}

// .............................................................................
/// A type adapter accepting all JSON and passing wrapped values through.
class _JsonTypeAdapter extends TypeRegistry {
  @override
  Value nativeToValue(dynamic value) {
    if (value is Value) return value;
    if (value is List) {
      return ListValue([for (final e in value) nativeToValue(e)], this);
    }
    return super.nativeToValue(value);
  }
}

// .............................................................................
/// Collects syntax errors instead of printing them to stderr.
class _SyntaxErrorCollector extends BaseErrorListener {
  /// The collected errors, one line each.
  final List<String> errors = [];

  @override
  void syntaxError(
    Recognizer<ATNSimulator> recognizer,
    Object? offendingSymbol,
    int? line,
    int charPositionInLine,
    String msg,
    RecognitionException? e,
  ) {
    errors.add('line $line:$charPositionInLine $msg');
  }
}

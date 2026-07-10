// @license
// Copyright (c) 2026 ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// CompiledExpression is the declared mitigation boundary around the
// cel engine; it needs engine internals to detect silently swallowed
// syntax errors and to replace the engine's JSON-hostile type
// adapter.
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

/// A CEL expression compiled once and evaluated many times with
/// different input bindings.
///
/// The mitigation boundary around the `cel` engine's quirks:
/// - It swallows syntax errors (into an `'<<error>>'` literal) and
///   prints ANTLR diagnostics to stderr on every parse, deadlocking
///   runners that do not drain stderr (the gg tool). [compile] parses
///   listener-free, reports syntax errors with line and column, and
///   rejects `'<<error>>'` literals (also emitted for unary minus on
///   non-literals) — so that literal cannot appear in a source.
/// - Unknown functions and macros are rejected at [compile].
/// - Its type adapter rejects most list shapes and cannot pass its own
///   wrapped values through, so programs run with [_JsonTypeAdapter],
///   which accepts arbitrary JSON.
/// - Unknown-identifier errors embed the whole activation map;
///   [evaluate] replaces them with a concise message.
class CompiledExpression {
  CompiledExpression._(this.source, this._program);

  /// Compiles [source], reusing [cache] when given (keyed by source).
  ///
  /// Throws a [TreeExpressionsException] on syntax errors, on calls
  /// to functions the engine does not have (`size()`, `min`/`max`,
  /// macros like `has`/`all`/`exists`/`map`/`filter`, type
  /// conversions), on unary minus applied to non-literals, and on
  /// field access after an index (`m[0].key`).
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
        'Note: field access after an index is not supported — '
            'write m[0]["key"] instead of m[0].key.',
      ], expression: source);
    }

    final result = CompiledExpression._(source, program);
    cache?[source] = result;
    return result;
  }

  /// The expression source.
  final String source;

  final Program _program;

  static final Environment _environment = _JsonEnvironment();

  // ...........................................................................
  /// Evaluates the expression with [inputs] bound as CEL variables.
  ///
  /// Returns a JSON-compatible Dart value (num, String, bool, List,
  /// Map with string keys, or null).
  Object? evaluate(Map<String, Object?> inputs) {
    final Object? raw;
    try {
      raw = _program.evaluate(Map<String, dynamic>.of(inputs));
    } catch (e) {
      throw ExpressionException([
        'Evaluation of expression "$source" failed:',
        _conciseEngineError(e, inputs),
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
  /// Shortens the engine's attribute errors, which embed the entire
  /// activation map. The engine uses the same error for missing
  /// variables and for failed member access on existing ones — the
  /// input names tell the two apart.
  String _conciseEngineError(Object error, Map<String, Object?> inputs) {
    final text = error.toString();
    final match = RegExp(
      r'Could not find MaybeAttribute\(\[AbsoluteAttribute\((\.?\w+)',
    ).firstMatch(text);
    if (match == null) return messageOf(error);

    final name = match.group(1)!;
    if (inputs.containsKey(name)) {
      return 'Failed to read a member of input "$name" — a path '
          'segment is null or not a map/list.';
    }
    final available = inputs.keys.isEmpty
        ? '(none)'
        : inputs.keys.map((k) => '"$k"').join(', ');
    return 'Unknown variable "$name". Declare it in the "inputs" '
        'of the variant. Available inputs: $available.';
  }

  // ...........................................................................
  /// Parses [source] like the engine does, but without its error
  /// listeners: no stderr output, and syntax errors are collected
  /// and thrown with line and column instead of being swallowed.
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
  /// Detects the `'<<error>>'` literals the parser produces instead
  /// of throwing on syntax errors.
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

  /// The engine's only callable (non-operator) functions.
  static const _knownFunctions = [
    'contains', 'startsWith', 'endsWith', //
    'matches',
  ];

  static final RegExp _identifierName = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');

  // ...........................................................................
  /// Finds calls to functions the engine does not know. Those would
  /// otherwise fail at evaluation with a raw cast error (binary
  /// calls) instead of a clear compile error. Operator functions
  /// have non-identifier names like `_+_` and pass through.
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
}

// .............................................................................
/// An environment whose programs use [_JsonTypeAdapter].
///
/// `Environment.standard()` hard-wires the engine's own registry;
/// overriding the adapter getter routes every conversion the
/// interpreter performs through the JSON-safe adapter instead.
class _JsonEnvironment extends Environment {
  _JsonEnvironment() : super.standard();

  @override
  TypeAdapter get adapter => _jsonAdapter;

  static final TypeAdapter _jsonAdapter = _JsonTypeAdapter();
}

// .............................................................................
/// A type adapter whose conversions survive JSON data.
///
/// The engine's own adapter rejects lists other than `List<String>` /
/// `List<Value>` and does not pass its own `ListValue`/`NullValue`
/// through — binding lists, indexing into bound maps, and ternary
/// list/null branches would all throw. This adapter accepts every
/// JSON shape and passes wrapped values through.
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

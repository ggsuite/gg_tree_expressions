// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';

import 'rule_ref.dart';
import 'tree_expressions_exception.dart';

// .............................................................................
/// The outcome of a marker-aware query read.
sealed class ReadResult {
  const ReadResult();
}

/// The query resolved to a value free of unresolved markers.
class ReadValue extends ReadResult {
  /// Creates the result carrying the resolved [value].
  const ReadValue(this.value);

  /// The value the query resolved to. Never null.
  final Object value;
}

/// The query resolved to nothing.
class ReadMissing extends ReadResult {
  /// Creates the result.
  const ReadMissing();
}

/// The query touches an unresolved value and must be retried.
class ReadBlocked extends ReadResult {
  /// Creates the result naming the [blocker] location.
  const ReadBlocked(this.blocker);

  /// The location of the unresolved value, e.g. `'/dialog#width'`.
  final String blocker;
}

// .............................................................................
/// Validates that [query] is parseable; throws with [context] if not.
void validateQuery(String query, {required String context}) {
  try {
    TreeQuery(query);
  } catch (e) {
    throw SchemaException([
      'Invalid query "$query" in $context:',
      messageOf(e),
    ]);
  }
}

/// Validates the context data [path]; throws with [context] if invalid.
void validateContextPath(String path, {required String context}) {
  final segments = parseJsonPath(path);
  if (segments.isEmpty) {
    throw SchemaException([
      'Invalid context path "$path" in $context:',
      'the path is empty.',
    ]);
  }
  for (final segment in segments) {
    try {
      parseArrayIndex(segment);
    } catch (e) {
      throw SchemaException([
        'Invalid context path "$path" in $context:',
        messageOf(e),
      ]);
    }
  }
}

/// Returns the message of [error] without the `'Exception: '` prefix.
String messageOf(Object error) {
  final text = error.toString();
  const prefix = 'Exception: ';
  return text.startsWith(prefix) ? text.substring(prefix.length) : text;
}

// .............................................................................
/// A parsed [query] with its data path [segments].
class _ParsedQuery {
  _ParsedQuery(this.query, this.segments);
  final TreeQuery query;
  final List<String> segments;
}

final Map<String, _ParsedQuery> _parseCache = <String, _ParsedQuery>{};

/// Parses [query], cached by query string.
_ParsedQuery _parse(String query) {
  final cached = _parseCache[query];
  if (cached != null) return cached;

  final parsed = TreeQuery(query);
  final result = _ParsedQuery(parsed, parseJsonPath(parsed.data));
  if (_parseCache.length >= 512) _parseCache.clear();
  _parseCache[query] = result;
  return result;
}

// .............................................................................
/// Reads [query] relative to [node] like `Tree.getOrNull`.
///
/// Returns [ReadBlocked] when the read touches or searches past a marker.
ReadResult readQuery(Tree<Json> node, String query) {
  final _ParsedQuery pq;
  try {
    pq = _parse(query);
  } catch (e) {
    throw QueryException(
      ['Invalid query "$query" at node "${node.path}":', messageOf(e)],
      query: query,
      nodePath: node.path,
    );
  }
  final parsed = pq.query;

  if (parsed.data.startsWith('${Tree.nodeInfoKey}/')) {
    return _realRead(node, query);
  }

  return _scanRead(node, parsed, pq.segments) ?? _realRead(node, query);
}

// .............................................................................
/// Reads the data [path] from the caller [context].
///
/// Anything that cannot be read is [ReadMissing].
ReadResult readContext(Json? context, String path) {
  if (context == null) return const ReadMissing();
  final Object? value;
  try {
    value = context.getOrNull<dynamic>(path);
  } on Exception {
    return const ReadMissing();
  }
  return value == null ? const ReadMissing() : ReadValue(value);
}

// .............................................................................
/// Reads [query] with `Tree.getOrNull`; throws a [QueryException].
ReadResult _realRead(Tree<Json> node, String query) {
  final Object? value;
  try {
    value = node.getOrNull<dynamic>(query);
  } catch (e) {
    throw QueryException(
      ['Query "$query" failed at node "${node.path}":', messageOf(e)],
      query: query,
      nodePath: node.path,
    );
  }

  if (value == null) return const ReadMissing();

  // Defensive; never reached.
  if (containsMarker(value)) {
    // coverage:ignore-start
    return ReadBlocked('${node.path}#<result of "$query">');
    // coverage:ignore-end
  }
  return ReadValue(value);
}

// .............................................................................
/// Reads like `Tree.getOrNull`, detecting markers.
///
/// Returns null for a shape anomaly.
ReadResult? _scanRead(
  Tree<Json> node,
  TreeQuery parsed,
  List<String> segments,
) {
  final Iterable<Tree<Json>> searchNodes = parsed.searchToRoot
      ? node.ancestors(includeSelf: true)
      : <Tree<Json>>[node];

  for (final searchNode in searchNodes) {
    final target = searchNode.childByPathOrNull(parsed.node);
    if (target == null) continue;

    final (verdict, prefix, value) = _scanData(target, segments);
    switch (verdict) {
      case _Verdict.blocked:
        return ReadBlocked('${target.path}#$prefix');
      case _Verdict.clean:
        return ReadValue(value as Object);
      case _Verdict.aborted:
        return null;
      case _Verdict.missing:
        continue;
    }
  }
  return const ReadMissing();
}

// .............................................................................
enum _Verdict { clean, missing, blocked, aborted }

/// Walks [target]'s data along [segments], detecting markers.
(_Verdict, String, Object?) _scanData(
  Tree<Json> target,
  List<String> segments,
) {
  Object? cur = target.data;
  final walked = <String>[];
  var isRoot = true;

  for (final segment in segments) {
    if (cur == null) return (_Verdict.missing, '', null);
    if (!isRoot && isMarker(cur)) {
      return (_Verdict.blocked, walked.join('/'), null);
    }
    if (cur is! Map) return (_Verdict.aborted, '', null);
    isRoot = false;

    final String key;
    final Iterable<int> indices;
    try {
      (key, indices) = parseArrayIndex(segment);
    } catch (_) {
      return (_Verdict.aborted, '', null);
    }

    cur = cur[key];
    walked.add(key);

    for (final index in indices) {
      if (cur == null) break;
      // The marker sits before this index.
      if (isMarker(cur)) {
        return (_Verdict.blocked, walked.join('/'), null);
      }
      if (cur is! List) return (_Verdict.aborted, '', null);
      cur = index < cur.length ? cur[index] : null;
      walked.last = '${walked.last}[$index]';
    }
  }

  final prefix = walked.join('/');
  if (cur == null) return (_Verdict.missing, '', null);
  if (containsMarker(cur)) return (_Verdict.blocked, prefix, null);
  return (_Verdict.clean, prefix, cur);
}

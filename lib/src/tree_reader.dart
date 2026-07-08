// @license
// Copyright (c) 2026 ggsuite
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

/// The query touches a still-unresolved value and must be retried
/// after further resolution.
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

/// Returns the message of [error] without the `'Exception: '` prefix.
String messageOf(Object error) {
  final text = error.toString();
  const prefix = 'Exception: ';
  return text.startsWith(prefix) ? text.substring(prefix.length) : text;
}

// .............................................................................
/// Reads [query] relative to [node], detecting unresolved markers.
///
/// Mirrors `Tree.getOrNull` semantics but returns [ReadBlocked] when
/// the resolution would read — or silently search past — a reference
/// string, escaped literal, or inline expression map. Shape errors
/// (e.g. a data path traversing a non-map value) throw a
/// [TreeExpressionsException] naming query and node.
ReadResult readQuery(Tree<Json> node, String query) {
  final TreeQuery parsed;
  try {
    parsed = TreeQuery(query);
  } catch (e) {
    throw QueryException(
      ['Invalid query "$query" at node "${node.path}":', messageOf(e)],
      query: query,
      nodePath: node.path,
    );
  }

  // The '#node/...' namespace reads computed tree properties which
  // can never hold markers.
  if (!parsed.data.startsWith('${Tree.nodeInfoKey}/')) {
    final blocked = _scanForMarkers(node, parsed);
    if (blocked != null) return blocked;
  }

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

  // Safety net: the scan above mirrors getOrNull's search, so a
  // marker in the value should be impossible here. Kept as a guard
  // against future gg_tree semantic changes.
  if (containsMarker(value)) {
    // coverage:ignore-start
    return ReadBlocked('${node.path}#<result of "$query">');
    // coverage:ignore-end
  }
  return ReadValue(value);
}

// .............................................................................
/// Walks the same search chain as `Tree.getOrNull` and reports the
/// first marker the query would read or search past.
ReadBlocked? _scanForMarkers(Tree<Json> node, TreeQuery parsed) {
  final Iterable<Tree<Json>> searchNodes = parsed.searchToRoot
      ? node.ancestors(includeSelf: true)
      : <Tree<Json>>[node];

  final segments = parseJsonPath(parsed.data);

  for (final searchNode in searchNodes) {
    final target = searchNode.childByPathOrNull(parsed.node);
    if (target == null) continue;

    final (verdict, prefix) = _scanData(target, segments);
    switch (verdict) {
      case _Verdict.blocked:
        return ReadBlocked('${target.path}#$prefix');
      case _Verdict.clean:
        // The real read stops at this node; markers above are
        // shadowed.
        return null;
      case _Verdict.aborted:
        // Shape anomaly — the real read will throw here.
        return null;
      case _Verdict.missing:
        continue;
    }
  }
  return null;
}

// .............................................................................
enum _Verdict { clean, missing, blocked, aborted }

/// Walks [target]'s data along [segments]; reports markers on the
/// path or in the final value. The root data map itself is never a
/// marker.
(_Verdict, String) _scanData(Tree<Json> target, List<String> segments) {
  Object? cur = target.data;
  final walked = <String>[];
  var isRoot = true;

  for (final segment in segments) {
    if (cur == null) return (_Verdict.missing, '');
    if (!isRoot && isMarker(cur)) {
      return (_Verdict.blocked, walked.join('/'));
    }
    if (cur is! Map) return (_Verdict.aborted, '');
    isRoot = false;

    final String key;
    final Iterable<int> indices;
    try {
      (key, indices) = parseArrayIndex(segment);
    } catch (_) {
      return (_Verdict.aborted, '');
    }

    cur = cur[key];
    walked.add(key);

    for (final index in indices) {
      if (cur == null) break;
      // The marker sits at the path walked so far — before this
      // index is applied.
      if (isMarker(cur)) {
        return (_Verdict.blocked, walked.join('/'));
      }
      if (cur is! List) return (_Verdict.aborted, '');
      cur = index < cur.length ? cur[index] : null;
      walked.last = '${walked.last}[$index]';
    }
  }

  final prefix = walked.join('/');
  if (cur == null) return (_Verdict.missing, '');
  if (containsMarker(cur)) return (_Verdict.blocked, prefix);
  return (_Verdict.clean, prefix);
}

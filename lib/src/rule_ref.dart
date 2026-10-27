// @license
// Copyright (c) ggsuite
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// The pattern a rule key must match.
final RegExp ruleKeyPattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*$');

/// The key marking a map in tree data as a rule reference.
const String referenceKey = '§';

/// The key marking a map in tree data as an inline expression.
const String inlineExpressionKey = '§expression';

/// The key holding the inputs of an inline expression map.
const String inlineInputsKey = '§inputs';

/// Returns true when [key] is a valid rule key like `'borderWidth'`.
bool isRuleKey(String key) => ruleKeyPattern.hasMatch(key);

/// Returns true when [value] is a reference like `{"§": "name"}`.
bool isReference(Object? value) =>
    value is Map && value.containsKey(referenceKey);

/// Returns true when [value] is an inline expression map like
/// `{"§expression": "1 + 2"}`.
bool isInlineExpression(Object? value) =>
    value is Map && value.containsKey(inlineExpressionKey);

/// Returns true when [value] is a map with a key starting with `§`.
bool isMarker(Object? value) =>
    value is Map && value.keys.any((k) => k is String && k.startsWith('§'));

/// Returns true when [value] is or deep-contains a marker.
bool containsMarker(Object? value) {
  if (isMarker(value)) return true;
  if (value is Map) {
    return value.values.any(containsMarker);
  }
  if (value is List) {
    return value.any(containsMarker);
  }
  return false;
}

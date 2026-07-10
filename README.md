# gg_tree_expressions

Values in a [gg_tree](https://pub.dev/packages/gg_tree) tree can say
"ask rule X" — and one `resolve()` call answers every such question in
place. Rules are plain JSON data with per-context overrides; their
expressions are [CEL](https://cel.dev) and evaluate in the context of
the node holding the reference.

The package is generic: it knows nothing about any domain and depends
only on `gg_tree`, `gg_json`, and `cel`.

## Quick start

```dart
import 'package:gg_json/gg_json.dart';
import 'package:gg_tree/gg_tree.dart';
import 'package:gg_tree_expressions/gg_tree_expressions.dart';

void main() {
  final ruleBook = RuleBook.fromJson({
    '§borderWidth': [
      // Base definition: applies everywhere.
      {'expression': '1.0'},
      // Override for one context.
      {
        'selector': {'theme#id': 'dark'},
        'expression': '2.0',
      },
      // Override with inputs read from the tree.
      {
        'selector': {'theme#id': 'dark', '#platform': 'mobile'},
        'inputs': {'screenWidth': 'screen#width'},
        'expression': 'screenWidth < 400.0 ? 3.0 : 2.0',
      },
    ],
  });

  final app = Tree<Json>(
    key: 'app',
    data: {'platform': 'mobile'},
    children: [
      Tree<Json>(key: 'theme', data: {'id': 'dark'}),
      Tree<Json>(key: 'screen', data: {'width': 380.0}),
      Tree<Json>(
        key: 'dialog',
        data: {
          'borderWidth': {'§': '§borderWidth'},
        },
      ),
    ],
  );

  final resolved = Resolver(ruleBook: ruleBook).resolve(app);
  print(resolved.childByPath('dialog').get<double>('./#borderWidth'));
  // 3.0 — and every node below dialog inherits it via getOrNull.
}
```

## Concepts

| Term | Meaning |
|---|---|
| Reference | A map value `{"§": "§ruleName"}` in tree data. Replaced by the rule's result at its exact location — also inside nested maps and lists. |
| Rule | A named list of variants under a rule key like `"§borderWidth"`. |
| Variant | Optional `selector`, optional `inputs`, one CEL `expression`. |
| Selector | Conditions `treeQuery == literal`, all of which must hold. |
| Inputs | Explicit bindings from CEL identifiers to tree queries, evaluated from the node holding the reference. |

### Precedence

The variant with the most selector conditions wins (CSS-like
specificity); ties go to the later variant. `RuleBook.merge` takes
books in ascending priority (e.g. global → vendor → item), so later
books win ties. If no variant matches, resolution fails with the
per-variant reasons — unless the rule is `optional` (see below).

### Inputs and defaults

```jsonc
"inputs": {
  "screenWidth": "screen#width",                    // short form
  "margin": { "query": "#margin", "default": 4.0 }  // long form
}
```

Without a default, an unresolvable input query is an error naming the
input, query, rule, and node.

### Inline expressions

A tree value can carry an expression directly instead of referencing
a rule:

```json
{ "§expression": "w < 400.0 ? 3.0 : 2.0", "§inputs": { "w": "#width" } }
```

The whole map is replaced by the result.

### Reserved keys — strings are always data

References are maps, so no string value ever needs escaping:
`"§name"`, `"§ 5 Abs. 2"`, and any other `§`-string are plain data,
in authored trees and in rule results alike. The flip side: map keys
starting with `§` are reserved. A map carrying such a key must be a
reference or an inline expression — anything else (e.g. a typo like
`"§expresion"`) fails resolution with a clear message.

### Optional rules and result types

```json
{
  "§hint": {
    "optional": true,
    "resultType": "number",
    "variants": [ { "selector": { "#a": 1 }, "expression": "2.0" } ]
  }
}
```

When no variant of an optional rule matches, the reference is removed
(map entries) or nulled (list elements) instead of erroring. A
declared `resultType` (`number`, `string`, `bool`, `list`, `map`)
validates every resolved result of the rule.

## Resolution semantics

- `resolve(tree)` works on a deep copy; the original keeps its
  references. Copy mode requires the tree root (a detached subtree
  copy would silently lose inherited context — the resolver fails
  fast instead). `resolve(tree, inPlace: true)` mutates directly and
  also resolves a subtree within its full tree.
- One call resolves everything, order-independently: items whose
  selectors or inputs read still-unresolved values are deferred and
  retried; queries never silently search past an unresolved value.
- A rule result containing a reference map is re-resolved (aliasing);
  circular aliases fail with the full chain in the message.
- A resolved tree contains no references, so `resolve()` is
  idempotent and re-runnable: resolve → interpret values → grow the
  tree (new subtrees may carry new references) → resolve again.
- If nothing can make progress, resolution fails listing every
  pending item and the value it waits for.

## Debugging: verbose mode

To see which rule/variant produced each value, use `resolveVerbose`
instead of `resolve`. It behaves identically but also returns a
`ResolutionReport`:

```dart
final (resolved, report) = Resolver(ruleBook: ruleBook)
    .resolveVerbose(app, rich: true);
print(report);
// ResolutionReport (1 entries, rich):
//   /dialog#borderWidth ← §borderWidth[2] = 3.0  {selector {…}; inputs {…}; …}
```

Each `ProvenanceEntry` carries, at minimum, the `location`, the `kind`
(`rule` / `inline` / `optionalRemoval`), the `ruleKey`, the
`variantIndex`, and the `value`. Pass `rich: true` to also capture the
winning variant's `selector`, the bound `inputs`, the `expression`
source, and the `aliasChain`. A location appears once per alias hop.
`report.at(location)` filters, and both `ResolutionReport` and
`ProvenanceEntry` have `toJson()`. `resolve()` itself is unchanged and
records nothing.

## Supported CEL subset

Expressions run on the [`cel`](https://pub.dev/packages/cel) Dart
engine. `test/fixtures/cel_conformance.json` pins the exact supported
subset and is reusable from a TypeScript harness (`@bufbuild/cel`)
for cross-language authoring parity. Highlights:

- Operators, ternary `c ? a : b`, `in`, string functions
  (`contains`, `startsWith`, `endsWith`, `matches`), list/map
  construction and indexing.
- **Not** supported: `size()`, macros (`has`, `all`, `exists`,
  `map`, `filter`), type conversions, timestamps, unary minus
  on non-literals (`-x`), and field access after an index (write
  `m[0]["key"]` instead of `m[0].key`).
- Gotchas: `int + double` truncates when the int is on the left
  (write `400.0`), list/map equality is identity, bytes literals
  behave as integer lists.

No `min`/`max` built-ins: use the ternary (`a < b ? a : b`).

## Error reporting

All errors are subtypes of the sealed `TreeExpressionsException`
(`SchemaException`, `ExpressionException`, `QueryException`,
`UnknownRuleException`, `CircularAliasException`,
`NoVariantException`, `MissingInputException`, `StuckException`,
`ResolveException`) carrying typed fields — catch categories instead
of parsing messages.

Every failure names the node path, rule key, variant, and — where
applicable — the alternatives that were considered: unknown rules get
did-you-mean suggestions, unmatched rules list why each variant
failed, stuck resolutions list every pending item and its blocker.
`RuleBook.lint()` additionally flags suspicious setups (identical
rules under two names, duplicate selectors, missing base variants).

## Example

See `example/gg_tree_expressions_example.dart` and the tests.

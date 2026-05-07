# Policy AST reference

zopa's AST is plain JSON. Every node is an object with a `type` field
and node-specific properties. The shape mirrors a useful subset of
Rego.

## Module

A complete policy:

```json
{
  "type": "module",
  "rules": [ <Rule>, ... ]
}
```

Evaluation picks every rule whose `name` matches the target rule
(default `"allow"`) and OR-combines them. A bare expression at the
top level (without `"type": "module"`) is wrapped into a synthetic
`allow` rule -- handy for tests and small policies.

## Rule

```json
{
  "type": "rule",
  "name": "allow",
  "default": false,
  "body":  [ <Expr>, ... ],
  "value": <Expr>
}
```

| Field     | Meaning                                                                                                                  |
| --------- | ------------------------------------------------------------------------------------------------------------------------ |
| `name`    | Required. The rule name to dispatch against.                                                                             |
| `default` | Optional, default `false`. When true, this rule's `value` is the fallback when no other rule with the same name fires.   |
| `body`    | Optional. Implicit AND of expressions. Every entry must evaluate truthy for the rule to fire. Empty body = always fires. |
| `value`   | Optional. Resolved when the body fires. Defaults to boolean `true`. Non-boolean values are treated as truthy.            |

## Expressions

### `value` -- literal

```json
{ "type": "value", "value": <JSON value> }
```

`<JSON value>` is any JSON scalar or composite. Composites (arrays,
objects) are projected to internal `Value` form.

### `ref` -- path lookup

```json
{ "type": "ref", "path": ["input", "user", "role"] }
```

Refs walk the active scope chain first, then the input root. A
leading `"input"` segment is stripped (it just names the input root,
matching Rego's convention).

A missing path is *undefined*, treated as `false` in body position --
deny-by-default.

### `compare` -- binary comparison

```json
{
  "type": "compare",
  "op":   "eq" | "neq" | "lt" | "lte" | "gt" | "gte",
  "left":  <Expr>,
  "right": <Expr>
}
```

Equality (`eq` / `neq`) works on every value kind. Order operators
(`lt` / `lte` / `gt` / `gte`) work on numbers and strings; mixed
types compare as `false`.

Shorthand: any of the op names as the `type` directly.

```json
{ "type": "eq", "left": ..., "right": ... }
```

is identical to

```json
{ "type": "compare", "op": "eq", "left": ..., "right": ... }
```

### `not` -- negation

```json
{ "type": "not", "expr": <Expr> }
```

Boolean negation of the inner expression.

### `set` -- set literal

```json
{ "type": "set", "items": [ <JSON value>, ... ] }
```

Used as the `source` of a `some` / `every`, or as a literal compared
for equality. Order doesn't matter; duplicates are preserved but
ignored by equality.

### `some` -- existential

```json
{
  "type": "some",
  "var":  "x",
  "source": <Expr>,
  "body":   <Expr>
}
```

Resolves `source` to an array or set, then evaluates `body` once for
each element with `x` bound. True iff any iteration's body holds. An
empty source yields `false`.

### `every` -- universal

```json
{
  "type": "every",
  "var":  "x",
  "source": <Expr>,
  "body":   <Expr>
}
```

Same shape as `some`, but the body must hold for every element.
An empty source yields `true` (vacuous).

## Decision encoding

`evaluate(input, ast)` returns a single `i32`:

| Code | Meaning                                                                     |
| ---- | --------------------------------------------------------------------------- |
| `1`  | Allow. The target rule fired with a truthy value.                           |
| `0`  | Deny. No rule fired and no truthy default rule.                             |
| `-1` | Error. Parse failure, unknown node type, recursion cap, etc. Treat as deny. |

## Limits

- Maximum JSON nesting depth: 64.
- Maximum evaluation recursion depth: 32 (`compare` / `not` / `some` /
  `every` / `resolveValue`).

Both limits are constants in the source -- bump them if you have a
documented need.

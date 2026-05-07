// Integration tests for zopa.wasm via the generic `evaluate` export.
// proxy-wasm imports are stubbed because the test path doesn't reach
// them; a stub firing means the harness has drifted.
//
//   node test/run.mjs                # uses zig-out/bin/zopa.wasm
//   node test/run.mjs path/to.wasm   # explicit path

import { readFileSync } from 'node:fs';
import { argv, exit } from 'node:process';

const wasmPath = argv[2] ?? 'zig-out/bin/zopa.wasm';
const bytes = readFileSync(wasmPath);

const { instance } = await WebAssembly.instantiate(bytes, {
  env: {
    proxy_log: () => 0,
    proxy_get_buffer_bytes: () => 1,
    proxy_get_header_map_pairs: () => 1,
    proxy_get_header_map_value: () => 1,
    proxy_send_local_response: () => 0,
  },
});

const { malloc, free, evaluate, memory } = instance.exports;
const enc = new TextEncoder();

function writeBytes(bytes) {
  const ptr = malloc(bytes.length);
  if (ptr === 0) throw new Error('malloc failed');
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  return { ptr, len: bytes.length };
}

function writeJson(obj) {
  return writeBytes(enc.encode(JSON.stringify(obj)));
}

function freeBuf({ ptr }) {
  free(ptr);
}

function decide(input, ast) {
  const i = writeJson(input);
  const a = writeJson(ast);
  try {
    return evaluate(i.ptr, i.len, a.ptr, a.len);
  } finally {
    freeBuf(i);
    freeBuf(a);
  }
}

let failed = 0;
function check(name, got, expected) {
  if (got === expected) {
    console.log(`PASS  ${name}`);
  } else {
    console.log(`FAIL  ${name}: got ${got}, expected ${expected}`);
    failed++;
  }
}

// ---------------------------------------------------------------------------
// 1. legacy bare expression -- a literal `true` is wrapped into a
//    synthetic `allow` rule with body `[true]` and yields allow.
// ---------------------------------------------------------------------------
check(
  'bare literal true -> allow',
  decide({}, { type: 'value', value: true }),
  1,
);

check(
  'bare literal false -> deny',
  decide({}, { type: 'value', value: false }),
  0,
);

// ---------------------------------------------------------------------------
// 2. compare ops
// ---------------------------------------------------------------------------
const refRole = { type: 'ref', path: ['input', 'user', 'role'] };

check(
  'compare eq -> allow',
  decide(
    { user: { role: 'admin' } },
    { type: 'compare', op: 'eq', left: refRole, right: { type: 'value', value: 'admin' } },
  ),
  1,
);

check(
  'compare eq -> deny on mismatch',
  decide(
    { user: { role: 'guest' } },
    { type: 'compare', op: 'eq', left: refRole, right: { type: 'value', value: 'admin' } },
  ),
  0,
);

check(
  'compare neq -> allow on mismatch',
  decide(
    { user: { role: 'guest' } },
    { type: 'compare', op: 'neq', left: refRole, right: { type: 'value', value: 'admin' } },
  ),
  1,
);

const refAge = { type: 'ref', path: ['input', 'age'] };
check(
  'compare lt -> allow',
  decide({ age: 17 }, { type: 'compare', op: 'lt', left: refAge, right: { type: 'value', value: 18 } }),
  1,
);
check(
  'compare lte -> allow at boundary',
  decide({ age: 18 }, { type: 'compare', op: 'lte', left: refAge, right: { type: 'value', value: 18 } }),
  1,
);
check(
  'compare gt -> deny at boundary',
  decide({ age: 18 }, { type: 'compare', op: 'gt', left: refAge, right: { type: 'value', value: 18 } }),
  0,
);
check(
  'compare gte -> allow at boundary',
  decide({ age: 18 }, { type: 'compare', op: 'gte', left: refAge, right: { type: 'value', value: 18 } }),
  1,
);

// ---------------------------------------------------------------------------
// 3. shorthand `{type:"eq", ...}` aliasing
// ---------------------------------------------------------------------------
check(
  'eq shorthand -> allow',
  decide(
    { user: { role: 'admin' } },
    { type: 'eq', left: refRole, right: { type: 'value', value: 'admin' } },
  ),
  1,
);

// ---------------------------------------------------------------------------
// 4. not
// ---------------------------------------------------------------------------
check(
  'not flips false to allow',
  decide(
    { admin: false },
    { type: 'not', expr: { type: 'ref', path: ['input', 'admin'] } },
  ),
  1,
);
check(
  'not flips true to deny',
  decide(
    { admin: true },
    { type: 'not', expr: { type: 'ref', path: ['input', 'admin'] } },
  ),
  0,
);

// ---------------------------------------------------------------------------
// 5. module with default rule
// ---------------------------------------------------------------------------
const adminPolicy = {
  type: 'module',
  rules: [
    {
      type: 'rule',
      name: 'allow',
      default: true,
      value: { type: 'value', value: false },
    },
    {
      type: 'rule',
      name: 'allow',
      body: [
        { type: 'eq', left: refRole, right: { type: 'value', value: 'admin' } },
      ],
    },
  ],
};
check('module default deny when not admin', decide({ user: { role: 'guest' } }, adminPolicy), 0);
check('module rule fires when admin', decide({ user: { role: 'admin' } }, adminPolicy), 1);

// ---------------------------------------------------------------------------
// 6. nested compare in rule.value
// ---------------------------------------------------------------------------
const ageGate = {
  type: 'module',
  rules: [
    {
      type: 'rule',
      name: 'allow',
      body: [{ type: 'value', value: true }],
      value: { type: 'compare', op: 'gte', left: refAge, right: { type: 'value', value: 18 } },
    },
  ],
};
check('nested compare in value: 25 >= 18 -> allow', decide({ age: 25 }, ageGate), 1);
check('nested compare in value: 12 >= 18 -> deny', decide({ age: 12 }, ageGate), 0);

// ---------------------------------------------------------------------------
// 7. set-style equality (set literal == set value via ref-of-set is
//    not supported yet; here we verify that the set literal builder
//    parses without error and equals itself when wrapped in a body).
// ---------------------------------------------------------------------------
check(
  'set literal in body: definedness -> allow',
  decide(
    {},
    {
      type: 'module',
      rules: [
        {
          type: 'rule',
          name: 'allow',
          body: [{ type: 'set', items: ['a', 'b', 'c'] }],
        },
      ],
    },
  ),
  1,
);

// ---------------------------------------------------------------------------
// 8. invalid input JSON -> -1
// ---------------------------------------------------------------------------
{
  const badBytes = enc.encode('{bad}');
  const bad = writeBytes(badBytes);
  const a = writeJson({ type: 'value', value: true });
  const r = evaluate(bad.ptr, bad.len, a.ptr, a.len);
  freeBuf(bad);
  freeBuf(a);
  check('invalid input json -> -1', r, -1);
}

// ---------------------------------------------------------------------------
// 9. surrogate pair round-trip through 𝄞
// ---------------------------------------------------------------------------
{
  // Emit the AST literal as JSON containing the surrogate pair
  // escape, parsed by zopa as U+1D11E.
  const inputBytes = enc.encode(JSON.stringify({ name: '\u{1D11E}' }));
  const astText = '{"type":"compare","op":"eq",'
    + '"left":{"type":"ref","path":["input","name"]},'
    + '"right":{"type":"value","value":"\\uD834\\uDD1E"}}';
  const i = writeBytes(inputBytes);
  const a = writeBytes(enc.encode(astText));
  const r = evaluate(i.ptr, i.len, a.ptr, a.len);
  freeBuf(i);
  freeBuf(a);
  check('surrogate-pair literal equals U+1D11E in input', r, 1);
}

// ---------------------------------------------------------------------------
// 10. eval depth guard: deeply nested `not` should error out, not
//     stack-overflow. The evaluator collapses the nesting to bool, so
//     we wrap a literal in 64 `not`s -- one over the depth limit.
// ---------------------------------------------------------------------------
{
  let nested = { type: 'value', value: true };
  for (let i = 0; i < 64; i++) {
    nested = { type: 'not', expr: nested };
  }
  // Beyond the depth cap -> error path -> -1.
  check('64 nested nots trip depth guard -> -1', decide({}, nested), -1);
}

// ---------------------------------------------------------------------------
// 11. legacy ref-as-decision: ref to a missing path is undefined
//     and our evaluator denies.
// ---------------------------------------------------------------------------
check(
  'missing ref -> deny',
  decide({}, { type: 'ref', path: ['input', 'missing'] }),
  0,
);

// ---------------------------------------------------------------------------
// 12. some / every iterators
// ---------------------------------------------------------------------------
const someAdmin = {
  type: 'some',
  var: 'tag',
  source: { type: 'ref', path: ['input', 'tags'] },
  body: {
    type: 'eq',
    left: { type: 'ref', path: ['tag'] },
    right: { type: 'value', value: 'admin' },
  },
};
check('some: matching element -> allow', decide({ tags: ['viewer', 'admin', 'guest'] }, someAdmin), 1);
check('some: no match -> deny', decide({ tags: ['viewer', 'guest'] }, someAdmin), 0);
check('some: empty source -> deny', decide({ tags: [] }, someAdmin), 0);

const everyAdmin = {
  type: 'every',
  var: 'tag',
  source: { type: 'ref', path: ['input', 'tags'] },
  body: {
    type: 'eq',
    left: { type: 'ref', path: ['tag'] },
    right: { type: 'value', value: 'admin' },
  },
};
check('every: all match -> allow', decide({ tags: ['admin', 'admin'] }, everyAdmin), 1);
check('every: one mismatch -> deny', decide({ tags: ['admin', 'guest'] }, everyAdmin), 0);
check('every: vacuously true on empty -> allow', decide({ tags: [] }, everyAdmin), 1);

// some over a set literal in the AST
const someInLiteralSet = {
  type: 'some',
  var: 'role',
  source: { type: 'set', items: ['admin', 'editor'] },
  body: {
    type: 'eq',
    left: { type: 'ref', path: ['role'] },
    right: { type: 'ref', path: ['input', 'user', 'role'] },
  },
};
check('some: literal set membership -> allow', decide({ user: { role: 'editor' } }, someInLiteralSet), 1);
check('some: literal set non-member -> deny', decide({ user: { role: 'viewer' } }, someInLiteralSet), 0);

// nested some inside an `every` -- each pair (perm, allowed) checks
// that every required permission is in the user's grants set.
const userHasAllRequired = {
  type: 'every',
  var: 'required',
  source: { type: 'ref', path: ['input', 'required_perms'] },
  body: {
    type: 'some',
    var: 'granted',
    source: { type: 'ref', path: ['input', 'user', 'perms'] },
    body: {
      type: 'eq',
      left: { type: 'ref', path: ['granted'] },
      right: { type: 'ref', path: ['required'] },
    },
  },
};
check(
  'every+some: user has every required perm -> allow',
  decide({ required_perms: ['read', 'write'], user: { perms: ['read', 'write', 'admin'] } }, userHasAllRequired),
  1,
);
check(
  'every+some: missing one required perm -> deny',
  decide({ required_perms: ['read', 'delete'], user: { perms: ['read', 'write'] } }, userHasAllRequired),
  0,
);

if (failed > 0) {
  console.error(`\n${failed} test(s) failed`);
  exit(1);
} else {
  console.log(`\nall tests passed`);
}

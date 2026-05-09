// Latency benchmark for zopa.wasm. v1 covers the zopa side only.
// Drives the generic `evaluate(input, ast)` export. Other engines
// (OPA, Cedar) are deferred per bench/README.md.

import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const DEFAULT_WASM = join(HERE, '..', 'zig-out', 'bin', 'zopa.wasm');
const WASM_PATH = process.argv[2] ?? DEFAULT_WASM;

const WARMUP = 1000;
const ITERS = 10000;

// Minimal stubs for isolated benchmarking. These always succeed and
// would mask real proxy errors if reached, but the generic `evaluate`
// path doesn't call them, so an unexpected hit means the harness has
// drifted from what the wasm expects.
const { instance } = await WebAssembly.instantiate(
  readFileSync(WASM_PATH),
  { env: {
      proxy_log: () => 0,
      proxy_get_buffer_bytes: () => 1,
      proxy_get_header_map_pairs: () => 1,
      proxy_get_header_map_value: () => 1,
      proxy_send_local_response: () => 0,
  }},
);
const { malloc, free, evaluate, memory } = instance.exports;

const enc = new TextEncoder();
function writeJson(obj) {
  const bytes = enc.encode(JSON.stringify(obj));
  const ptr = malloc(bytes.length);
  if (ptr === 0) throw new Error('malloc failed');
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
  return { ptr, len: bytes.length };
}
function freeBuf({ ptr }) { free(ptr); }

function percentile(sorted, p) {
  const idx = Math.min(sorted.length - 1, Math.floor(sorted.length * p));
  return sorted[idx];
}

function runFixture(fix) {
  const i = writeJson(fix.input);
  const a = writeJson(fix.ast);
  try {
    // Warmup also validates the policy actually evaluates without
    // error. evaluate() returns 1 (allow), 0 (deny), or -1 (parse /
    // depth-cap / unknown-node failures). We bail on -1 so the
    // benchmark never times an error path; allow + deny are both
    // legitimate decisions to measure.
    for (let k = 0; k < WARMUP; k++) {
      const r = evaluate(i.ptr, i.len, a.ptr, a.len);
      if (r === -1) throw new Error(`fixture ${fix.name}: evaluate returned -1`);
    }
    const samples = new Float64Array(ITERS);
    for (let k = 0; k < ITERS; k++) {
      const t0 = process.hrtime.bigint();
      evaluate(i.ptr, i.len, a.ptr, a.len);
      const t1 = process.hrtime.bigint();
      samples[k] = Number(t1 - t0) / 1000;  // microseconds
    }
    samples.sort();
    const mean = samples.reduce((s, x) => s + x, 0) / samples.length;
    return {
      p50:  percentile(samples, 0.50),
      p95:  percentile(samples, 0.95),
      p99:  percentile(samples, 0.99),
      mean,
    };
  } finally {
    freeBuf(i);
    freeBuf(a);
  }
}

const fixturesDir = join(HERE, 'fixtures');
const fixtures = readdirSync(fixturesDir)
  .filter(f => f.endsWith('.json'))
  .sort()
  .map(f => JSON.parse(readFileSync(join(fixturesDir, f), 'utf8')));

console.log('fixture                 |    p50 |    p95 |    p99 |   mean');
console.log('------------------------+--------+--------+--------+-------');
for (const fix of fixtures) {
  const r = runFixture(fix);
  const fmt = (x) => x.toFixed(2).padStart(6);
  console.log(`${fix.name.padEnd(24)}|${fmt(r.p50)}  |${fmt(r.p95)}  |${fmt(r.p99)}  |${fmt(r.mean)}`);
}

# proxy-wasm integration

zopa implements the [proxy-wasm 0.2.1][spec] ABI. This document
covers what's exported, what's imported, and the assumptions zopa
makes about the host.

[spec]: https://github.com/proxy-wasm/spec/blob/master/abi-versions/v0.2.1/README.md

## ABI version negotiation

zopa exports a single empty function whose name encodes the supported
version:

```text
proxy_abi_version_0_2_1
```

A host that supports a different version should refuse to load.

## Exports

### Buffer ownership

| Name     | Signature            | Notes                                                                                                                    |
| -------- | -------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `malloc` | `(size: i32) -> i32` | Returns 0 on OOM. The block has an 8-byte length prefix in front of the payload; the host sees only the payload pointer. |
| `free`   | `(ptr: i32) -> void` | Length is recovered from the prefix; no length argument needed.                                                          |

### Lifecycle

| Name                        | Signature                                         | Status                                                                                                                                                                                                |
| --------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `proxy_on_vm_start`         | `(root_id, vm_config_size) -> i32`                | Returns 1 (OK).                                                                                                                                                                                       |
| `proxy_on_configure`        | `(context_id, config_size) -> i32`                | Reads the policy AST JSON via `proxy_get_buffer_bytes(BufferType.PluginConfiguration)` and stores it in `host_allocator`. Returning 0 from here is treated as an unrecoverable load failure by Envoy. |
| `proxy_on_context_create`   | `(context_id, parent_context_id) -> void`         | No-op.                                                                                                                                                                                                |
| `proxy_on_request_headers`  | `(context_id, num_headers, end_of_stream) -> i32` | Builds an input from the request header map and runs `evaluate`. Returns `Action.Continue`. Sends a 403 via `proxy_send_local_response` on deny.                                                      |
| `proxy_on_request_body`     | `(context_id, body_size, end_of_stream) -> i32`   | Currently a no-op (returns Continue). Body-aware evaluation needs per-request state plumbing -- see ROADMAP.md.                                                                                       |
| `proxy_on_response_headers` | `(context_id, num_headers, end_of_stream) -> i32` | Currently a no-op. Response policies need a separate target rule and a response-shaped input.                                                                                                         |
| `proxy_on_done`             | `(context_id) -> i32`                             | Returns 1.                                                                                                                                                                                            |

### Generic ABI (not proxy-wasm)

| Name       | Signature                                         | Notes                                                                                                            |
| ---------- | ------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `evaluate` | `(input_ptr, input_len, ast_ptr, ast_len) -> i32` | Returns 1=allow, 0=deny, -1=error. The arena is reset before returning, so caller buffers stay valid throughout. |

## Imports

The host must provide all of these. zopa does not feature-test --
unresolved imports cause module instantiation to fail.

| Name                             | Signature                                                                                                    |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `env.proxy_log`                  | `(level, msg, len) -> i32`                                                                                   |
| `env.proxy_get_buffer_bytes`     | `(buffer_type, start, max_size, return_data, return_size) -> i32`                                            |
| `env.proxy_get_header_map_pairs` | `(map_type, return_data, return_size) -> i32`                                                                |
| `env.proxy_get_header_map_value` | `(map_type, key_data, key_size, return_data, return_size) -> i32`                                            |
| `env.proxy_send_local_response`  | `(status, details_data, details_size, body_data, body_size, headers_data, headers_size, grpc_status) -> i32` |

## Input shape

For request-side evaluation the input is built by reading the
request header map:

```json
{
  "method":  "GET",
  "path":    "/orders/42",
  "headers": {
    "host":          "api.example.com",
    "authorization": "Bearer ...",
    "user-agent":    "..."
  }
}
```

`:method` and `:path` are pulled via `proxy_get_header_map_value`
because some hosts (Envoy with the `wamr` runtime, in particular)
omit pseudo-headers from `proxy_get_header_map_pairs`. Real headers
come from `pairs`. Pseudo-headers in `pairs` are filtered to avoid
duplication.

## Configuration

The plugin configuration string passed to Envoy is the policy AST
JSON:

```yaml
config:
  configuration:
    "@type": type.googleapis.com/google.protobuf.StringValue
    value: |
      { "type": "module", "rules": [ ... ] }
```

zopa stores a `host_allocator.dupe` of those bytes for the lifetime
of the module. Reconfiguration replaces the previous copy.

## Runtime selection

The Envoy build matters: pick a build that ships the runtime your
distribution provides.

| Envoy build                                      | Runtimes shipped |
| ------------------------------------------------ | ---------------- |
| Homebrew                                         | `null`, `wamr`   |
| Official Docker (`envoyproxy/envoy:*`)           | `null`, `v8`     |
| Self-built with `--define wasm=wamr,wasmtime,v8` | All of the above |

zopa is plain `wasm32-freestanding` with only the proxy-wasm imports,
so any of these runtimes works. Pick whatever your host has.

## Host quirks discovered while integrating

- **Pseudo-headers:** Envoy/wamr does not surface `:method`, `:path`,
  or `:authority` through `proxy_get_header_map_pairs`. zopa works
  around this by reading them individually with
  `proxy_get_header_map_value`.
- **Response phase headers:** by the time `proxy_on_response_headers`
  fires the request header map has been cleared. A response policy
  can't reference `input.method` from inside that callback.
- **Body phase pseudo-headers:** same as the response phase --
  pseudo-headers are gone by `proxy_on_request_body`. Body-aware
  policies need to snapshot what they care about during
  `proxy_on_request_headers`.

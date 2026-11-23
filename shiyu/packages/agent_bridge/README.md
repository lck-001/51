# agent_bridge

App-owned Windows local text-candidate authorization, a small private framed
connection, and a separately compiled stdio MCP proxy. Defaults to disabled.
This is neither a model runner, a public HTTP service nor brand authentication.

`AgentBridgeController.attach(materials:, candidates:, privateDirectory:,
rootLock:, proxyCommand:)` accepts the App's already opened matching-owner
instances. It never opens another Store. Acquire `LearningRootLock` before both
Store opens, including migration. Stop bridge admission and drain real pending
commits, close both Stores, then release the Root lock; never unlink its sentinel.

The public UI contracts are in `agent_bridge_contracts.dart`:

- `authorize(AgentBridgeGrantRequest(materialVersionId:, allowSourceRead:false))`
  explicitly grants one confirmed source for 15 minutes; no account/CLI/model/TTS
  is invoked. Source text reading needs its separate checkbox/scope.
- `current`/`snapshots` expose authorization and real pending-operation metadata,
  never credentials, source text, an endpoint or private path.
- `revoke()` immediately stops new admission but waits for already accepted Core
  work; disconnect/timeout does not imply delivery was cancelled.
- `setup()` is an explicit owner-only advanced action with a secret-free TOML
  template. It requires the App's compiled `tools/shiyu_agent_proxy.exe` and
  exports canonical local paths, not an R-drive SDK/development script.
- `retire()` and `close()` belong to App shutdown, not ordinary page disposal.

`AgentBridgeClient(descriptorPath:)` and the stdio proxy only read that explicit
owner-private descriptor; they never discover/open/modify a material/learning
manifest. The proxy accepts no argv; the environment contains only the locator
`SHIYU_BRIDGE_DESCRIPTOR`. The generated file contains short-lived secrets and
must never be printed, shared, placed in Git, or supplied as a tool argument.

Tools are limited to `shiyu_get_source_reference`, `shiyu_read_fixed_source` and
`shiyu_submit_learning_candidate`. The latter requires exact source IDs/hash,
delivery ID, nonempty English+Chinese sentence pairs and an unverified source
declaration. Media presence, even null, is unsupported in B1. No tool confirms,
lists other candidates, generates, executes instructions, downloads a URL or
publishes. Receipt `status=delivered` says only persistent delivery; a replay may
refer to an already confirmed/rejected candidate, whose current owner state is
not disclosed. Unknown delivery outcomes must be checked using the same delivery
ID and content, never automatically resent under a new ID.

Network transport is private binary framing, not HTTP/MCP-over-HTTP. Literal
IPv4 loopback, fixed NUL magic, byte/depth/node bounds, same-Socket HMAC proof
before credentials/body, independent source read, one real Store operation, and
serial revoke/rotation are reviewed in
[`M19B1-local-bridge-design.md`](../../docs/reviews/M19B1-local-bridge-design.md).
The outer stdio uses MCP UTF8 newline JSON-RPC, initialized capability gating,
two supported protocol versions and bounded session IDs/output. stdout has only
MCP messages. No credentials or private locator occur in errors.

Windows native owner/protected DACL verification allows only current user and
SYSTEM. Existing broad permission fails without writing a secret. This does not
defend against an administrator or arbitrary malicious software under the same
OS identity. A restricted tool sandbox may correctly lack access to this owner's
file: do not broaden the ACL to make it work. Actual desktop client launch/reload
is a separate acceptance step. Android/Apple external stdio is not enabled by
this B1 implementation; Root writer locking remains platform-aware.

Exact dependencies reuse existing `crypto:3.0.8`, `ffi:2.2.0` and local Core
packages, without upgrading versions. FFI has a BSD-style license. Compile the
proxy using the existing SDK, then bundle the resulting executable alongside the
App; ordinary users need no Python or Dart SDK. Build output, local descriptors,
private receipts and synthetic runtime files are excluded from public source.

Tests use new temporary roots, actual filesystem/OS locks/ACLs, actual local
frames, controlled process senders and real same-instance Stores. They do not
prove Codex/WorkBuddy/Baidu brand connection, model invocation, language quality,
audio, scoring, four-platform acceptance or publication. See the result record
for exact evidence and failed-fixture corrections.

## C1 private media ingestion

`MediaIngest` is a separate, local structure-only capability. It accepts a
manifest, ordered bounded chunks, a sealed receipt and a complete structured
submission. It owns its staging/journal lifecycle, not the two caller-owned
Stores. Cancellation closes admission synchronously and drains real work;
recovery reconciles the original operation/delivery keys against the Stores.
Uncertain state is held rather than silently discarded or treated as absent.

C1 has no socket/stdio exposure or App permission UI. Its evidence is explicitly
`controlledTest`, not an invented raw transport digest or assistant brand
identity. See [the scoped result](../../docs/reviews/B2C1-media-ingest-results.md)
and execute `test/media_ingest_local.dart` with the existing Dart SDK/package
configuration. Windows tests require the actual owner context for their own
private ACL fixtures; no user directory permissions should be weakened.

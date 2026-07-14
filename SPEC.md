# Zinc specification

## Boundary

Circuitry executes crystallized dataflow written as KDL or KDL-fronted Markdown. Zinc owns immutable packets, stable block manifests, visual/context heads, fork groups, completion events, and Store transactions. Solid owns thread rows and application state. Lexical owns one loaded block's editing and selection.

Zinc has no accounts, authentication, identity verification, merge engine, CRDT, revision browser, or body-history chain.

## Configuration and theme

`config.kdl` requires `store`, `turn`, and `theme` paths. Relative paths resolve from the config directory. `theme.kdl` contains exactly one `theme` node with strict hexadecimal values for `background`, `surface`, `text`, `muted`, `accent`, `positive`, `negative`, `warning`, `info`, and `violet`.

The server validates the KDL and publishes `/theme.css` before browser startup. All browser colors derive from these variables. Zinc has one configured theme and no persisted theme presentation metadata.

A human author is a trimmed description of 1–64 characters. `agent` and `system` are reserved. Human HTTP commits use the configured author; the browser cannot select an author.

## Schema v8

```sql
meta(key text primary key, value text not null)
packets(id text primary key, sources text not null, role text not null, author text not null, at integer not null, bytes blob not null)
threads(id text primary key, identifier text not null, visual_revision text not null, context_revision text not null, body_packet text not null, body_to text, context_packet text not null, context_to text, prompt_tokens integer not null, updated integer not null, parent_thread text, origin_point text, baseline_packet text, baseline_to text)
fork_points(id text primary key, block_id text not null)
fork_members(point_id text not null, thread_id text not null, primary key(point_id,thread_id))
```

Schema v8 is fresh-only. Any other version fails with `Unsupported Zinc store schema: <version>. Clean the store before opening it.`

Packets contain exact bytes, an ordered JSON array of direct source slices, a role, the author of those bytes, and creation time. Source order, ranges, and duplicate occurrences are significant. Large bytes may live in validated overflow files.

A head packet contains ordered stable block references:

```ts
type Slice = { packet: string; from?: number; to?: number };
type BlockRef = { id: string; slice: Slice };
type Head = { blocks: BlockRef[] };
```

Head packets have empty sources. Opaque visual/context revision strings provide CAS without exposing head packet IDs to Web.

## Roles and authors

`role` is `user`, `agent`, or `system`. It records the original purpose of a block. `author` records who last produced its bytes.

Editing retains the existing role. Splits inherit it. Merges retain the surviving block's role. Reordering does not change it. A new browser or dock block is `user`; provider output is `agent`; host/action output is `system` unless explicitly classified otherwise.

Raw completion context is headed by role. The packet catalog separately exposes role, author, sources, active state, and content.

## Manifests, reads, and patches

Web initially receives:

```ts
type ThreadManifest = {
  id: string;
  revision: string;
  identifier: string;
  blocks: Array<{ id: string; role: Role; author: string; sourceCount: number; byteLength: number }>;
  forkPoints: ForkPointDescriptor[];
};
```

The manifest contains no block bytes. `POST /api/blocks/read` accepts up to 256 block IDs from one exact revision and returns their bytes plus direct sources.

A save is:

```ts
type ThreadPatch = {
  revision: string;
  identifier?: string;
  order: string[];
  writes: Array<{ id: string; origins: string[]; bytes: Uint8Array }>;
};
```

`order` contains every resulting stable block ID. `writes` contains only changed and new blocks. Omission deletes. Origins resolve against the base revision, retain order and duplicates, and become exact source slices. Existing IDs without writes reuse packets.

A save acknowledgement returns a manifest. It never returns a reconstructed Lexical document.

## Packet formats

Visual content uses canonical Zinc envelopes rather than serialized complete-thread Lexical documents. Supported packets include text formats (`markdown`, `reasoning`, `error`, `tsx`, `kdl`, and `json`) and structured shell, recall, and definition packets.

Web projects these into ordinary rich-text nodes plus retained `EquationNode`, `TsxPreviewNode`, `ReasoningNode`, `ShellNode`, `RecallNode`, and `ErrorNode`. Browser-only node state does not enter Zinc core.

## Dual heads

The visual head is the complete user-facing thread. The context head starts equivalent and may later retain, summarize, or omit visual ranges. Compaction changes only context.

Visual edits reconcile context transactionally. Unaffected context derivations remain. Any summary whose represented visual lineage was changed expands to current visual descendants. New output enters both heads.

A context summary is an ordinary system Markdown packet whose sources are the exact adjacent context occurrences it replaced.

## Sources

Each loaded sourced block displays only its direct source occurrences. Hover or focus fetches one exact packet/range and renders a non-mutating diff outside Lexical.

Applying a source creates a new packet with selected bytes, target role, configured human author, selected direct lineage, and the same stable block ID. Visual and context heads update in one transaction.

## Forks

A new fork references an existing visual head plus an inclusive stable block boundary. It initially creates no copied head packet. Its context starts from the exact visual prefix, independent of parent compaction.

`fork_points` name a stable anchor block. `fork_members` is many-to-many. Every live member receives every other member in its gutter. A descendant inherits earlier memberships whose anchors remain in its prefix. Deleting an anchor removes that thread's membership.

A fork stores its parent and immutable baseline. After each commit and release, Zinc compares ordered block IDs, roles, and exact ranged bytes to the baseline. Equivalent forks are deleted, memberships are cleaned, and the browser redirects to the parent. Packet IDs, authors, sources, and identifier presentation do not affect equivalence.

## Host and completion

One ZincHost owns one parsed `turn.md`, one Circuitry Runtime, Store registry, lazy Store connections, active completions, and SSE subscribers. Configured `parallel` is supplied explicitly.

Dock submission captures dirty thread blocks and new user blocks in one ThreadPatch. Store commits that patch before the configured turn starts. No browser projection array exists.

ZincHost supplies clean visual/context Markdown, structured packet catalogs, event, definitions, shell/workspace/allowlist, provider endpoint, and token measurements. It supplies no provider prompt and assigns no provider request roles. Markdown Circuitry programs own requests and prompting.

Raw context contains no packet IDs, ranges, omission markers, or source comments. Packet topology is available only through the packet catalog. Whole context occurrences are selected newest-first and are never split.

Reasoning and response stream transiently and persist after EOF. SSE disconnect does not cancel work. Explicit cancellation aborts without storing an error. Nested action failures become durable system context during ordinary turns.

## Compaction

`compact-at` is an integer from 1 to 100. Compaction is required when recorded prompt tokens reach its percentage of `context-tokens`, or when complete context occurrences do not fit the hard byte window.

The bundled `compact.md` returns decisions covering every current context occurrence once and in order: one-index keep/drop decisions or adjacent-index summaries with non-empty Markdown. Zinc maps indexes to exact slices before Store validation. A valid compaction updates context only and resets prompt usage.

## Web session

One Solid thread session owns revision, identifier, descriptors, loaded payloads, dirty generations, save queue, run output, conflicts, and mounted editor handles. ZincClient is stateless HTTP/SSE transport.

TanStack Solid Virtual uses native window scrolling, stable block keys, dynamic measurement, six-row overscan, and pinned focused/dirty/saving/preview rows. Clean offscreen editors detach and may be evicted. Web does not keep a hidden complete document or custom scroll-state manager.

Save generations prevent an acknowledgement from clearing newer changes. A 409 freezes autosave and retains dirty editors until explicit reload; Zinc performs no merge.

## Editing

Each loaded block owns one Lexical editor. Solid owns order and block operations. Enter splits a top-level paragraph; Shift+Enter inserts a local line break; structural nodes retain their normal local Enter behavior. Boundary Backspace/Delete merge compatible blocks. Reorder changes manifest order without mutating Lexical.

Markdown syntax characters are ordinary source TextNodes. The Markdown plugin derives ephemeral syntax ownership, collapses markers outside valid active ranges, reveals them with inherited typography, and reparses only the edited block when grammar changes. Selection-only visibility does not dirty content.

`EquationNode` stores exact delimiters and renders through KaTeX. Activation exposes ordinary source text in the parent Lexical root; leaving valid source restores the equation node. There is no nested editable element.

TSX begins as `TsxPreviewNode` and explicitly toggles to a normal `CodeNode(language="tsx")`. Markdown parsing is disabled for TSX packets. Presentation mode is session-local and defaults to preview after clean remount.

Undo is local to one block. Native browser find and rich selection observe mounted rows only; Zinc does not create hidden full-document authorities to disguise virtualization.

## Presentation

The top bar spans the viewport with 24px edge insets. The manuscript and dock are 820px wide. The dock is fixed 24px from the bottom, has 20px padding, a 140px minimum, and a 360px maximum. Its measured height sets thread bottom occlusion.

One identifier string persists. Tags canonicalize to the front and render leftmost as soft `#text` chips. Titles, bookmark fallback, icon colors, and tag colors are derived.

User/non-user dividers depend only on adjacent roles. Agent and system are the same non-user side. Source tags stay below their block in normal flow.

Gutter order is `[new fork] [other forks…] [handle] │ thread`. It is `max-content`, right-anchored, non-wrapping, and grows left without moving the manuscript.

StyleX owns Solid-rendered chrome. Reset, Lexical descendant rules, KaTeX, custom-node DOM, and virtual geometry remain global CSS. KDL owns all source colors. AnimeJS owns interpolation; CSS transitions, keyframes, and animations are forbidden.

## HTTP

```text
GET    /theme.css
GET    /api/bootstrap
GET    /api/stores
POST   /api/stores
GET    /api/threads
POST   /api/threads
GET    /api/thread
POST   /api/thread
DELETE /api/thread
POST   /api/thread/release
POST   /api/blocks/read
GET    /api/source
POST   /api/source
POST   /api/fork
POST   /api/completions
DELETE /api/completions
GET    /api/events
POST   /api/tsx/compile
```

JSON wire bytes are base64. Source GET returns bytes directly. Stale revisions and duplicate completions return 409.

## Cleanup and distribution

Reachability starts from visual heads, context heads, fork baselines, their block slices, and recursive packet sources. Cleanup removes orphan overflow and SQLite side files while preserving external stores.

TypeScript builds host modules, Vite builds browser assets, and Edge.js runs host and CLI. Standalone installation copies Zinc, defaults, and built Circuitry artifacts. Installed packages are not source-tree symlinks.

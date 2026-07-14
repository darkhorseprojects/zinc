export type Role = "user" | "agent" | "system";
export type SourceSlice = { packet: string; from?: number; to?: number };
export type StoreRef = { path: string; name: string };
export type ThreadSummary = { id: string; identifier: string; revision: string; updated: number };
export type BlockDescriptor = { id: string; role: Role; author: string; sourceCount: number; byteLength: number };
export type ForkPoint = { id: string; block: string; members: ThreadSummary[] };
export type ThreadManifest = { id: string; revision: string; identifier: string; blocks: BlockDescriptor[]; forkPoints: ForkPoint[] };
export type BlockPayload = { id: string; bytes: Uint8Array; sources: SourceSlice[] };
export type BlockWrite = { id: string; origins: string[]; bytes: Uint8Array };
export type ThreadPatch = { revision: string; identifier?: string; order: string[]; writes: BlockWrite[] };
export type CommitResult = { manifest: ThreadManifest; collapsedTo?: string };
export type Bootstrap = { stores: StoreRef[]; store: string | null; threads: ThreadSummary[]; thread: string | null; manifest: ThreadManifest | null; author: string; rawContextBytes: number };
export type ZincEvent =
  | { type: "update" | "done"; store: string; thread: string; revision: string }
  | { type: "deleted"; store: string; thread: string; redirect?: string }
  | { type: "reasoning" | "response" | "error"; store: string; thread: string; text: string };

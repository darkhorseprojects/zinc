import { connect } from "@tursodatabase/database";
import crypto from "node:crypto";
import { mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { humanAuthor } from "./config.js";
import { markdownBlocks } from "./markdown-blocks.js";
import {
  decodeHead,
  encodeHead,
  equalBlocks,
  normalizeIdentifier,
  planPatch,
  prefixHead,
  role as parseRole,
  sameSlice,
  suggestIdentifier,
  type BlockAcknowledgement,
  type BlockDescriptor,
  type BlockPayload,
  type BlockRef,
  type Context,
  type ContextPart,
  type ForkPointDescriptor,
  type Head,
  type Role,
  type Slice,
  type ThreadManifest,
  type ThreadPatch,
  type ThreadSummary,
} from "./thread.js";

type Db = Awaited<ReturnType<typeof connect>>;
type Options = { path: string; packets: string; overflowBytes: number };
type HeadName = "visual" | "context";
type ThreadRow = {
  id: string;
  identifier: string;
  visualRevision: string;
  contextRevision: string;
  body: string;
  bodyTo?: string;
  context: string;
  contextTo?: string;
  promptTokens: number;
  updated: number;
  parent?: string;
  originPoint?: string;
  baseline?: string;
  baselineTo?: string;
};
type PacketMetadata = { id: string; sources: Slice[]; role: Role; author: string; at: number; size: number };
type Packet = PacketMetadata & { bytes: Uint8Array };
type VisualItem = { block: BlockRef; origins: string[]; changed: boolean };
type TitleRow = Pick<ThreadRow, "id" | "identifier" | "visualRevision" | "body" | "bodyTo">;
export type CompactionDecision =
  | { action: "keep" | "drop"; sources: Slice[]; rank: number }
  | { action: "summarize"; sources: Slice[]; rank: number; bytes: Uint8Array };
export type CommitResult = { manifest: ThreadManifest; acknowledged: BlockAcknowledgement[]; collapsedTo?: string };

const encoder = new TextEncoder(), decoder = new TextDecoder("utf-8", { fatal: true }), magic = "zinc-packet-overflow-v1\n";

export class ConflictError extends Error {
  constructor(readonly current: string) { super("Thread changed before this edit could be saved."); }
}

export class Store {
  private titles = new Map<string, { revision: string; title: string }>();
  private constructor(private db: Db, readonly path: string, private directory: string, private limit: number) {}

  static async open(options: Options) {
    await mkdir(dirname(options.path), { recursive: true });
    await mkdir(options.packets, { recursive: true });
    const db = await connect(options.path);
    await schema(db);
    await cleanup(db, options.packets);
    return new Store(db, options.path, options.packets, options.overflowBytes);
  }

  async list(): Promise<ThreadSummary[]> {
    const raw = await (await this.db.prepare("select id,identifier,visual_revision,updated,body_packet,body_to from threads order by updated desc,id")).all() as any[];
    const rows = raw.map(titleRow), titles = await this.threadTitles(rows);
    return raw.map((row, index) => summaryRow(row, titles.get(rows[index].id)));
  }

  async create() {
    const id = next("thr"), files: string[] = [];
    try {
      const transaction = this.db.transaction(async () => {
        const body = await this.insert([], "system", "system", encodeHead({ blocks: [] }), files), revision = next("rev"), now = seconds();
        await (await this.db.prepare("insert into threads(id,identifier,visual_revision,context_revision,body_packet,body_to,context_packet,context_to,prompt_tokens,updated,parent_thread,origin_point,baseline_packet,baseline_to) values(?,?,?,?,?,null,?,null,0,?,null,null,null,null)")).run(id, "", revision, revision, body, body, now);
      });
      await transaction();
      return { id, manifest: await this.manifest(id) };
    } catch (error) { await remove(files); throw error; }
  }

  async manifest(id: string): Promise<ThreadManifest> {
    const row = await this.threadRow(id), head = await this.head(row, "visual"), packets = await this.packetMetadataMap(head.blocks.map((block) => block.slice.packet));
    const blocks: BlockDescriptor[] = head.blocks.map((block) => {
      const packet = packets.get(block.slice.packet); if (!packet) throw new Error(`Missing packet: ${block.slice.packet}`);
      return { id: block.id, role: packet.role, author: packet.author, sourceCount: packet.sources.length, byteLength: packet.size };
    });
    const title = row.identifier || await this.threadTitle(row, head, packets);
    return { id, revision: row.visualRevision, updated: row.updated, identifier: row.identifier, title, blocks, forkPoints: await this.forkPoints(id, new Set(head.blocks.map((block) => block.id))) };
  }

  async readBlocks(id: string, revision: string, ids: string[]): Promise<BlockPayload[]> {
    const row = await this.threadRow(id);
    if (row.visualRevision !== revision) throw new ConflictError(row.visualRevision);
    if (!Array.isArray(ids) || ids.length > 256) throw new Error("A block read accepts at most 256 ids");
    const requested = new Set<string>();
    for (const block of ids) { if (typeof block !== "string" || !block || requested.has(block)) throw new Error("Invalid block read ids"); requested.add(block); }
    const head = await this.head(row, "visual"), byId = new Map(head.blocks.map((block) => [block.id, block]));
    return Promise.all(ids.map(async (block) => {
      const ref = byId.get(block); if (!ref) throw new Error(`Unknown thread block: ${block}`);
      const packet = await this.packet(ref.slice.packet);
      return { id: block, bytes: sliceBytes(packet.bytes, ref.slice), sources: packet.sources.map(copySlice) };
    }));
  }

  read(id: string) { return this.readHead(id, "visual"); }
  readContext(id: string) { return this.readHead(id, "context"); }
  async readHeads(id: string) {
    const row = await this.threadRow(id), heads = new Map<string, Promise<Head>>();
    const load = (packet: string) => { let value = heads.get(packet); if (!value) { value = this.readHeadPacket(packet); heads.set(packet, value); } return value; };
    const [rawVisual, rawContext] = await Promise.all([load(row.body), load(row.context)]), visual = prefixHead(rawVisual, row.bodyTo), context = prefixHead(rawContext, row.contextTo);
    const packets = await this.packetMap([...visual.blocks, ...context.blocks].map((block) => block.slice.packet));
    return {
      visual: this.context(row.visualRevision, visual, packets),
      context: this.context(row.contextRevision, context, packets),
    };
  }

  async state(id: string) {
    const row = await this.threadRow(id);
    return { visualRevision: row.visualRevision, contextRevision: row.contextRevision, promptTokens: row.promptTokens };
  }

  async commit(id: string, patch: ThreadPatch, author: string): Promise<CommitResult> {
    const human = humanAuthor(author), files: string[] = [], acknowledged: BlockAcknowledgement[] = [];
    try {
      let collapsedTo: string | undefined;
      const transaction = this.db.transaction(async () => {
        const row = await this.threadRow(id);
        if (row.visualRevision !== patch.revision) throw new ConflictError(row.visualRevision);
        const oldVisual = await this.head(row, "visual"), oldContext = await this.head(row, "context"), planned = planPatch(oldVisual, patch);
        const oldPackets = await this.packetMetadataMap(oldVisual.blocks.map((block) => block.slice.packet)), nextBlocks: BlockRef[] = [], items: VisualItem[] = [];
        for (const item of planned) {
          if ("reuse" in item) { nextBlocks.push(item.reuse); items.push({ block: item.reuse, origins: [item.id], changed: false }); continue; }
          const current = oldVisual.blocks.find((block) => block.id === item.id), first = item.origins[0], sourcePacket = current ? oldPackets.get(current.slice.packet) : first ? oldPackets.get(first.slice.packet) : null;
          const role = sourcePacket?.role ?? "user", sources = item.origins.map((origin) => copySlice(origin.slice));
          const block = { id: item.id, slice: { packet: await this.insert(sources, role, human, item.bytes, files) } };
          acknowledged.push({ id: item.id, sources: sources.map(copySlice), role, author: human });
          nextBlocks.push(block); items.push({ block, origins: item.origins.map((origin) => origin.id), changed: true });
        }
        const nextVisual = { blocks: nextBlocks }, nextContext = await this.reconcile(oldVisual, oldContext, items);
        const body = equalBlocks(oldVisual.blocks, nextBlocks) && !row.bodyTo ? row.body : await this.insert([], "system", "system", encodeHead(nextVisual), files);
        const context = equalBlocks(nextBlocks, nextContext.blocks) ? body : equalBlocks(oldContext.blocks, nextContext.blocks) && !row.contextTo ? row.context : await this.insert([], "system", "system", encodeHead(nextContext), files);
        const visualRevision = next("rev"), contextRevision = body === row.body && context === row.context && !row.bodyTo && !row.contextTo ? row.contextRevision : next("rev"), identifier = patch.identifier === undefined ? row.identifier : normalizeIdentifier(patch.identifier);
        const changed = await (await this.db.prepare("update threads set identifier=?,visual_revision=?,context_revision=?,body_packet=?,body_to=null,context_packet=?,context_to=null,updated=? where id=? and visual_revision=?")).run(identifier, visualRevision, contextRevision, body, context, seconds(), id, row.visualRevision);
        if (changed.changes !== 1) throw new ConflictError((await this.threadRow(id)).visualRevision);
        await this.removeMissingMemberships(id, new Set(nextBlocks.map((block) => block.id)));
        const updated = await this.threadRow(id);
        if (updated.baseline && await this.baselineEqual(updated, nextVisual)) {
          collapsedTo = updated.parent;
          await this.deleteThreadRow(id);
        }
      });
      await transaction();
      if (collapsedTo) { await this.collect(); return { manifest: await this.manifest(collapsedTo), acknowledged, collapsedTo }; }
      return { manifest: await this.manifest(id), acknowledged };
    } catch (error) { await remove(files); throw error; }
  }

  async appendMany(id: string, role: "agent" | "system", values: Uint8Array[]) {
    if (!values.length) { const manifest = await this.manifest(id), state = await this.state(id); return { manifest, ids: [] as string[], parts: [] as ContextPart[], contextRevision: state.contextRevision }; }
    const files: string[] = [], ids: string[] = [], parts: ContextPart[] = []; let contextRevision = "";
    try {
      const transaction = this.db.transaction(async () => {
        const row = await this.threadRow(id), visual = await this.head(row, "visual"), context = await this.head(row, "context"), appended: BlockRef[] = [];
        for (const value of values) {
          const block = next("blk"), packet = await this.insert([], role, role, value, files), slice = { packet };
          ids.push(block); appended.push({ id: block, slice }); parts.push({ id: block, slice, role, author: role, bytes: value, sources: [] });
        }
        const nextVisual = { blocks: [...visual.blocks, ...appended] }, nextContext = { blocks: [...context.blocks, ...appended] };
        const body = await this.insert([], "system", "system", encodeHead(nextVisual), files), contextPacket = equalBlocks(nextVisual.blocks, nextContext.blocks) ? body : await this.insert([], "system", "system", encodeHead(nextContext), files), visualRevision = next("rev"); contextRevision = next("rev");
        const changed = await (await this.db.prepare("update threads set visual_revision=?,context_revision=?,body_packet=?,body_to=null,context_packet=?,context_to=null,updated=? where id=? and visual_revision=? and context_revision=?")).run(visualRevision, contextRevision, body, contextPacket, seconds(), id, row.visualRevision, row.contextRevision);
        if (changed.changes !== 1) throw new ConflictError((await this.threadRow(id)).visualRevision);
      });
      await transaction(); return { manifest: await this.manifest(id), ids, parts, contextRevision };
    } catch (error) { await remove(files); throw error; }
  }

  async compact(id: string, revision: string, decisions: CompactionDecision[]) {
    const files: string[] = [];
    try {
      const transaction = this.db.transaction(async () => {
        const row = await this.threadRow(id);
        if (row.contextRevision !== revision) throw new ConflictError(row.contextRevision);
        const current = await this.head(row, "context");
        validateCompaction(current.blocks, decisions);
        const nextBlocks: BlockRef[] = []; let cursor = 0;
        for (const decision of decisions) {
          if (decision.action === "keep") nextBlocks.push(current.blocks[cursor]);
          else if (decision.action === "summarize") nextBlocks.push({ id: next("ctx"), slice: { packet: await this.insert(decision.sources, "system", "system", decision.bytes, files) } });
          cursor += decision.sources.length;
        }
        const context = await this.insert([], "system", "system", encodeHead({ blocks: nextBlocks }), files), contextRevision = next("rev");
        const changed = await (await this.db.prepare("update threads set context_packet=?,context_to=null,context_revision=?,prompt_tokens=0 where id=? and context_revision=?")).run(context, contextRevision, id, row.contextRevision);
        if (changed.changes !== 1) throw new ConflictError((await this.threadRow(id)).contextRevision);
      });
      await transaction(); return this.readContext(id);
    } catch (error) { await remove(files); throw error; }
  }

  async recordPromptTokens(id: string, contextRevision: string, tokens: number) {
    if (!Number.isInteger(tokens) || tokens < 0) throw new Error("Prompt token usage must be a non-negative integer");
    const changed = await (await this.db.prepare("update threads set prompt_tokens=? where id=? and context_revision=?")).run(tokens, id, contextRevision);
    if (changed.changes !== 1) throw new ConflictError((await this.threadRow(id)).contextRevision);
  }

  async applySource(id: string, revision: string, blockId: string, sourceIndex: number, author: string): Promise<CommitResult> {
    const human = humanAuthor(author), files: string[] = []; let acknowledged: BlockAcknowledgement | undefined;
    try {
      let collapsedTo: string | undefined;
      const transaction = this.db.transaction(async () => {
        const row = await this.threadRow(id); if (row.visualRevision !== revision) throw new ConflictError(row.visualRevision);
        const visual = await this.head(row, "visual"), context = await this.head(row, "context"), index = visual.blocks.findIndex((block) => block.id === blockId);
        if (index < 0) throw new Error(`Unknown thread block: ${blockId}`);
        const target = visual.blocks[index], packet = await this.packet(target.slice.packet);
        if (!Number.isInteger(sourceIndex) || sourceIndex < 0 || sourceIndex >= packet.sources.length) throw new Error(`Unknown packet source: ${sourceIndex}`);
        const source = packet.sources[sourceIndex], sourcePacket = await this.packet(source.packet), bytes = sliceBytes(sourcePacket.bytes, source);
        const replacementSources = [copySlice(source)], replacement = { id: blockId, slice: { packet: await this.insert(replacementSources, packet.role, human, bytes, files) } }, blocks = [...visual.blocks]; blocks[index] = replacement;
        acknowledged = { id: blockId, sources: replacementSources, role: packet.role, author: human };
        const nextVisual = { blocks }, nextContext = await this.reconcile(visual, context, blocks.map((block, at) => ({ block, origins: [block.id], changed: at === index })));
        const body = await this.insert([], "system", "system", encodeHead(nextVisual), files), contextPacket = equalBlocks(blocks, nextContext.blocks) ? body : await this.insert([], "system", "system", encodeHead(nextContext), files);
        const changed = await (await this.db.prepare("update threads set visual_revision=?,context_revision=?,body_packet=?,body_to=null,context_packet=?,context_to=null,updated=? where id=? and visual_revision=?")).run(next("rev"), next("rev"), body, contextPacket, seconds(), id, row.visualRevision);
        if (changed.changes !== 1) throw new ConflictError((await this.threadRow(id)).visualRevision);
        const updated = await this.threadRow(id); if (updated.baseline && await this.baselineEqual(updated, nextVisual)) { collapsedTo = updated.parent; await this.deleteThreadRow(id); }
      });
      await transaction(); const acknowledgements = acknowledged ? [acknowledged] : [];
      if (collapsedTo) { await this.collect(); return { manifest: await this.manifest(collapsedTo), acknowledged: acknowledgements, collapsedTo }; }
      return { manifest: await this.manifest(id), acknowledged: acknowledgements };
    } catch (error) { await remove(files); throw error; }
  }

  async fork(id: string, revision: string, blockId: string) {
    const fork = next("thr");
    const transaction = this.db.transaction(async () => {
      const row = await this.threadRow(id); if (row.visualRevision !== revision) throw new ConflictError(row.visualRevision);
      const visual = await this.head(row, "visual"); if (!visual.blocks.some((block) => block.id === blockId)) throw new Error(`Unknown thread block: ${blockId}`);
      let point: any = await (await this.db.prepare("select p.id from fork_points p join fork_members m on m.point_id=p.id where m.thread_id=? and p.block_id=? limit 1")).get(id, blockId);
      const pointId = point ? String(point.id) : next("fork");
      if (!point) { await (await this.db.prepare("insert into fork_points(id,block_id) values(?,?)")).run(pointId, blockId); await (await this.db.prepare("insert into fork_members(point_id,thread_id) values(?,?)")).run(pointId, id); }
      const inherited = await (await this.db.prepare("select p.id,p.block_id from fork_points p join fork_members m on m.point_id=p.id where m.thread_id=?")).all(id) as any[], prefix = prefixHead(visual, blockId), ids = new Set(prefix.blocks.map((block) => block.id)), now = seconds();
      const visualRevision = next("rev"), contextRevision = next("rev");
      await (await this.db.prepare("insert into threads(id,identifier,visual_revision,context_revision,body_packet,body_to,context_packet,context_to,prompt_tokens,updated,parent_thread,origin_point,baseline_packet,baseline_to) values(?,?,?,?,?,?,?,?,0,?,?,?,?,?)")).run(fork, row.identifier, visualRevision, contextRevision, row.body, blockId, row.body, blockId, now, id, pointId, row.body, blockId);
      const insert = await this.db.prepare("insert or ignore into fork_members(point_id,thread_id) values(?,?)");
      for (const membership of inherited) if (ids.has(String(membership.block_id))) await insert.run(String(membership.id), fork);
      await insert.run(pointId, fork);
    });
    await transaction(); return { id: fork, manifest: await this.manifest(fork) };
  }

  async release(id: string) {
    const row = await this.threadRow(id).catch(() => null); if (!row || !row.baseline) return { collapsedTo: undefined };
    if (!await this.baselineEqual(row, await this.head(row, "visual"))) return { collapsedTo: undefined };
    const transaction = this.db.transaction(async () => this.deleteThreadRow(id)); await transaction(); await this.collect();
    return { collapsedTo: row.parent };
  }

  async slices(id: string, head: HeadName = "visual") {
    const row = await this.threadRow(id); return { revision: head === "visual" ? row.visualRevision : row.contextRevision, blocks: (await this.head(row, head)).blocks };
  }

  async delete(id: string) {
    const row = await this.threadRow(id).catch(() => null); if (!row) return false;
    const visual = await this.head(row, "visual");
    if (visual.blocks.length && !(row.baseline && await this.baselineEqual(row, visual))) return false;
    const transaction = this.db.transaction(async () => this.deleteThreadRow(id)); await transaction(); await this.collect(); return true;
  }

  async cleanThread(id: string) {
    const transaction = this.db.transaction(async () => { const result = await (await this.db.prepare("delete from threads where id=?")).run(id); if (result.changes !== 1) throw new Error(`Thread not found: ${id}`); await (await this.db.prepare("delete from fork_members where thread_id=?")).run(id); await this.cleanForkPoints(); });
    await transaction(); return this.collect();
  }

  async cleanPacket(id: string) {
    const row: any = await (await this.db.prepare("select bytes from packets where id=?")).get(id); if (!row) throw new Error(`Missing packet: ${id}`);
    const head: any = await (await this.db.prepare("select id from threads where body_packet=? or context_packet=? or baseline_packet=? limit 1")).get(id, id, id); if (head) throw new Error(`Packet ${id} is retained as a head of thread ${String(head.id)}`);
    const threads = await (await this.db.prepare("select id,body_packet,body_to,context_packet,context_to from threads")).all() as any[];
    for (const thread of threads) for (const [packet, to] of [[thread.body_packet, thread.body_to], [thread.context_packet, thread.context_to]]) {
      const ref = (await this.readHeadPacket(String(packet), to == null ? undefined : String(to))).blocks.findIndex((block) => block.slice.packet === id);
      if (ref >= 0) throw new Error(`Packet ${id} is retained by thread ${String(thread.id)} block ${ref}`);
    }
    const rows = await (await this.db.prepare("select id,sources from packets")).all() as any[], child = rows.find((packet) => decodeSources(String(packet.sources)).some((source) => source.packet === id));
    if (child) throw new Error(`Packet ${id} is retained as source of ${String(child.id)}`);
    await (await this.db.prepare("delete from packets where id=?")).run(id); const file = overflowFile(bytes(row.bytes)); if (file) await rm(join(this.directory, file), { force: true });
  }

  close() { return this.db.close(); }

  private async readHead(id: string, head: HeadName): Promise<Context> {
    const row = await this.threadRow(id), value = await this.head(row, head), packets = await this.packetMap(value.blocks.map((block) => block.slice.packet));
    return this.context(head === "visual" ? row.visualRevision : row.contextRevision, value, packets);
  }

  private context(revision: string, head: Head, packets: Map<string, Packet>): Context {
    return { revision, parts: head.blocks.map((block) => {
      const packet = packets.get(block.slice.packet); if (!packet) throw new Error(`Missing packet: ${block.slice.packet}`);
      return { id: block.id, slice: copySlice(block.slice), role: packet.role, author: packet.author, bytes: packet.bytes, sources: packet.sources.map(copySlice) };
    }) };
  }

  private head(row: ThreadRow, name: HeadName) { return this.readHeadPacket(name === "visual" ? row.body : row.context, name === "visual" ? row.bodyTo : row.contextTo); }
  private async readHeadPacket(packet: string, through?: string) { return prefixHead(decodeHead((await this.packet(packet)).bytes), through); }

  private async threadRow(id: string): Promise<ThreadRow> {
    const row: any = await (await this.db.prepare("select * from threads where id=?")).get(id); if (!row) throw new Error(`Thread not found: ${id}`);
    return {
      id: String(row.id), identifier: String(row.identifier), visualRevision: String(row.visual_revision), contextRevision: String(row.context_revision), body: String(row.body_packet),
      ...(row.body_to == null ? {} : { bodyTo: String(row.body_to) }), context: String(row.context_packet), ...(row.context_to == null ? {} : { contextTo: String(row.context_to) }),
      promptTokens: Number(row.prompt_tokens), updated: Number(row.updated), ...(row.parent_thread == null ? {} : { parent: String(row.parent_thread) }), ...(row.origin_point == null ? {} : { originPoint: String(row.origin_point) }),
      ...(row.baseline_packet == null ? {} : { baseline: String(row.baseline_packet) }), ...(row.baseline_to == null ? {} : { baselineTo: String(row.baseline_to) }),
    };
  }

  private async packetMetadata(id: string): Promise<PacketMetadata> {
    const row: any = await (await this.db.prepare("select id,sources,role,author,at,bytes from packets where id=?")).get(id); if (!row) throw new Error(`Missing packet: ${id}`);
    return packetMetadata(row);
  }

  private async packet(id: string): Promise<Packet> {
    const row: any = await (await this.db.prepare("select id,sources,role,author,at,bytes from packets where id=?")).get(id); if (!row) throw new Error(`Missing packet: ${id}`);
    return { ...packetMetadata(row), bytes: await readStored(bytes(row.bytes), this.directory) };
  }

  private async packetMetadataMap(ids: string[]) {
    const unique = [...new Set(ids)]; if (!unique.length) return new Map<string, PacketMetadata>();
    const placeholders = unique.map(() => "?").join(","), rows = await (await this.db.prepare(`select id,sources,role,author,at,bytes from packets where id in (${placeholders})`)).all(...unique) as any[];
    return new Map(rows.map((row) => [String(row.id), packetMetadata(row)]));
  }

  private async packetMap(ids: string[]) {
    const unique = [...new Set(ids)]; if (!unique.length) return new Map<string, Packet>();
    const placeholders = unique.map(() => "?").join(","), rows = await (await this.db.prepare(`select id,sources,role,author,at,bytes from packets where id in (${placeholders})`)).all(...unique) as any[];
    const entries = await Promise.all(rows.map(async (row) => [String(row.id), { ...packetMetadata(row), bytes: await readStored(bytes(row.bytes), this.directory) }] as const));
    return new Map(entries);
  }

  private async insert(sources: Slice[], role: Role, author: string, value: Uint8Array, files: string[]) {
    if (!(value instanceof Uint8Array) || !value.byteLength) throw new Error("Packet writes must contain bytes");
    const id = next("pkt"), stored = await storeBytes(id, value, this.directory, this.limit, files);
    await (await this.db.prepare("insert into packets(id,sources,role,author,at,bytes) values(?,?,?,?,?,?)")).run(id, JSON.stringify(sources.map(copySlice)), role, author, seconds(), stored); return id;
  }

  private async reconcile(oldVisual: Head, oldContext: Head, items: VisualItem[]): Promise<Head> {
    if (!oldContext.blocks.length || equalBlocks(oldVisual.blocks, oldContext.blocks)) return { blocks: items.map((item) => item.block) };
    const oldIds = oldVisual.blocks.map((block) => block.id), reused = new Set(items.filter((item) => !item.changed).map((item) => item.block.id)), groups: Array<{ position: number; blocks: BlockRef[]; represented: number[] }> = [];
    const packets = new Map<string, Promise<PacketMetadata>>(), closures = new Map<string, Promise<Slice[]>>();
    const coverage = await Promise.all(oldContext.blocks.map((block) => this.coverage(block.slice, oldVisual.blocks, packets, closures)));
    for (let index = 0; index < oldContext.blocks.length; index++) {
      const covered = coverage[index], set = new Set(covered), matches = items.map((item, position) => ({ item, position })).filter(({ item, position }) => item.origins.some((origin) => set.has(origin)) || (!item.origins.length && insertionInside(items, position, set)));
      if (!covered.length) continue;
      const invalid = covered.some((id) => !reused.has(id)) || matches.some(({ item }) => item.changed);
      const position = matches[0]?.position ?? Math.max(0, items.findIndex((item) => item.origins.includes(covered[0])));
      if (invalid) groups.push({ position, blocks: matches.map(({ item }) => item.block), represented: matches.map(({ position }) => position) });
      else groups.push({ position, blocks: [oldContext.blocks[index]], represented: matches.map(({ position }) => position) });
    }
    const represented = new Set(groups.flatMap((group) => group.represented));
    items.forEach((item, position) => { if (!represented.has(position) && (item.changed || !oldIds.includes(item.block.id))) groups.push({ position, blocks: [item.block], represented: [position] }); });
    groups.sort((left, right) => left.position - right.position); return { blocks: groups.flatMap((group) => group.blocks) };
  }

  private async coverage(slice: Slice, visual: BlockRef[], packets: Map<string, Promise<PacketMetadata>>, closures: Map<string, Promise<Slice[]>>) {
    const source = await this.closure(slice, packets, closures), result: string[] = [];
    for (const block of visual) if (intersectsAny(source, await this.closure(block.slice, packets, closures))) result.push(block.id);
    return result;
  }

  private closure(root: Slice, packets: Map<string, Promise<PacketMetadata>>, closures: Map<string, Promise<Slice[]>>): Promise<Slice[]> {
    const rootKey = JSON.stringify(root), existing = closures.get(rootKey); if (existing) return existing;
    const result = (async () => {
      const values: Slice[] = [copySlice(root)], pending = [root], visited = new Set<string>();
      while (pending.length) {
        const slice = pending.pop()!, key = JSON.stringify(slice); if (visited.has(key)) continue; visited.add(key);
        let packet = packets.get(slice.packet); if (!packet) { packet = this.packetMetadata(slice.packet); packets.set(slice.packet, packet); }
        for (const source of (await packet).sources) { values.push(copySlice(source)); pending.push(source); }
      }
      return values;
    })();
    closures.set(rootKey, result); return result;
  }

  private async threadTitle(row: TitleRow, head?: Head, metadata?: Map<string, PacketMetadata>) {
    if (row.identifier) return row.identifier;
    const cached = this.titles.get(row.id); if (cached?.revision === row.visualRevision) return cached.title;
    const visual = head ?? await this.readHeadPacket(row.body, row.bodyTo), packets = metadata ?? await this.packetMetadataMap(visual.blocks.map((block) => block.slice.packet));
    const first = visual.blocks.find((block) => packets.get(block.slice.packet)?.role === "user");
    const title = first ? packetTitle(await this.packet(first.slice.packet), first.slice) : "thread";
    this.titles.set(row.id, { revision: row.visualRevision, title }); return title;
  }

  private async threadTitles(rows: TitleRow[]) {
    const result = new Map<string, string>(), pending: TitleRow[] = [];
    for (const row of rows) {
      if (row.identifier) result.set(row.id, row.identifier);
      else { const cached = this.titles.get(row.id); if (cached?.revision === row.visualRevision) result.set(row.id, cached.title); else pending.push(row); }
    }
    if (!pending.length) return result;
    const headPackets = await this.packetMap(pending.map((row) => row.body)), heads = new Map<string, Head>();
    for (const row of pending) { const packet = headPackets.get(row.body); if (!packet) throw new Error(`Missing packet: ${row.body}`); heads.set(row.id, prefixHead(decodeHead(packet.bytes), row.bodyTo)); }
    const metadata = await this.packetMetadataMap([...heads.values()].flatMap((head) => head.blocks.map((block) => block.slice.packet))), first = new Map<string, BlockRef>();
    for (const row of pending) { const block = heads.get(row.id)!.blocks.find((item) => metadata.get(item.slice.packet)?.role === "user"); if (block) first.set(row.id, block); }
    const bodies = await this.packetMap([...first.values()].map((block) => block.slice.packet));
    for (const row of pending) {
      const block = first.get(row.id), packet = block ? bodies.get(block.slice.packet) : undefined, title = block && packet ? packetTitle(packet, block.slice) : "thread";
      result.set(row.id, title); this.titles.set(row.id, { revision: row.visualRevision, title });
    }
    return result;
  }

  private async forkPoints(thread: string, visible: Set<string>): Promise<ForkPointDescriptor[]> {
    const rows = await (await this.db.prepare("select p.id point_id,p.block_id,t.id,t.identifier,t.visual_revision,t.updated from fork_points p join fork_members owner on owner.point_id=p.id and owner.thread_id=? join fork_members member on member.point_id=p.id join threads t on t.id=member.thread_id order by p.id,t.updated desc,t.id")).all(thread) as any[];
    const points = new Map<string, ForkPointDescriptor>();
    for (const row of rows) {
      const id = String(row.point_id), block = String(row.block_id); if (!visible.has(block)) continue;
      let point = points.get(id); if (!point) { point = { id, block, members: [] }; points.set(id, point); }
      point.members.push(summaryRow(row));
    }
    return [...points.values()].filter((point) => point.members.length > 1);
  }

  private async removeMissingMemberships(thread: string, visible: Set<string>) {
    const rows = await (await this.db.prepare("select p.id,p.block_id from fork_points p join fork_members m on m.point_id=p.id where m.thread_id=?")).all(thread) as any[];
    for (const row of rows) if (!visible.has(String(row.block_id))) await (await this.db.prepare("delete from fork_members where point_id=? and thread_id=?")).run(String(row.id), thread);
    await this.cleanForkPoints();
  }

  private async deleteThreadRow(id: string) {
    await (await this.db.prepare("delete from fork_members where thread_id=?")).run(id); await (await this.db.prepare("delete from threads where id=?")).run(id); await this.cleanForkPoints();
  }

  private async cleanForkPoints() {
    await this.db.run("delete from fork_points where id in (select p.id from fork_points p left join fork_members m on m.point_id=p.id group by p.id having count(m.thread_id)<2)");
    await this.db.run("delete from fork_members where point_id not in (select id from fork_points)");
  }

  private async baselineEqual(row: ThreadRow, current: Head) {
    if (!row.baseline) return false; const baseline = await this.readHeadPacket(row.baseline, row.baselineTo);
    if (baseline.blocks.length !== current.blocks.length || baseline.blocks.some((block, index) => block.id !== current.blocks[index].id)) return false;
    for (let index = 0; index < current.blocks.length; index++) {
      const left = current.blocks[index], right = baseline.blocks[index], a = await this.packet(left.slice.packet), b = await this.packet(right.slice.packet);
      if (a.role !== b.role || !Buffer.from(sliceBytes(a.bytes, left.slice)).equals(Buffer.from(sliceBytes(b.bytes, right.slice)))) return false;
    }
    return true;
  }

  private async collect() {
    const threads = await (await this.db.prepare("select body_packet,context_packet,baseline_packet from threads")).all() as any[], rows = await (await this.db.prepare("select id,sources,bytes from packets")).all() as any[], packets = new Map(rows.map((row) => [String(row.id), row])), reachable = new Set<string>();
    for (const thread of threads) for (const raw of [thread.body_packet, thread.context_packet, thread.baseline_packet]) if (raw != null) {
      const head = String(raw), body = packets.get(head); if (!body) throw new Error(`Missing packet: ${head}`); reachable.add(head);
      for (const block of decodeHead(await readStored(bytes(body.bytes), this.directory)).blocks) reachable.add(block.slice.packet);
    }
    const pending = [...reachable]; while (pending.length) { const id = pending.pop()!, packet = packets.get(id); if (!packet) continue; for (const source of decodeSources(String(packet.sources))) if (!reachable.has(source.packet)) { reachable.add(source.packet); pending.push(source.packet); } }
    const removed = rows.filter((row) => !reachable.has(String(row.id))); if (!removed.length) return 0;
    const transaction = this.db.transaction(async () => { const statement = await this.db.prepare("delete from packets where id=?"); for (const row of removed) await statement.run(String(row.id)); }); await transaction();
    await Promise.all(removed.flatMap((row) => { const file = overflowFile(bytes(row.bytes)); return file ? [rm(join(this.directory, file), { force: true })] : []; })); return removed.length;
  }
}

export class Registry {
  private constructor(private file: string, private primary: string, private values: Array<{ path: string; name: string }>) {}
  static async open(file: string, primary: string) {
    let source = ""; try { source = await readFile(file, "utf8"); } catch (error: any) { if (error?.code !== "ENOENT") throw error; }
    const values: Array<{ path: string; name: string }> = [], seen = new Set<string>();
    for (const line of source.split(/\r?\n/)) { if (!line) continue; let value: any; try { value = JSON.parse(line); } catch { throw new Error(`Invalid store registry line: ${line}`); } if (!value || typeof value.path !== "string") throw new Error(`Invalid store registry line: ${line}`); const item = reference(value.path, value.name); if (!seen.has(item.path)) { seen.add(item.path); values.push(item); } }
    const first = reference(primary); if (!seen.has(first.path)) values.unshift(first); return new Registry(file, first.path, values);
  }
  list() { return this.values.map((value) => ({ ...value })); }
  async add(path: string, name?: string) { const item = reference(path, name); this.values = [item, ...this.values.filter((value) => value.path !== item.path)]; await this.save(); }
  async remove(path: string) { const target = resolve(path); if (target !== this.primary) { this.values = this.values.filter((value) => value.path !== target); await this.save(); } }
  private async save() { await mkdir(dirname(this.file), { recursive: true }); const temporary = `${this.file}.tmp`; await writeFile(temporary, `${this.values.map((value) => JSON.stringify(value)).join("\n")}\n`); await rename(temporary, this.file); }
}

export async function readPacketBytes(path: string, directory: string, id: string) {
  const db = await connect(path); try { const row: any = await (await db.prepare("select bytes from packets where id=?")).get(id); if (!row) throw new Error(`Missing packet: ${id}`); return readStored(bytes(row.bytes), directory); } finally { await db.close(); }
}

function validateCompaction(current: BlockRef[], decisions: CompactionDecision[]) {
  const flattened = decisions.flatMap((decision) => decision.sources);
  if (current.length !== flattened.length || current.some((block, index) => !sameSlice(block.slice, flattened[index]))) throw new Error("Compaction must classify every current context range exactly once and in order");
  for (const decision of decisions) {
    if (!decision.sources.length || !Number.isFinite(decision.rank) || decision.rank < 0 || decision.rank > 1) throw new Error("Invalid compaction decision");
    if ((decision.action === "keep" || decision.action === "drop") && decision.sources.length !== 1) throw new Error(`${decision.action} decisions require one source`);
    if (decision.action === "summarize" && (!(decision.bytes instanceof Uint8Array) || !decision.bytes.byteLength)) throw new Error("Compaction summaries require bytes");
  }
}

async function schema(db: Db) {
  await (await db.prepare("create table if not exists meta(key text primary key,value text not null)")).run();
  const version: any = await (await db.prepare("select value from meta where key='schema_version'")).get();
  if (version && String(version.value) !== "8") throw new Error(`Unsupported Zinc store schema: ${String(version.value)}. Clean the store before opening it.`);
  if (!version) {
    const packets: any = await (await db.prepare("select name from sqlite_master where type='table' and name='packets'")).get(); if (packets) throw new Error("Unsupported Zinc store schema. Clean the store before opening it.");
    await db.run("create table packets(id text primary key,sources text not null,role text not null check(role in ('user','agent','system')),author text not null,at integer not null,bytes blob not null)");
    await db.run("create table threads(id text primary key,identifier text not null,visual_revision text not null,context_revision text not null,body_packet text not null,body_to text,context_packet text not null,context_to text,prompt_tokens integer not null,updated integer not null,parent_thread text,origin_point text,baseline_packet text,baseline_to text)");
    await db.run("create table fork_points(id text primary key,block_id text not null)");
    await db.run("create table fork_members(point_id text not null,thread_id text not null,primary key(point_id,thread_id))");
    await db.run("insert into meta values('schema_version','8')");
  }
}

function decodeSources(value: string): Slice[] {
  const parsed = JSON.parse(value); if (!Array.isArray(parsed)) throw new Error("Invalid packet sources");
  return parsed.map((source) => { if (!source || typeof source !== "object" || typeof source.packet !== "string") throw new Error("Invalid packet source"); const from = source.from === undefined ? undefined : Number(source.from), to = source.to === undefined ? undefined : Number(source.to); if (from !== undefined && (!Number.isInteger(from) || from < 0) || to !== undefined && (!Number.isInteger(to) || to <= (from ?? 0))) throw new Error("Invalid packet source"); return { packet: source.packet, ...(from ? { from } : {}), ...(to === undefined ? {} : { to }) }; });
}

function sliceBytes(value: Uint8Array, slice: Slice) {
  if (slice.from === undefined && slice.to === undefined) return value;
  const parsed = JSON.parse(decoder.decode(value)), from = slice.from ?? 0;
  if (Array.isArray(parsed)) return encoder.encode(`${JSON.stringify(select(parsed, slice.packet, from, slice.to))}\n`);
  if (record(parsed) && parsed.zinc === "text" && typeof parsed.text === "string") {
    if (parsed.format === "markdown") return encoder.encode(select(markdownBlocks(parsed.text), slice.packet, from, slice.to).map((block) => block.raw).join(""));
    select([parsed], slice.packet, from, slice.to); return value;
  }
  if (record(parsed) && typeof parsed.zinc === "string") { select([parsed], slice.packet, from, slice.to); return value; }
  throw new Error(`Packet ${slice.packet} does not support ranged reads`);
}
function select<T>(values: T[], id: string, from: number, to?: number) { const end = to ?? values.length; if (!Number.isInteger(from) || from < 0 || !Number.isInteger(end) || end <= from || from >= values.length || end > values.length) throw new Error(`Packet range is outside ${id}`); return values.slice(from, end); }

async function storeBytes(id: string, value: Uint8Array, directory: string, limit: number, files: string[]) {
  if (value.byteLength <= limit && !decoder.decode(value.slice(0, magic.length)).startsWith(magic)) return value;
  const file = `${id}.packet`, temporary = join(directory, `${id}.tmp`), path = join(directory, file); await writeFile(temporary, value); await rename(temporary, path); files.push(path);
  const tail = value.slice(Math.max(0, value.byteLength - limit)); return encoder.encode(`${magic}${JSON.stringify({ file, size: value.byteLength, tail: Buffer.from(tail).toString("base64") })}\n`);
}
async function readStored(value: Uint8Array, directory: string) { if (!decoder.decode(value.slice(0, magic.length)).startsWith(magic)) return value; const marker = overflowMarker(value), content = await readFile(join(directory, marker.file)), tail = Buffer.from(marker.tail, "base64"); if (content.byteLength !== marker.size || !Buffer.from(content).subarray(-tail.length).equals(tail)) throw new Error("Packet overflow mismatch"); return new Uint8Array(content); }
function overflowFile(value: Uint8Array) { return decoder.decode(value.slice(0, magic.length)).startsWith(magic) ? overflowMarker(value).file : null; }
function overflowMarker(value: Uint8Array): { file: string; size: number; tail: string } { const marker = JSON.parse(decoder.decode(value.slice(magic.length)).trim()); if (!marker || typeof marker.file !== "string" || marker.file !== marker.file.split(/[\\/]/).pop() || !Number.isInteger(marker.size) || typeof marker.tail !== "string") throw new Error("Invalid packet overflow marker"); return marker; }
async function cleanup(db: Db, directory: string) { const files = await readdir(directory).catch(() => []), temporary = files.filter((file) => file.endsWith(".tmp")); await Promise.all(temporary.map((file) => rm(join(directory, file), { force: true }))); const overflow = files.filter((file) => file.endsWith(".packet")); if (!overflow.length) return; const referenced = new Set<string>(), rows = await (await db.prepare("select bytes from packets")).all() as any[]; for (const row of rows) { const file = overflowFile(bytes(row.bytes)); if (file) referenced.add(file); } await Promise.all(overflow.filter((file) => !referenced.has(file)).map((file) => rm(join(directory, file), { force: true }))); }

function previousOrigins(items: VisualItem[], index: number) { for (let at = index - 1; at >= 0; at--) if (items[at].origins.length) return items[at].origins; return []; }
function nextOrigins(items: VisualItem[], index: number) { for (let at = index + 1; at < items.length; at++) if (items[at].origins.length) return items[at].origins; return []; }
function insertionInside(items: VisualItem[], index: number, covered: Set<string>) { const before = previousOrigins(items, index), after = nextOrigins(items, index); return before.some((id) => covered.has(id)) && after.some((id) => covered.has(id)); }
function intersectsAny(left: Slice[], right: Slice[]) { return left.some((a) => right.some((b) => overlaps(a, b))); }
function overlaps(left: Slice, right: Slice) { const leftFrom = left.from ?? 0, leftTo = left.to ?? Infinity, rightFrom = right.from ?? 0, rightTo = right.to ?? Infinity; return left.packet === right.packet && leftFrom < rightTo && rightFrom < leftTo; }
function copySlice(slice: Slice): Slice { return { packet: slice.packet, ...(slice.from === undefined ? {} : { from: slice.from }), ...(slice.to === undefined ? {} : { to: slice.to }) }; }
function packetMetadata(row: any): PacketMetadata { const stored = bytes(row.bytes), marker = overflowFile(stored); return { id: String(row.id), sources: decodeSources(String(row.sources)), role: parseRole(row.role), author: String(row.author), at: Number(row.at), size: marker ? overflowMarker(stored).size : stored.byteLength }; }
function titleRow(row: any): TitleRow { return { id: String(row.id), identifier: String(row.identifier), visualRevision: String(row.visual_revision), body: String(row.body_packet), ...(row.body_to == null ? {} : { bodyTo: String(row.body_to) }) }; }
function packetTitle(packet: Packet, slice: Slice) {
  try {
    const value = JSON.parse(decoder.decode(packet.bytes)); if (!record(value) || value.zinc !== "text" || typeof value.text !== "string") return "thread";
    const text = value.format === "markdown" && (slice.from !== undefined || slice.to !== undefined) ? markdownBlocks(value.text).slice(slice.from ?? 0, slice.to).map((block) => block.raw).join("") : value.text;
    return suggestIdentifier(text) || "thread";
  } catch { return "thread"; }
}
function summaryRow(row: any, title?: string): ThreadSummary { const identifier = String(row.identifier); return { id: String(row.id), identifier, title: title || identifier || "thread", revision: String(row.visual_revision), updated: Number(row.updated) }; }
function reference(path: string, name?: unknown) { const absolute = resolve(path); return { path: absolute, name: typeof name === "string" && name ? name : absolute.split(/[\\/]/).pop() || absolute }; }
function next(prefix: string) { return `${prefix}_${crypto.randomUUID()}`; }
function seconds() { return Math.floor(Date.now() / 1000); }
function bytes(value: unknown): Uint8Array { if (value instanceof Uint8Array) return value; if (value instanceof ArrayBuffer) return new Uint8Array(value); if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength); if (typeof value === "string") return encoder.encode(value); return encoder.encode(String(value ?? "")); }
async function remove(files: string[]) { await Promise.all(files.map((file) => rm(file, { force: true }))); }
function record(value: unknown): value is Record<string, any> { return typeof value === "object" && value !== null && !Array.isArray(value); }

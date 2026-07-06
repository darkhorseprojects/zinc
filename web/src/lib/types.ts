export interface Packet {
  id: string;
  parent: string | null;
  at: number;
  bytes: Uint8Array;
}

export interface Thread {
  id: string;
  revision: string;
  meta: Record<string, any>;
}

export interface PacketRange {
  packet: string;
  from?: number;
  to?: number;
  author?: "user" | "assistant" | "system";
}

export interface ThreadBody {
  ranges: PacketRange[];
}

export interface TextRange {
  packet: PacketRange;
  textFrom: number;
  textTo: number;
  byteFrom: number;
  byteTo: number;
}

export interface ThreadText {
  mdx: string;
  ranges: TextRange[];
  byteLength: number;
}

export interface ThreadView {
  id: string;
  revision: string;
  updated: number;
  body: ThreadBody;
  packets: Record<string, Packet>;
  mdx: string;
  meta?: Record<string, any>;
}

export type ThreadListItem = Pick<ThreadView, "id" | "revision" | "updated"> & {
  label: string;
  meta?: Record<string, any>;
};

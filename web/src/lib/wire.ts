import type { ThreadView, Packet } from "./types";

export type WirePacket = Omit<Packet, "bytes"> & { bytes: string };
export type WireThreadView = Omit<ThreadView, "packets"> & { packets: Record<string, WirePacket> };

export type ContinueEvent =
  | { type: "output"; entry: string; stream: "stdout" | "stderr"; text: string }
  | { type: "packet"; packet: WirePacket }
  | { type: "thread"; thread: WireThreadView }
  | { type: "error"; message: string };

export function packetToWire(packet: Packet): WirePacket {
  return {
    id: packet.id,
    parent: packet.parent,
    at: packet.at,
    bytes: Buffer.from(packet.bytes).toString("base64"),
  };
}

export function threadViewToWire(view: ThreadView): WireThreadView {
  return {
    ...view,
    packets: Object.fromEntries(Object.entries(view.packets).map(([id, packet]) => [id, packetToWire(packet)])),
  };
}

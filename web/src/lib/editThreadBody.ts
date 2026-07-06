import { normalizeThreadBody, packetText, utf8ByteLength } from "./threadBody";
import type { PacketRange, ThreadBody, ThreadText, Packet } from "./types";

export async function editThreadBody(
  oldText: ThreadText,
  newMdx: string,
  createPacket: (bytes: string | Uint8Array) => Promise<Packet>,
): Promise<ThreadBody> {
  const oldMdx = oldText.mdx;
  const prefix = commonPrefixLength(oldMdx, newMdx);
  const suffix = commonSuffixLength(oldMdx, newMdx, prefix);
  const oldMiddleTo = oldMdx.length - suffix;
  const newMiddleTo = newMdx.length - suffix;
  const ranges: PacketRange[] = [];

  ranges.push(...sliceThreadText(oldText, 0, prefix));

  const middle = newMdx.slice(prefix, newMiddleTo);
  if (middle) {
    const packet = await createPacket(middle);
    ranges.push({ packet: packet.id });
  }

  ranges.push(...sliceThreadText(oldText, oldMiddleTo, oldMdx.length));
  return normalizeThreadBody({ ranges });
}

export function sliceThreadText(text: ThreadText, textFrom: number, textTo: number): PacketRange[] {
  if (textTo <= textFrom) return [];
  const ranges: PacketRange[] = [];

  for (const range of text.ranges) {
    const from = Math.max(textFrom, range.textFrom);
    const to = Math.min(textTo, range.textTo);
    if (to <= from) continue;

    const rangeText = text.mdx.slice(range.textFrom, range.textTo);
    const innerFrom = from - range.textFrom;
    const innerTo = to - range.textFrom;
    const packetFrom = (range.packet.from ?? 0) + utf8ByteLength(rangeText.slice(0, innerFrom));
    const packetTo = (range.packet.from ?? 0) + utf8ByteLength(rangeText.slice(0, innerTo));

    ranges.push({
      packet: range.packet.packet,
      ...(packetFrom > 0 ? { from: packetFrom } : {}),
      ...(packetTo !== fullRangeTo(range.packet) ? { to: packetTo } : {}),
      ...(range.packet.author ? { author: range.packet.author } : {}),
    });
  }

  return normalizeThreadBody({ ranges }).ranges;
}

export function commonPrefixLength(left: string, right: string) {
  const limit = Math.min(left.length, right.length);
  let index = 0;
  while (index < limit && left[index] === right[index]) index++;
  return index;
}

export function commonSuffixLength(left: string, right: string, prefixLength: number) {
  const limit = Math.min(left.length, right.length) - prefixLength;
  let count = 0;
  while (count < limit && left[left.length - 1 - count] === right[right.length - 1 - count]) count++;
  return count;
}

function fullRangeTo(range: PacketRange) {
  return range.to ?? Number.POSITIVE_INFINITY;
}

export function packetBytesAsString(packet: Packet) {
  return packetText(packet);
}

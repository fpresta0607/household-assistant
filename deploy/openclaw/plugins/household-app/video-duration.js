// Read MP4/MOV timing from the file, never the phone's claimed duration. No codec or
// ffmpeg installation is needed on the gateways. Unknown/fragmented formats fail closed.
export function videoDurationMs(bytes) {
  let boxesLeft = 4096;
  const durations = [];
  let movie = false;
  let track = false;
  function walk(start, end, parent = "") {
    for (let offset = start; offset < end;) {
      if (--boxesLeft < 0 || offset + 8 > end) throw new Error("bad video container");
      let size = bytes.readUInt32BE(offset);
      const type = bytes.toString("ascii", offset + 4, offset + 8);
      let header = 8;
      if (size === 1) {
        if (offset + 16 > end) throw new Error("bad video container");
        const large = bytes.readBigUInt64BE(offset + 8);
        if (large > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error("bad video container");
        size = Number(large);
        header = 16;
      } else if (size === 0) size = end - offset;
      if (size < header || offset + size > end) throw new Error("bad video container");
      const body = offset + header;
      if (type === "moof" || type === "mvex") throw new Error("fragmented video");
      if ((type === "moov" && parent === "") || (type === "trak" && parent === "moov") ||
          (type === "mdia" && parent === "trak")) walk(body, offset + size, type);
      if ((type === "mvhd" && parent === "moov") || (type === "mdhd" && parent === "mdia")) {
        const version = bytes[body];
        const timeOffset = version === 1 ? 20 : 12;
        const needed = version === 1 ? 32 : 20;
        if (![0, 1].includes(version) || body + needed > offset + size) throw new Error("bad video timing");
        const scale = bytes.readUInt32BE(body + timeOffset);
        const ticks = version === 1 ? Number(bytes.readBigUInt64BE(body + 24)) : bytes.readUInt32BE(body + 16);
        if (!scale || !Number.isSafeInteger(ticks) || ticks <= 0 || ticks === 0xffffffff) throw new Error("unknown video timing");
        durations.push(ticks * 1000 / scale);
        if (type === "mvhd") movie = true;
        else track = true;
      }
      offset += size;
    }
  }
  walk(0, bytes.length);
  if (!movie || !track) throw new Error("unknown video timing");
  return Math.max(...durations);
}

#!/usr/bin/env node
// Relay one clear-text HTTP connection, replacing its Host authority before it
// leaves the host. Node fetch derives Host from the URL and ignores a duplicate
// defaultHeaders value, so this must live below the OpenAI client.

import net from "node:net";

const [upstreamHost, upstreamPort, authority] = process.argv.slice(2);
if (!upstreamHost || !/^[0-9]+$/.test(upstreamPort) || !authority) {
  process.stderr.write("usage: http-host-relay.mjs HOST PORT AUTHORITY\n");
  process.exit(2);
}

const upstream = net.connect({ host: upstreamHost, port: Number(upstreamPort) });
let pending = Buffer.alloc(0);
let bodyRemaining = 0;
let chunked = false;
let chunkRemaining = null;
let readingTrailers = false;

function send(bytes) { if (bytes.length) upstream.write(bytes); }

function headerEnd(bytes) {
  const crlf = bytes.indexOf("\r\n\r\n");
  if (crlf >= 0) return [crlf, 4];
  const lf = bytes.indexOf("\n\n");
  return lf >= 0 ? [lf, 2] : null;
}

function rewriteHeader(header) {
  const lines = header.toString("latin1").replace(/\r?\n\r?\n$/, "").split(/\r?\n/);
  // Remove every supplied Host line: leaving a duplicate lets a parser choose
  // the URL-derived authority rather than the endpoint authority.
  const kept = lines.filter((line, index) => index === 0 || !/^host\s*:/i.test(line));
  kept.splice(1, 0, `Host: ${authority}`);
  return Buffer.from(kept.join("\r\n") + "\r\n\r\n", "latin1");
}

function beginRequest(header) {
  const text = header.toString("latin1");
  const contentLength = text.match(/^content-length\s*:\s*(\d+)\s*$/im);
  chunked = /^transfer-encoding\s*:\s*.*\bchunked\b/im.test(text);
  bodyRemaining = contentLength ? Number(contentLength[1]) : 0;
  chunkRemaining = null;
  readingTrailers = false;
  send(rewriteHeader(header));
}

function consume() {
  while (pending.length) {
    if (bodyRemaining) {
      const count = Math.min(bodyRemaining, pending.length);
      send(pending.subarray(0, count)); pending = pending.subarray(count);
      bodyRemaining -= count; continue;
    }
    if (chunked) {
      if (readingTrailers) {
        // An empty trailer section is one CRLF: the zero-sized chunk already
        // carried its own CRLF, so this is not a normal HTTP header block.
        const end = pending.subarray(0, 2).equals(Buffer.from("\r\n"))
          ? [0, 2] : headerEnd(pending);
        if (!end) return;
        const [at, width] = end;
        send(pending.subarray(0, at + width)); pending = pending.subarray(at + width);
        chunked = false; readingTrailers = false; continue;
      }
      if (chunkRemaining === null) {
        const at = pending.indexOf("\r\n");
        if (at < 0) return;
        const line = pending.subarray(0, at + 2);
        const size = Number.parseInt(line.toString("ascii"), 16);
        if (!Number.isFinite(size) || size < 0) { upstream.destroy(new Error("invalid chunked request")); return; }
        send(line); pending = pending.subarray(at + 2);
        if (size === 0) readingTrailers = true;
        else chunkRemaining = size + 2; // chunk bytes and their CRLF
        continue;
      }
      if (pending.length < chunkRemaining) return;
      send(pending.subarray(0, chunkRemaining)); pending = pending.subarray(chunkRemaining);
      chunkRemaining = null; continue;
    }
    const end = headerEnd(pending);
    if (!end) return;
    const [at, width] = end;
    beginRequest(pending.subarray(0, at + width));
    pending = pending.subarray(at + width);
  }
}

process.stdin.on("data", (data) => { pending = Buffer.concat([pending, data]); consume(); });
process.stdin.on("end", () => upstream.end());
process.stdin.on("error", () => upstream.destroy());
upstream.on("data", (data) => process.stdout.write(data));
upstream.on("end", () => process.stdout.end());
upstream.on("error", () => process.stdout.end());

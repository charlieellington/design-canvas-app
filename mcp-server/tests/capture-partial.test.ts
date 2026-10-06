// Verify the partial-result 504 path: when Design Canvas hits its 180s budget,
// it returns 504 with what completed plus { error, captured, total, unsettled }.
// The MCP tool surfaces that as a diagnostic message and any partial images,
// instead of the older misleading "too many routes" sentence.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { createServer, type Server } from "node:http";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import sharp from "sharp";

let server: Server;
let port = 0;
let fakeJpegPath = "";

before(async () => {
  // 1×1 white JPEG so the image-encoding loop in tools.ts has a real file to read.
  const tmp = mkdtempSync(join(tmpdir(), "dc-partial-"));
  fakeJpegPath = join(tmp, "partial.jpg");
  const jpegBuffer = await sharp({
    create: { width: 1, height: 1, channels: 3, background: { r: 255, g: 255, b: 255 } },
  })
    .jpeg()
    .toBuffer();
  writeFileSync(fakeJpegPath, jpegBuffer);

  server = createServer((req, res) => {
    if (req.method === "POST" && req.url === "/capture") {
      res.statusCode = 504;
      res.statusMessage = "Gateway Timeout";
      res.setHeader("Content-Type", "application/json");
      res.end(
        JSON.stringify({
          error: "Capture timed out",
          captured: 1,
          total: 3,
          unsettled: ["/login", "/dashboard"],
          screenshots: [{ path: "/", filePath: fakeJpegPath }],
        }),
      );
      return;
    }
    res.statusCode = 404;
    res.end("not found");
  });
  await new Promise<void>((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (typeof addr === "object" && addr) {
        port = addr.port;
      }
      resolve();
    });
  });
});

after(() => {
  server?.close();
});

test("capture_canvas surfaces partial 504 with diagnostic + image", async () => {
  // getBaseUrl() reads this lazily each request, so flipping it just-in-time works
  // even though ghost.test.ts pinned it earlier in the same process.
  process.env.DESIGN_CANVAS_URL = `http://127.0.0.1:${port}`;
  const { handleCaptureCanvas } = await import("../src/tools.js");

  const result = await handleCaptureCanvas({});

  assert.equal(result.isError, true, "partial 504 should be flagged as error");

  const texts = result.content
    .filter((c) => c.type === "text")
    .map((c) => ("text" in c ? c.text : ""));
  const allText = texts.join(" | ");
  assert.match(allText, /timed out/i, "diagnostic should mention timeout");
  assert.match(allText, /1\/3/, "diagnostic should include captured/total counts");
  assert.match(allText, /\/login/, "diagnostic should name unsettled routes");

  const images = result.content.filter((c) => c.type === "image");
  assert.equal(images.length, 1, "should render the one partial screenshot");
});

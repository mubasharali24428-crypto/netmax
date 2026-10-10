import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const desktop = dirname(fileURLToPath(import.meta.url));
const serverPath = join(desktop, "netmax-mcp-server.mjs");
const enginePath = join(desktop, "engine", "netmax.py");

test("download_file validates basenames before spawning and uses the private CLI mode", async (t) => {
  const work = await mkdtemp(join(tmpdir(), "netmax-mcp-boundary-"));
  const marker = join(work, "argv.json");
  const fakePython = join(work, "fake-python");
  await writeFile(fakePython, [
    "#!/usr/bin/env node",
    "const fs = require('node:fs');",
    "fs.writeFileSync(process.env.NETMAX_TEST_ARGV_FILE, JSON.stringify(process.argv.slice(2)));",
    "process.stdout.write('FAKE_ENGINE_OK\\n');",
  ].join("\n"));
  await chmod(fakePython, 0o700);

  const client = new Client({ name: "netmax-boundary-test", version: "1.0.0" });
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverPath],
    cwd: desktop,
    env: { ...process.env, NETMAX_PYTHON: fakePython, NETMAX_TEST_ARGV_FILE: marker },
    stderr: "pipe",
  });
  await client.connect(transport);
  t.after(async () => {
    await client.close().catch(() => {});
    await rm(work, { recursive: true, force: true });
  });

  const invalidNames = [
    "", ".", "..", "../escape", "/tmp/escape", "a/b", "a\\b", "C:escape",
    "C:/a.json", "\\\\?\\C:\\evil", "\\\\server\\share",
    "bad\0name", "bad\nname", "x".repeat(181), "é".repeat(91),
  ];
  for (const output of invalidNames) {
    const result = await client.callTool({
      name: "download_file",
      arguments: { url: "https://example.test/file", streams: 2, output },
    });
    assert.equal(result.isError, true, `expected rejection for ${JSON.stringify(output)}`);
    assert.match(result.content[0].text, /basename/);
    assert.equal(existsSync(marker), false, "invalid names must not spawn the engine");
  }

  const explicitName = "é".repeat(90);
  const explicit = await client.callTool({
    name: "download_file",
    arguments: { url: "https://example.test/file", streams: 2, output: explicitName },
  });
  assert.equal(explicit.isError, undefined);
  assert.deepEqual(JSON.parse(await readFile(marker, "utf8")), [
    "-B", enginePath, "fetch", "https://example.test/file",
    "--mcp-output-name", explicitName, "--streams", "2",
  ]);

  const derived = await client.callTool({
    name: "download_file",
    arguments: { url: "https://example.test/files/report.bin", streams: 1 },
  });
  assert.equal(derived.isError, undefined);
  assert.deepEqual(JSON.parse(await readFile(marker, "utf8")), [
    "-B", enginePath, "fetch", "https://example.test/files/report.bin",
    "--mcp-output-name", "report.bin", "--streams", "1",
  ]);

  const fallback = await client.callTool({
    name: "download_file",
    arguments: { url: "https://example.test/files/", streams: 1 },
  });
  assert.equal(fallback.isError, undefined);
  assert.deepEqual(JSON.parse(await readFile(marker, "utf8")), [
    "-B", enginePath, "fetch", "https://example.test/files/",
    "--mcp-output-name", "download", "--streams", "1",
  ]);
});

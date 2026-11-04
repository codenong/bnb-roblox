#!/usr/bin/env node
// Verify prepared assets, manifest metadata, and the Studio ID template.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const PREPARED = path.join(ROOT, "assets", "prepared");
const MANIFEST = path.join(PREPARED, "manifest.json");
const STUDIO = path.join(ROOT, "tools", "studio_asset_ids.json");

function fail(message) {
  console.error(`FAIL ${message}`);
  process.exitCode = 1;
}

function pngSize(file) {
  const buffer = fs.readFileSync(file);
  if (buffer.subarray(0, 8).toString("hex") !== "89504e470d0a1a0a") return null;
  if (buffer.subarray(12, 16).toString("ascii") !== "IHDR") return null;
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
}

if (!fs.existsSync(MANIFEST)) {
  console.error("missing assets/prepared/manifest.json; run tools/prepare_assets.py");
  process.exit(1);
}
const manifest = JSON.parse(fs.readFileSync(MANIFEST, "utf8"));
const imageEntries = Object.entries(manifest.images ?? {});
const audioEntries = Object.entries(manifest.audio ?? {});

for (const [key, entry] of imageEntries) {
  const file = path.join(PREPARED, entry.file);
  if (!fs.existsSync(file)) {
    fail(`${key}: missing ${entry.file}`);
    continue;
  }
  const size = pngSize(file);
  if (!size) {
    fail(`${key}: not a PNG`);
    continue;
  }
  if (size.width !== entry.width || size.height !== entry.height) {
    fail(`${key}: ${size.width}x${size.height} != manifest ${entry.width}x${entry.height}`);
  }
  if (Math.max(size.width, size.height) > 1024) {
    fail(`${key}: exceeds Roblox 1024 px limit`);
  }
  const cols = entry.cols ?? 1;
  const rows = entry.rows ?? 1;
  const fw = entry.frameWidth ?? 0;
  const fh = entry.frameHeight ?? 0;
  if (cols > 1 && (size.width % cols !== 0 || size.width / cols !== fw)) {
    fail(`${key}: frame width ${fw} does not divide ${size.width} / ${cols}`);
  }
  if (rows > 1 && (size.height % rows !== 0 || size.height / rows !== fh)) {
    fail(`${key}: frame height ${fh} does not divide ${size.height} / ${rows}`);
  }
}

for (const [key, entry] of audioEntries) {
  const file = path.join(PREPARED, entry.file);
  if (!fs.existsSync(file)) {
    fail(`${key}: missing ${entry.file}`);
    continue;
  }
  const buffer = fs.readFileSync(file);
  if (buffer.subarray(0, 4).toString("ascii") !== "OggS") {
    fail(`${key}: not an OGG file`);
  }
}

const studio = JSON.parse(fs.readFileSync(STUDIO, "utf8"));
for (const key of [...Object.keys(manifest.images ?? {}), ...Object.keys(manifest.audio ?? {})]) {
  if (!(key in studio)) fail(`studio_asset_ids.json missing ${key}`);
}

if (!process.exitCode) {
  console.log(`OK ${imageEntries.length} images, ${audioEntries.length} audio files`);
}

#!/usr/bin/env node
// Upload prepared BnB assets through the Roblox Open Cloud Assets API.
//
// Required environment:
//   ROBLOX_API_KEY        API key with asset:read + asset:write
//   ROBLOX_CREATOR_TYPE   user | group (default: user)
//   ROBLOX_CREATOR_ID     user ID or group ID
//
// Usage:
//   node tools/upload_assets.mjs --dry-run
//   node tools/upload_assets.mjs --images-only
//   node tools/upload_assets.mjs --audio-only
//   node tools/upload_assets.mjs --only=img_box,sfx_explode
//   node tools/upload_assets.mjs --force
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const MANIFEST = path.join(ROOT, "assets", "prepared", "manifest.json");
const CACHE_DIR = path.join(ROOT, "assets", ".cache");
const CACHE = path.join(CACHE_DIR, "upload-cache.json");
const GEN = path.join(ROOT, "tools", "gen_asset_ids.mjs");
const API = "https://apis.roblox.com/assets/v1";
const AUDIO_ORDER = [
  "sfx_explode",
  "sfx_bomb_set",
  "sfx_get",
  "sfx_role_die",
  "sfx_start",
  "sfx_save",
  "sfx_lose",
  "sfx_draw",
  "sfx_victory",
  "bgm_game",
  "bgm_lobby",
  "bgm_login",
];

const argv = process.argv.slice(2);
const dryRun = argv.includes("--dry-run");
const force = argv.includes("--force");
const imagesOnly = argv.includes("--images-only");
const audioOnly = argv.includes("--audio-only");
const onlyArg = argv.find((arg) => arg.startsWith("--only="));
const only = onlyArg
  ? new Set(onlyArg.slice("--only=".length).split(",").map((s) => s.trim()).filter(Boolean))
  : null;

function die(message) {
  console.error(message);
  process.exit(1);
}

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}

function writeCache(cache) {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  fs.writeFileSync(CACHE, JSON.stringify(cache, null, 2) + "\n");
}

function sha256(buffer) {
  return crypto.createHash("sha256").update(buffer).digest("hex");
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function creatorKey() {
  const type = (process.env.ROBLOX_CREATOR_TYPE || "user").toLowerCase();
  const id = (process.env.ROBLOX_CREATOR_ID || "").trim();
  if (type !== "user" && type !== "group") die("ROBLOX_CREATOR_TYPE must be user or group");
  if (!/^\d+$/.test(id)) die("ROBLOX_CREATOR_ID must be a numeric user/group ID");
  return { type, id, key: `${type}:${id}` };
}

function creatorBody(creator) {
  return creator.type === "group"
    ? { creator: { groupId: creator.id } }
    : { creator: { userId: creator.id } };
}

const manifest = readJson(MANIFEST, null);
if (!manifest) die("missing assets/prepared/manifest.json; run tools/prepare_assets.py");

const allEntries = [];
for (const [key, entry] of Object.entries(manifest.images ?? {})) {
  allEntries.push({ key, ...entry, kind: "image" });
}
const audioEntries = Object.entries(manifest.audio ?? {}).map(([key, entry]) => ({
  key,
  ...entry,
  kind: "audio",
}));
audioEntries.sort((a, b) => {
  const ai = AUDIO_ORDER.indexOf(a.key);
  const bi = AUDIO_ORDER.indexOf(b.key);
  return (ai < 0 ? 999 : ai) - (bi < 0 ? 999 : bi);
});
allEntries.push(...audioEntries);

function selectedEntries() {
  return allEntries.filter((entry) => {
    if (imagesOnly && entry.kind !== "image") return false;
    if (audioOnly && entry.kind !== "audio") return false;
    if (only && !only.has(entry.key)) return false;
    return true;
  });
}

function operationUrl(operation) {
  const raw = operation.path || operation.operationId;
  if (!raw) return null;
  if (/^https?:\/\//.test(raw)) return raw;
  if (raw.startsWith("/")) return `https://apis.roblox.com${raw}`;
  if (raw.startsWith("assets/v1/")) return `https://apis.roblox.com/${raw}`;
  if (raw.startsWith("operations/")) return `${API}/${raw}`;
  return `${API}/operations/${raw}`;
}

async function apiFetch(url, options, retries = 5) {
  for (let attempt = 0; attempt <= retries; attempt++) {
    const response = await fetch(url, options);
    if (response.status !== 429 || attempt === retries) return response;
    const retryAfter = Number(response.headers.get("retry-after"));
    const waitMs = Number.isFinite(retryAfter) && retryAfter > 0
      ? retryAfter * 1000
      : 2000 * 2 ** attempt;
    console.warn(`rate limited; retrying in ${Math.round(waitMs / 1000)}s`);
    await sleep(waitMs);
  }
  throw new Error("unreachable");
}

async function uploadOne(entry, creator, apiKey) {
  const file = path.join(ROOT, "assets", "prepared", entry.file);
  const bytes = fs.readFileSync(file);
  const digest = sha256(bytes);
  const mime = entry.kind === "image" ? "image/png" : "audio/ogg";

  const request = {
    assetType: entry.assetType,
    displayName: entry.displayName || entry.key,
    description: "BnB Roblox port",
    creationContext: creatorBody(creator),
  };

  const form = new FormData();
  form.append(
    "request",
    new Blob([JSON.stringify(request)], { type: "application/json" }),
    "request.json",
  );
  form.append(
    "fileContent",
    new Blob([bytes], { type: mime }),
    path.basename(entry.file),
  );

  const response = await apiFetch(`${API}/assets`, {
    method: "POST",
    headers: { "x-api-key": apiKey },
    body: form,
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`HTTP ${response.status} for ${entry.key}: ${text}`);
  }
  let operation = JSON.parse(text);
  const url = operationUrl(operation);
  if (!url) throw new Error(`no operation path for ${entry.key}: ${text}`);

  for (let i = 0; i < 450; i++) {
    if (operation.done) {
      const assetId =
        operation.response?.assetId ??
        operation.response?.asset?.id ??
        operation.assetId;
      const moderation = operation.response?.moderationResult?.moderationState ??
        operation.response?.moderationState;
      if (moderation === "Rejected") {
        throw new Error(`${entry.key} rejected by moderation: ${text}`);
      }
      if (!assetId) throw new Error(`${entry.key} finished without assetId: ${text}`);
      return { assetId: String(assetId), status: moderation || "Ready", sha256: digest };
    }
    await sleep(2000);
    const poll = await apiFetch(url, { headers: { "x-api-key": apiKey } });
    const pollText = await poll.text();
    if (!poll.ok) throw new Error(`poll HTTP ${poll.status} for ${entry.key}: ${pollText}`);
    operation = JSON.parse(pollText);
  }
  throw new Error(`timed out uploading ${entry.key}`);
}

async function main() {
  const envCreator = (process.env.ROBLOX_CREATOR_ID || "").trim()
    ? creatorKey()
    : null;
  if (!dryRun && !envCreator) die("ROBLOX_CREATOR_ID is not set");
  const creator = envCreator ?? { type: "user", id: "0", key: "" };
  const cache = readJson(CACHE, {});
  const entries = selectedEntries();

  const todo = [];
  for (const entry of entries) {
    const file = path.join(ROOT, "assets", "prepared", entry.file);
    if (!fs.existsSync(file)) die(`missing prepared file: ${entry.file}`);
    const digest = sha256(fs.readFileSync(file));
    const cached = cache[entry.key];
    const reusable = !force &&
      creator.key !== "" &&
      cached &&
      cached.sha256 === digest &&
      cached.creator === creator.key &&
      cached.status !== "Rejected" &&
      cached.assetId;
    if (reusable) {
      console.log(`cached  ${entry.key} -> ${cached.assetId}`);
      continue;
    }
    todo.push(entry);
  }

  console.log(`${todo.length} to upload, ${entries.length - todo.length} cached/skipped`);
  if (dryRun) {
    for (const entry of todo) console.log(`would upload ${entry.kind.padEnd(5)} ${entry.key}`);
    return;
  }
  if (!todo.length) {
    execFileSync(process.execPath, [GEN], { stdio: "inherit" });
    return;
  }

  const apiKey = process.env.ROBLOX_API_KEY;
  if (!apiKey) die("ROBLOX_API_KEY is not set");
  console.log(`creator ${creator.key}`);

  for (let i = 0; i < todo.length; i++) {
    const entry = todo[i];
    console.log(`[${i + 1}/${todo.length}] ${entry.key} ...`);
    const result = await uploadOne(entry, creator, apiKey);
    cache[entry.key] = {
      ...result,
      creator: creator.key,
      assetType: entry.assetType,
    };
    writeCache(cache);
    console.log(`          -> ${result.assetId} (${result.status})`);
  }

  execFileSync(process.execPath, [GEN], { stdio: "inherit" });
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});

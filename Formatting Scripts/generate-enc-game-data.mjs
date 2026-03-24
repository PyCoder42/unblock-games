#!/usr/bin/env node
/**
 * generate-enc-game-data.mjs
 *
 * Encrypts a game HTML file with AES-256-GCM and writes the encrypted payload
 * to a JSON file. The encryption key is stored in .game-keys (gitignored) and
 * reused on subsequent runs so the same game always has the same key.
 *
 * Usage:
 *   node generate-enc-game-data.mjs <game-html-path> <gameid> <output-enc-json-path>
 *
 * Prints the hex-encoded game key to stdout (for shell capture).
 * Writes .game-keys to the repo root alongside the script's parent directory.
 *
 * Output JSON format:
 *   { "iv": "<12-byte hex>", "authTag": "<16-byte hex>", "ciphertext": "<base64>" }
 */

import { readFileSync, writeFileSync, existsSync, mkdirSync } from 'fs';
import { randomBytes, createCipheriv } from 'crypto';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));

const args = process.argv.slice(2);
const [gameHtmlPath, gameId, outputPath] = args;

if (!gameHtmlPath || !gameId || !outputPath) {
  process.stderr.write(
    'Usage: node generate-enc-game-data.mjs <game-html-path> <gameid> <output-enc-json-path>\n'
  );
  process.exit(1);
}

// .game-keys lives in the repo root (parent of Formatting Scripts/)
const keysFile = resolve(__dirname, '..', '.game-keys');

// Load existing keys or start fresh
let keys = {};
if (existsSync(keysFile)) {
  try {
    keys = JSON.parse(readFileSync(keysFile, 'utf8'));
  } catch {
    keys = {};
  }
}

// Reuse existing key for this game, or generate a new one
let keyHex = keys[gameId];
if (!keyHex || !/^[0-9a-f]{64}$/.test(keyHex)) {
  keyHex = randomBytes(32).toString('hex');
  keys[gameId] = keyHex;
  writeFileSync(keysFile, JSON.stringify(keys, null, 2) + '\n');
}

// Encrypt
const keyBytes = Buffer.from(keyHex, 'hex');
const iv = randomBytes(12); // 96-bit IV for AES-GCM
const gameHtml = readFileSync(gameHtmlPath, 'utf8');

const cipher = createCipheriv('aes-256-gcm', keyBytes, iv);
const ciphertext = Buffer.concat([cipher.update(gameHtml, 'utf8'), cipher.final()]);
const authTag = cipher.getAuthTag(); // always 16 bytes for GCM

// Ensure output directory exists
const outputDir = dirname(resolve(outputPath));
if (!existsSync(outputDir)) mkdirSync(outputDir, { recursive: true });

// Write encrypted payload
writeFileSync(outputPath, JSON.stringify({
  iv: iv.toString('hex'),
  authTag: authTag.toString('hex'),
  ciphertext: ciphertext.toString('base64'),
}) + '\n');

// Print key hex to stdout for the calling shell script to capture
process.stdout.write(keyHex);

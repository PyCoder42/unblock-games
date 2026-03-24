#!/usr/bin/env node

import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  loadSyncSettings,
  syncRemoteConfig,
  trimString,
} from './remote-config-sync.mjs';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDir = path.dirname(scriptPath);
const repoRoot = path.dirname(scriptDir);

function printHelp() {
  console.log(`Usage: node "Formatting Scripts/sync-remote-config.mjs" [options]

Syncs the merged remote config between GAS and jsDelivr/GitHub.

Options:
  --dry-run           Read and merge only; do not write anything
  --no-local          Do not update the local config.json file
  --gas-url URL       Override GAS_URL
  --gas-secret VALUE  Override GAS_SECRET
  --jsdelivr-url URL  Override JSDELIVR_URL
  --github-repo REPO  Override GITHUB_REPO
  --github-pat TOKEN  Override GITHUB_PAT
  --help              Show this help
`);
}

function parseArgs(argv) {
  const options = {
    dryRun: false,
    noLocal: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--dry-run') {
      options.dryRun = true;
    } else if (arg === '--no-local') {
      options.noLocal = true;
    } else if (arg === '--gas-url') {
      options.gasUrl = argv[++i] || '';
    } else if (arg === '--gas-secret') {
      options.gasSecret = argv[++i] || '';
    } else if (arg === '--jsdelivr-url') {
      options.jsdelivrUrl = argv[++i] || '';
    } else if (arg === '--github-repo') {
      options.githubRepo = argv[++i] || '';
    } else if (arg === '--github-pat') {
      options.githubPat = argv[++i] || '';
    } else if (arg === '--help' || arg === '-h') {
      options.help = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return options;
}

function formatWriteStatus(name, result) {
  if (!result.attempted) {
    return `${name}: skipped (${result.reason || 'not attempted'})`;
  }
  if (result.ok) {
    return `${name}: ok`;
  }
  return `${name}: failed${result.reason ? ` (${result.reason})` : ''}`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }

  const settings = await loadSyncSettings({ cwd: repoRoot });
  const options = {
    dryRun: args.dryRun,
    gasUrl: trimString(args.gasUrl || settings.gasUrl),
    gasSecret: trimString(args.gasSecret || settings.gasSecret),
    jsdelivrUrl: trimString(args.jsdelivrUrl || settings.jsdelivrUrl),
    githubRepo: trimString(args.githubRepo || settings.githubRepo),
    githubPat: trimString(args.githubPat || settings.githubPat),
    localConfigPath: args.noLocal ? '' : settings.localConfigPath,
  };

  const result = await syncRemoteConfig(options);

  console.log(`Merged passwords: ${result.mergedConfig.passwords.length}`);
  console.log(`Merged games: ${result.mergedConfig.games.length}`);
  console.log(`Merged allowed IPs: ${Object.keys(result.mergedConfig.allowedIps).length}`);
  console.log(`Read GAS: ${result.reads.gas.ok ? 'ok' : 'failed'}`);
  console.log(`Read jsDelivr: ${result.reads.jsdelivr.ok ? 'ok' : 'failed'}`);
  console.log(formatWriteStatus('Write GAS', result.writes.gas));
  console.log(formatWriteStatus('Write GitHub', result.writes.github));
  console.log(formatWriteStatus('Purge jsDelivr', result.writes.jsdelivr));
  console.log(formatWriteStatus('Write local config.json', result.writes.local));
}

main().catch((error) => {
  console.error(error && error.message ? error.message : String(error));
  process.exitCode = 1;
});

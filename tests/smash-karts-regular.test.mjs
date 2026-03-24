import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import test from 'node:test';

const repoRoot = '/Users/saahir/Desktop/Unblock Games';
const smashKartsRegularFiles = [
  path.join(repoRoot, 'Games', 'Smash Karts', 'smash-karts-regular.html'),
  path.join(repoRoot, 'Admin Panel', 'Smash Karts', 'smash-karts-regular.html'),
];

test('Smash Karts installs blob URL rewrites inside the rewritten document', () => {
  for (const filePath of smashKartsRegularFiles) {
    assert.ok(existsSync(filePath), `expected Smash Karts regular file at ${filePath}`);

    const source = readFileSync(filePath, 'utf8');
    const startGameIndex = source.indexOf('function startGame()');
    const writeIndex = source.indexOf('document.write(INNER_DOCUMENT_HTML);');
    assert.notEqual(startGameIndex, -1, `missing startGame() in ${filePath}`);
    assert.notEqual(writeIndex, -1, `missing document.write handoff in ${filePath}`);

    const outerBootstrap = source.slice(startGameIndex, writeIndex);

    assert.doesNotMatch(outerBootstrap, /document\.createElement\s*=\s*function/);
    assert.doesNotMatch(outerBootstrap, /Element\.prototype\.setAttribute\s*=\s*function/);
    assert.doesNotMatch(outerBootstrap, /Object\.defineProperty\(Image\.prototype,\s*['"]src['"]/);
    assert.doesNotMatch(outerBootstrap, /window\.fetch\s*=\s*function/);
    assert.doesNotMatch(outerBootstrap, /XMLHttpRequest\.prototype\.open\s*=\s*function/);
    assert.doesNotMatch(outerBootstrap, /window\.Audio\s*=\s*function/);

    const innerPatchMarker = source.indexOf('Install asset rewrites in the new document context.');
    const constantsScript = source.indexOf('scripts/constants.js');
    assert.notEqual(innerPatchMarker, -1, `missing inner patch marker in ${filePath}`);
    assert.notEqual(constantsScript, -1, `missing constants script in ${filePath}`);
    assert.ok(innerPatchMarker < constantsScript, `inner patch bootstrap should run before constants.js in ${filePath}`);
  }
});

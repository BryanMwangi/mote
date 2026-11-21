#!/usr/bin/env node
// Brings uBlock Origin's scriptlets (https://github.com/gorhill/uBlock,
// GPL-3.0) into Mote/Resources/Scripts/ublock-scriptlets.json:
// each one's code with its helpers', its world and its aliases, for the
// filter lists' `##+js(...)` rules (see AdBlocker.swift). From its newest
// tag; with no network the copy already there stays.
//
//   node Tools/ublock/sync.mjs [TAG]
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repo = 'https://github.com/gorhill/uBlock';
const out = join(dirname(fileURLToPath(import.meta.url)), '../../Mote/Resources/Scripts/ublock-scriptlets.json');

const newestTag = () => {
    const refs = execFileSync('git', ['ls-remote', '--tags', '--refs', repo], { encoding: 'utf8', timeout: 30000 });
    const tags = refs.split('\n').map(line => line.split('refs/tags/')[1]).filter(tag => /^\d+\.\d+\.\d+/.test(tag ?? ''));
    const key = tag => tag.split(/[.b]|rc/).map(Number);
    return tags.sort((a, b) => {
        const [x, y] = [key(a), key(b)];
        for (let i = 0; i < Math.max(x.length, y.length); i++) {
            // A release sorts after its betas: 1.2.3 > 1.2.3b9.
            const d = (x[i] ?? Infinity) - (y[i] ?? Infinity);
            if (d) return d;
        }
        return 0;
    }).at(-1);
};

let tag;
try {
    tag = process.argv[2] ?? newestTag();
} catch (error) {
    console.warn(`ublock: can't reach ${repo} (${error.message.split('\n')[0]}); keeping the copy there`);
    process.exit(existsSync(out) ? 0 : 1);
}
const kept = existsSync(out) ? JSON.parse(readFileSync(out, 'utf8')) : null;
if (kept?.version === tag && kept.format === 1) {
    console.log(`ublock: scriptlets already from ${tag}`);
    process.exit(0);
}

const work = mkdtempSync(join(tmpdir(), 'mote-ublock-'));
try {
    execFileSync('git', ['-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1', '--branch', tag, '--filter=blob:none', '--sparse', repo, work], { timeout: 120000 });
    execFileSync('git', ['-C', work, 'sparse-checkout', 'set', 'src/js/resources'], { timeout: 120000 });
    const { builtinScriptlets } = await import(pathToFileURL(join(work, 'src/js/resources/scriptlets.js')).href);
    const scriptlets = builtinScriptlets.map(entry => ({
        name: entry.name,
        ...(entry.aliases?.length ? { aliases: entry.aliases } : {}),
        ...(entry.world === 'ISOLATED' ? { isolated: true } : {}),
        ...(entry.requiresTrust ? { trusted: true } : {}),
        ...(entry.dependencies?.length ? { needs: entry.dependencies } : {}),
        // What a rule calls; a helper (`.fn`) is only another's dependency.
        ...(entry.name.endsWith('.js') ? { call: entry.fn.name } : {}),
        code: entry.fn.toString(),
    }));
    const doc = {
        about: `uBlock Origin's scriptlets, ${repo}, GPL-3.0. Made by Tools/ublock/sync.mjs; don't edit.`,
        version: tag,
        format: 1,
        scriptlets,
    };
    writeFileSync(out, JSON.stringify(doc, null, 1) + '\n');
    console.log(`ublock: ${scriptlets.length} scriptlets from ${tag}`);
} catch (error) {
    console.warn(`ublock: couldn't bring ${tag} (${error.message.split('\n')[0]}); keeping the copy there`);
    process.exitCode = existsSync(out) ? 0 : 1;
} finally {
    rmSync(work, { recursive: true, force: true });
}

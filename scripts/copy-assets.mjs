#!/usr/bin/env node
// Copy non-TypeScript assets into the extension build output and compile them:
//   - metadata.json
//   - GSettings schema(s) + glib-compile-schemas
//   - gettext .po translations -> locale/<lang>/LC_MESSAGES/<domain>.mo
//
// `tsc` has already emitted extension.js / prefs.js into dist/<uuid>/.
// Missing GNOME build tools (glib-compile-schemas / msgfmt) only warn — the
// packaged zip is compiled again by `gnome-extensions pack`, and translations
// gracefully fall back to the English source strings.

import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))
const uuid = pkg.config?.uuid
if (!uuid) {
  console.error('copy-assets: package.json "config.uuid" is missing')
  process.exit(1)
}

const srcDir = path.join(root, 'gnome-extension')
const outDir = path.join(srcDir, 'dist', uuid)

if (!fs.existsSync(outDir)) {
  console.error(`copy-assets: build output "${outDir}" not found — run the TypeScript build first`)
  process.exit(1)
}

/** Run a command; return true on success, false if the tool is missing/failed. */
function run(cmd, args, { optional = false } = {}) {
  const res = spawnSync(cmd, args, { stdio: ['ignore', 'ignore', 'inherit'] })
  if (res.error?.code === 'ENOENT') {
    const msg = `copy-assets: "${cmd}" not found`
    if (optional) {
      console.warn(`${msg} — skipping (this step will be handled at package time)`)
      return false
    }
    console.error(msg)
    process.exit(1)
  }
  if (res.status !== 0) {
    console.error(`copy-assets: "${cmd} ${args.join(' ')}" exited with ${res.status}`)
    process.exit(1)
  }
  return true
}

// --- metadata.json ---
fs.copyFileSync(path.join(srcDir, 'metadata.json'), path.join(outDir, 'metadata.json'))

// --- GSettings schema(s) ---
const schemaSrc = path.join(srcDir, 'schemas')
if (fs.existsSync(schemaSrc)) {
  const schemaOut = path.join(outDir, 'schemas')
  fs.mkdirSync(schemaOut, { recursive: true })
  for (const file of fs.readdirSync(schemaSrc)) {
    if (file.endsWith('.gschema.xml'))
      fs.copyFileSync(path.join(schemaSrc, file), path.join(schemaOut, file))
  }
  run('glib-compile-schemas', [schemaOut], { optional: true })
}

// --- translations ---
const poDir = path.join(srcDir, 'po')
if (fs.existsSync(poDir)) {
  for (const file of fs.readdirSync(poDir)) {
    if (!file.endsWith('.po'))
      continue
    const lang = path.basename(file, '.po')
    const moDir = path.join(outDir, 'locale', lang, 'LC_MESSAGES')
    fs.mkdirSync(moDir, { recursive: true })
    run('msgfmt', [path.join(poDir, file), '-o', path.join(moDir, `${uuid}.mo`)], {
      optional: true,
    })
  }
}

console.log(`copy-assets: assets copied into ${path.relative(root, outDir)}`)

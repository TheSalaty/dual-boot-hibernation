#!/usr/bin/env node
// Package the built extension into a self-contained, installable zip.
//
// The zip's root is the *contents* of dist/<uuid>/ (metadata.json at top level),
// which is exactly what `gnome-extensions install <zip>` expects. Unlike
// `gnome-extensions pack`, this needs no gnome-shell on the machine, so it runs
// identically on a dev box and in CI. The bundle already contains the compiled
// schema and translations produced by the build step.

import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'))
const uuid = pkg.config?.uuid
if (!uuid) {
  console.error('pack: package.json "config.uuid" is missing')
  process.exit(1)
}

const distDir = path.join(root, 'gnome-extension', 'dist', uuid)
if (!fs.existsSync(path.join(distDir, 'metadata.json'))) {
  console.error(`pack: "${distDir}" has no metadata.json — run the build first`)
  process.exit(1)
}

const outZip = path.join(root, `${uuid}.shell-extension.zip`)
fs.rmSync(outZip, { force: true })

const res = spawnSync('zip', ['-r', '-q', '-X', outZip, '.'], { cwd: distDir, stdio: 'inherit' })
if (res.error?.code === 'ENOENT') {
  console.error('pack: "zip" not found — install it (e.g. `pacman -S zip` / `apt install zip`)')
  process.exit(1)
}
if (res.status !== 0) {
  console.error(`pack: zip exited with ${res.status}`)
  process.exit(1)
}

console.log(`pack: created ${path.relative(root, outZip)}`)

#!/usr/bin/env node

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { basename, extname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const repositoryRoot = resolve(fileURLToPath(new URL('..', import.meta.url)))
const defaultTargets = [
  join(repositoryRoot, 'docs', 'assets'),
  join(
    repositoryRoot,
    'apps',
    'x-macos',
    'Sources',
    'XMac',
    'Assets.xcassets',
    'AppIcon.appiconset',
    'OpenFish-1024.png',
  ),
]
const requestedTargets = process.argv.slice(2).map((value) => resolve(value))
const targets = requestedTargets.length > 0 ? requestedTargets : defaultTargets
const supportedExtensions = new Set(['.png', '.jpg', '.jpeg'])
const findings = []

function displayPath(file) {
  const value = relative(repositoryRoot, file)
  return value.startsWith('..') ? `external/${basename(file)}` : value
}

function collect(target, output) {
  if (!existsSync(target)) {
    report(target, 'required public asset path is missing')
    return
  }
  const info = statSync(target)
  if (info.isDirectory()) {
    for (const child of readdirSync(target).sort()) collect(join(target, child), output)
    return
  }
  if (info.isFile() && supportedExtensions.has(extname(target).toLowerCase())) output.push(target)
}

function report(file, rule) {
  findings.push(`${displayPath(file)}: ${rule}`)
}

function inspectVisibleStrings(file, data) {
  // Latin-1 is lossless for the byte range. Only the rule and file path are
  // reported; a potentially private matching value is never printed.
  const text = data.toString('latin1')
  const rules = [
    ['developer home path', /(?:file:\/\/\/)?\/Users\/[A-Za-z0-9._-]+\//i],
    ['email address', /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i],
    ['local hostname', /\b[A-Z0-9][A-Z0-9.-]*\.local\b/i],
    ['private IPv4 address', /\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})\b/],
    ['credential-like value', /(?:\bAKIA[0-9A-Z]{16}\b|\bgh[pousr]_[A-Za-z0-9]{36,}\b|\bsk-[A-Za-z0-9_-]{20,}\b|\bxox[baprs]-[A-Za-z0-9-]{20,}\b|-----BEGIN (?:[A-Z0-9 ]+ )?PRIVATE KEY-----)/],
  ]
  for (const [rule, expression] of rules) if (expression.test(text)) report(file, rule)
}

function inspectPng(file, data) {
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  if (data.length < signature.length || !data.subarray(0, 8).equals(signature)) {
    report(file, 'invalid PNG signature')
    return
  }

  const privateMetadataChunks = new Set(['tEXt', 'zTXt', 'iTXt', 'eXIf', 'tIME'])
  let offset = 8
  let foundEnd = false
  while (offset + 12 <= data.length) {
    const length = data.readUInt32BE(offset)
    const type = data.toString('ascii', offset + 4, offset + 8)
    const next = offset + 12 + length
    if (next > data.length) {
      report(file, 'truncated PNG chunk')
      return
    }
    if (privateMetadataChunks.has(type)) report(file, `embedded PNG metadata (${type})`)
    offset = next
    if (type === 'IEND') {
      foundEnd = true
      break
    }
  }
  if (!foundEnd) report(file, 'missing PNG end marker')
}

function inspectJpeg(file, data) {
  if (data.length < 4 || data[0] !== 0xff || data[1] !== 0xd8) {
    report(file, 'invalid JPEG signature')
    return
  }
  let offset = 2
  while (offset + 4 <= data.length) {
    if (data[offset] !== 0xff) {
      report(file, 'malformed JPEG segment')
      return
    }
    while (offset < data.length && data[offset] === 0xff) offset += 1
    const marker = data[offset]
    offset += 1
    if (marker === 0xda || marker === 0xd9) return
    if (marker >= 0xd0 && marker <= 0xd7) continue
    if (offset + 2 > data.length) break
    const length = data.readUInt16BE(offset)
    if (length < 2 || offset + length > data.length) {
      report(file, 'truncated JPEG segment')
      return
    }
    if (marker === 0xe1) report(file, 'embedded JPEG EXIF/XMP metadata')
    if (marker === 0xed) report(file, 'embedded JPEG IPTC metadata')
    if (marker === 0xfe) report(file, 'embedded JPEG comment')
    offset += length
  }
}

const files = []
for (const target of targets) collect(target, files)
if (files.length === 0) {
  for (const finding of [...new Set(findings)].sort()) console.error(finding)
  console.error('check_openfish_public_assets: no public image assets were found')
  process.exit(1)
}

for (const file of files) {
  const data = readFileSync(file)
  if (extname(file).toLowerCase() === '.png') inspectPng(file, data)
  else inspectJpeg(file, data)
  inspectVisibleStrings(file, data)
}

if (findings.length > 0) {
  for (const finding of [...new Set(findings)].sort()) console.error(finding)
  console.error('check_openfish_public_assets: public image privacy checks failed')
  process.exit(1)
}

console.log(`Public image metadata checks passed (${files.length} assets)`)

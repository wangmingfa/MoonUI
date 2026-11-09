#!/usr/bin/env node
// T235 P4：把 canvas-pixel 自检可执行自己的 dylib 依赖统一成"真身文件名"。
//
// 链接器给可执行记的是"我找到的那个文件名"（-lcairo 找到的是别名 libcairo.dylib），
// 而 dylib 之间记的是真实文件名；两条路径指同一个文件时 dyld 会当成两份加载
// （objc 会抱怨 class 重复实现）。这里把可执行自己的依赖也统一成真实文件名，
// 然后重签名（改过 load command 之后原签名失效）。
//
// 用法：node scripts/fix-dylib-aliases.js <可执行文件> <私有 runtime 目录>
// 由 scripts/canvas-pixel-check.sh 调用；旧版是那段 python3 heredoc，2026-11-09
// 逐行迁成 Node（零新增依赖）。

'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

function run(cmd) {
  return spawnSync(cmd[0], cmd.slice(1), { encoding: 'utf8' });
}

function main() {
  const binPath = process.argv[2];
  const runDir = process.argv[3];
  if (!binPath || !runDir) {
    process.stderr.write('用法：node scripts/fix-dylib-aliases.js <可执行文件> <runtime 目录>\n');
    return 2;
  }

  const alias = new Map();
  for (const f of fs.readdirSync(runDir)) {
    const p = path.join(runDir, f);
    if (fs.lstatSync(p).isSymbolicLink()) {
      alias.set(f, path.basename(fs.realpathSync(p)));
    }
  }

  const out = run(['otool', '-L', binPath]).stdout || '';
  const deps = out.split('\n').slice(1)
    .map((line) => line.trim().split(' (')[0])
    .filter((line) => line !== '');
  for (const dep of deps) {
    const base = path.basename(dep);
    if (alias.has(base)) {
      run(['install_name_tool', '-change', dep, '@loader_path/' + alias.get(base), binPath]);
    }
  }
  run(['codesign', '--force', '--sign', '-', binPath]);
  return 0;
}

process.exit(main());

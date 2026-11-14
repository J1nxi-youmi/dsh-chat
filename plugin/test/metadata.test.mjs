/**
 * 插件「门面」自检：DSH 插件页上的标题、描述、介绍页和图标。
 *
 * 插件改了、版本变了，这些展示资源经常忘了同步；这个测试让 CI 直接卡住：
 *
 * - locale/zh.json、locale/en.json 有 meta.title / meta.description；
 * - 声明了 meta.detail 就必须有那个文件，且在包内；
 * - 图标存在、格式对、不超过 256 KiB；
 * - 这些文件都被 package.json 的 files 覆盖（否则打出来的 tgz 里没有）；
 * - CHANGELOG 顶部版本 == package.json 版本（改版本就得写一句改了啥）。
 *
 * 跑法：node test/metadata.test.mjs
 */
import assert from 'node:assert/strict';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(fileURLToPath(new URL('..', import.meta.url)));
const pkg = JSON.parse(readFileSync(join(ROOT, 'package.json'), 'utf8'));
const readJson = (path) => JSON.parse(readFileSync(join(ROOT, path), 'utf8'));

/** package.json 的 files 里有没有覆盖到这个文件。 */
function packaged(file) {
  const entries = Array.isArray(pkg.files) ? pkg.files : [];
  const norm = file.replace(/\\/g, '/');
  return entries.some((entry) => {
    const item = String(entry).replace(/\\/g, '/');
    if (item === norm) return true;
    if (item.endsWith('*')) return norm.startsWith(item.replace(/\*+$/, ''));
    return norm.startsWith(`${item.replace(/\/$/, '')}/`);
  });
}

/** 图标必须是真的图片：SVG 看开头，PNG/JPEG/WebP 看magic。 */
function looksLikeImage(path) {
  const head = readFileSync(path).subarray(0, 64);
  const text = head.toString('utf8').trimStart();
  if (text.startsWith('<svg') || text.startsWith('<?xml')) return true;
  if (head[0] === 0x89 && head[1] === 0x50 && head[2] === 0x4e && head[3] === 0x47) return true;
  if (head[0] === 0xff && head[1] === 0xd8) return true;
  if (head.subarray(0, 4).toString('ascii') === 'RIFF') return true;
  return false;
}

// 1) 基础字段
{
  assert.ok(pkg.name, 'package.json 要有 name');
  assert.match(pkg.version, /^\d+\.\d+\.\d+$/, 'version 要是 x.y.z');
  assert.ok(pkg.description?.trim(), 'package.json 要有 description（没有 locale 时的兜底）');
  console.log(`✓ 基础字段（${pkg.name} v${pkg.version}）`);
}

// 2) 各语言的标题 / 描述
{
  for (const [locale, file] of [
    ['zh', 'locale/zh.json'],
    ['en', 'locale/en.json'],
  ]) {
    assert.ok(existsSync(join(ROOT, file)), `缺少 ${file}`);
    const meta = readJson(file).meta ?? {};
    assert.ok(String(meta.title ?? '').trim(), `${locale}: meta.title 不能为空`);
    assert.ok(String(meta.description ?? '').trim(), `${locale}: meta.description 不能为空`);
    assert.ok(String(meta.description).length >= 40, `${locale}: 描述太短，说不清插件做什么`);
    if (meta.detail) {
      const detail = String(meta.detail);
      assert.ok(detail.endsWith('.md') || detail.endsWith('.markdown'), `${locale}: meta.detail 要是 .md`);
      const abs = resolve(ROOT, detail);
      assert.ok(abs.startsWith(ROOT), `${locale}: meta.detail 必须留在包内`);
      assert.ok(existsSync(abs), `${locale}: meta.detail 指向的文件不存在：${detail}`);
      assert.ok(packaged(detail), `${locale}: meta.detail 没被 files 覆盖，打不进 tgz`);
    }
    assert.ok(packaged(file), `${locale}: ${file} 没被 files 覆盖，打不进 tgz`);
  }
  console.log('✓ 标题 / 描述 / 介绍页声明');
}

// 3) 图标
{
  const icon = pkg.icon ?? pkg.exports?.['./icon'];
  assert.ok(icon, '没有图标：package.json 的 icon 或 exports["./icon"] 要有值');
  const abs = resolve(ROOT, icon);
  assert.ok(abs.startsWith(ROOT + sep), '图标路径必须留在包内');
  assert.ok(existsSync(abs), `图标不存在：${icon}`);
  const size = statSync(abs).size;
  assert.ok(size <= 256 * 1024, `图标超过 256 KiB（${size} 字节）`);
  assert.ok(looksLikeImage(abs), '图标的字节不像 SVG / PNG / JPEG / WebP');
  assert.ok(packaged(relative(ROOT, abs).replace(/\\/g, '/')), '图标没被 files 覆盖，打不进 tgz');
  console.log(`✓ 图标（${icon}，${size} 字节）`);
}

// 4) 介绍页兜底：没有 meta.detail 时，DSH 显示 README
{
  const zh = readJson('locale/zh.json').meta ?? {};
  if (!zh.detail) {
    const readme = readFileSync(join(ROOT, 'README.md'), 'utf8');
    assert.ok(readme.trim().length > 200, '没有 meta.detail 时 README 就是介绍页，不能是空壳');
    console.log('✓ 介绍页走 README 兜底');
  }
}

// 5) CHANGELOG 顶部必须是当前版本（改版本就得写一句）
{
  const changelog = readFileSync(join(ROOT, 'CHANGELOG.md'), 'utf8');
  const top = /^##\s+v?(\d+\.\d+\.\d+)/m.exec(changelog)?.[1];
  assert.equal(top, pkg.version, `CHANGELOG 顶部版本是 ${top ?? '(没有)'}，和 package.json 的 ${pkg.version} 不一致`);
  console.log(`✓ CHANGELOG 顶部是 v${top}`);
}

console.log('\n全部通过（5 组）');

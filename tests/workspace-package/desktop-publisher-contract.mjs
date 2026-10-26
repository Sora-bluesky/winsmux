import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';

// Display metadata must not move the registry locations used by installed versions.
export function assertDesktopPublisherContract(repo, flavor) {
  const source = path.join(repo, 'winsmux-app/src-tauri');
  const config = JSON.parse(fs.readFileSync(path.join(source, 'tauri.conf.json'), 'utf8'));
  const publisher = config.bundle.publisher ?? config.identifier.split('.')[1];
  assert.equal(publisher, 'winsmux', 'Installed apps publisher must identify winsmux');
  assert.equal(config.bundle.publisher, 'winsmux', 'Publisher must be explicit');
  assert.equal(config.identifier, 'io.github.sora-bluesky.winsmux');
  assert.equal(config.productName, 'winsmux');
  const productKey = 'Software\\github\\winsmux';
  if (flavor === 'nsis') {
    const template = fs.readFileSync(path.join(source, 'nsis/installer.nsi'), 'utf8');
    const defines = new Map([...template.matchAll(/^!define (\w+) "([^"]*)"/gm)].map(m => [m[1], m[2]]));
    const expand = value => value.replace(/\$\{(\w+)\}/g, (_, key) => expand(defines.get(key) ?? key))
      .replaceAll('{{manufacturer}}', publisher).replaceAll('{{product_name}}', config.productName);
    assert.equal(expand(defines.get('MANUFACTURER')), publisher);
    assert.equal(expand(defines.get('MANUPRODUCTKEY')), productKey, 'NSIS must find the existing install directory and language');
    assert.equal(expand(defines.get('UNINSTKEY')), 'Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\winsmux');
    for (const operation of ['ReadRegStr $LANGUAGE HKCU "${MANUPRODUCTKEY}" "Installer Language"',
      'ReadRegStr $4 SHCTX "${MANUPRODUCTKEY}" ""']) assert.ok(template.includes(operation));
  } else {
    assert.equal(flavor, 'msi');
    const template = fs.readFileSync(path.join(source, 'wix/installer.wxs'), 'utf8');
    assert.ok(template.includes('Manufacturer="{{manufacturer}}"'));
    assert.ok(template.includes('UpgradeCode="{{upgrade_code}}"'));
    const productRows = [...template.matchAll(/<(RegistrySearch|RegistryValue|RegistryKey)\b[^>]*\bKey="([^"]+)"/g)]
      .filter(m => m[2].includes('{{product_name}}'));
    assert.equal(productRows.length, 6, 'Both prior-directory searches and all product registrations must be checked');
    for (const row of productRows) {
      assert.ok(row[0].includes('Root="HKCU"'), 'MSI must keep the current-user registry root');
      const key = row[2].replaceAll('{{manufacturer}}', publisher).replaceAll('{{product_name}}', config.productName);
      assert.equal(key.replaceAll('\\\\', '\\'), productKey, 'MSI must reuse the existing product key');
    }
    for (const name of ['PrevInstallDirNoName', 'PrevInstallDirWithName']) assert.ok(template.includes(`Id="${name}"`));
  }
}

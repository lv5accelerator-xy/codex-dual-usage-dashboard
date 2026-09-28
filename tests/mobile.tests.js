'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
vm.runInThisContext(fs.readFileSync(path.join(root, 'mobile', 'crypto.js'), 'utf8'), { filename: 'crypto.js' });
vm.runInThisContext(fs.readFileSync(path.join(root, 'mobile', 'model.js'), 'utf8'), { filename: 'model.js' });
const vector = JSON.parse(fs.readFileSync(path.join(__dirname, 'fixtures', 'mobile-crypto-vector.json'), 'utf8'));
let checks = 0;

function check(condition, message) {
  assert.ok(condition, message);
  checks += 1;
}

(async () => {
  check(await CodexCrypto.deriveUsageTopic(vector.pairKey) === vector.usageTopic, 'JS topic must equal the PowerShell vector.');
  check(await CodexCrypto.decryptRemoteMessage(vector.cipherText, vector.pairKey) === vector.plainText, 'JS must decrypt the PowerShell AES-CBC fixture.');

  await assert.rejects(() => CodexCrypto.decryptRemoteMessage(vector.cipherText, 'wrong-pair-key-12345'), { name: 'AuthenticationError' });
  checks += 1;
  const tampered = Buffer.from(vector.cipherText, 'base64');
  tampered[20] ^= 1;
  await assert.rejects(() => CodexCrypto.decryptRemoteMessage(tampered.toString('base64'), vector.pairKey), { name: 'AuthenticationError' });
  checks += 1;

  const snapshot = CodexMobileModel.validateSnapshot(JSON.parse(vector.plainText));
  check(snapshot.profiles.length === 1 && snapshot.profiles[0].fiveHour.remainingPercent === 82, 'Schema validator must preserve allowed quota data.');
  assert.throws(() => CodexMobileModel.validateSnapshot({ version: 1, type: 'usage_snapshot', publishedAt: 'bad', profiles: [] }), /格式/);
  checks += 1;
  assert.throws(() => CodexMobileModel.validateSnapshot({ ...JSON.parse(vector.plainText), profiles: [{ id: 'personal', ok: true, fiveHour: { kind: '5h', remainingPercent: 'NaN' } }] }), /百分比/);
  checks += 1;

  const stamp = Date.parse('2026-09-28T12:00:00Z');
  check(CodexMobileModel.getFreshness('2026-09-28T11:59:00Z', stamp).level === 'fresh', 'Under two minutes must be fresh.');
  check(CodexMobileModel.getFreshness('2026-09-28T11:55:00Z', stamp).level === 'aging', 'Two to ten minutes must be aging.');
  check(CodexMobileModel.getFreshness('2026-09-28T11:40:00Z', stamp).level === 'stale', 'Over ten minutes must be stale.');
  check(CodexMobileModel.getFreshness('2026-09-27T10:00:00Z', stamp).level === 'expired', 'Over 24 hours must be expired.');

  check(CodexMobileModel.formatCountdown('2026-09-28T14:14:00Z', stamp) === '2小时14分', 'Hour countdown must be local and exact to the minute.');
  check(CodexMobileModel.formatCountdown('2026-10-02T00:00:00Z', stamp) === '3天12小时', 'Multi-day countdown must show days and hours.');
  check(CodexMobileModel.formatCountdown('2026-09-28T11:59:00Z', stamp) === '等待电脑确认', 'Expired reset must wait for Windows confirmation.');

  check(CodexMobileModel.clampPercent(-4) === 0, 'Percent must clamp at zero.');
  check(CodexMobileModel.clampPercent(104) === 100, 'Percent must clamp at one hundred.');
  check(CodexMobileModel.clampPercent('invalid') === null, 'Invalid percentage must remain unknown.');
  check(CodexMobileModel.quotaTone(35, false) === 'warning' && CodexMobileModel.quotaTone(15, false) === 'danger', 'Mobile thresholds must match desktop 35/15 semantics.');
  check(CodexMobileModel.quotaTone(100, true) === 'muted', 'Stale values must be muted independently of percentage.');

  const serviceWorker = fs.readFileSync(path.join(root, 'mobile', 'sw.js'), 'utf8');
  check(!serviceWorker.includes('pairKey') && !serviceWorker.includes('usage_snapshot'), 'Service worker must not cache keys or decrypted snapshots.');
  check(serviceWorker.includes("url.origin !== self.location.origin"), 'Service worker must exclude external relay responses.');

  const mobileApp = fs.readFileSync(path.join(root, 'mobile', 'app.js'), 'utf8');
  check(mobileApp.includes('/json?poll=1&since=latest'), 'Latest snapshot fetch must request only the newest cached message.');
  check(!mobileApp.includes('/json?poll=1&since=all'), 'Latest snapshot fetch must not request the full cached history.');

  process.stdout.write(`Mobile JavaScript: ${checks} checks passed.\n`);
})().catch((error) => {
  process.stderr.write(`${error.stack || error}\n`);
  process.exitCode = 1;
});

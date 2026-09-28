(function () {
  'use strict';

  const DEFAULT_RELAY = 'https://ntfy.sh';
  const STORAGE = Object.freeze({ relay: 'codexUsage.relay', rememberedKey: 'codexUsage.pairKey', sessionKey: 'codexUsage.sessionPairKey' });
  const elements = {};
  let connection = null;
  let eventSource = null;
  let snapshot = null;
  let ticker = null;

  function byId(id) { return document.getElementById(id); }
  function setText(node, value) { node.textContent = value; }

  function getPairKey() {
    return localStorage.getItem(STORAGE.rememberedKey) || sessionStorage.getItem(STORAGE.sessionKey) || '';
  }

  function normalizeRelay(raw) {
    const url = new URL(String(raw || '').trim());
    const localHttp = url.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
    if (url.protocol !== 'https:' && !localHttp) throw new Error('中继地址必须使用 HTTPS');
    if (url.username || url.password || url.search || url.hash) throw new Error('中继地址不能包含账号、参数或片段');
    return url.href.replace(/\/$/, '');
  }

  function saveConnection(relay, pairKey, remember) {
    localStorage.setItem(STORAGE.relay, relay);
    if (remember) {
      localStorage.setItem(STORAGE.rememberedKey, pairKey);
      sessionStorage.removeItem(STORAGE.sessionKey);
    } else {
      localStorage.removeItem(STORAGE.rememberedKey);
      sessionStorage.setItem(STORAGE.sessionKey, pairKey);
    }
  }

  function setPill(text, tone) {
    setText(elements.pill, text);
    elements.pill.className = `pill ${tone || 'muted'}`;
  }

  function setBanner(title, detail, tone) {
    setText(elements.stateTitle, title);
    setText(elements.stateDetail, detail);
    elements.banner.dataset.tone = tone || 'muted';
  }

  function showSetup(error) {
    elements.setup.hidden = false;
    elements.dashboard.hidden = true;
    setPill('未连接', 'muted');
    setText(elements.setupError, error || '');
  }

  function showDashboard() {
    elements.setup.hidden = true;
    elements.dashboard.hidden = false;
  }

  function makeElement(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function createQuota(label, windowValue, stale) {
    const block = makeElement('section', 'quota');
    const heading = makeElement('div', 'quota-heading');
    heading.append(makeElement('span', '', label));
    const percentage = windowValue ? CodexMobileModel.clampPercent(windowValue.remainingPercent) : null;
    heading.append(makeElement('strong', '', percentage === null ? '—' : `${Math.round(percentage)}%`));
    block.append(heading);
    const track = makeElement('div', 'quota-track');
    track.setAttribute('role', 'progressbar');
    track.setAttribute('aria-label', label);
    track.setAttribute('aria-valuemin', '0');
    track.setAttribute('aria-valuemax', '100');
    track.setAttribute('aria-valuenow', percentage === null ? '0' : String(percentage));
    const fill = makeElement('span', `quota-fill ${CodexMobileModel.quotaTone(percentage, stale)}`);
    fill.style.width = `${percentage === null ? 0 : percentage}%`;
    track.append(fill);
    block.append(track);
    return block;
  }

  function createAccountCard(profile, freshness) {
    const stale = freshness.level === 'stale' || freshness.level === 'expired' || !profile.ok;
    const card = makeElement('article', `account-card${stale ? ' stale' : ''}`);
    const header = makeElement('header', 'account-header');
    const titleWrap = makeElement('div');
    titleWrap.append(makeElement('p', 'eyebrow', profile.id === 'personal' ? 'PERSONAL' : 'WORK'));
    titleWrap.append(makeElement('h2', '', profile.label));
    header.append(titleWrap);
    header.append(makeElement('span', `account-state ${profile.ok ? 'ok' : 'error'}`, profile.ok ? '已连接' : '读取失败'));
    card.append(header);
    card.append(createQuota('5 小时', profile.fiveHour, stale));
    card.append(createQuota('长周期', profile.longTerm, stale));

    const resets = makeElement('dl', 'reset-grid');
    const pairs = [
      ['5H 恢复', profile.fiveHour ? CodexMobileModel.formatCountdown(profile.fiveHour.resetsAt) : '未提供'],
      ['长周期恢复', profile.longTerm ? CodexMobileModel.formatCountdown(profile.longTerm.resetsAt) : '未提供']
    ];
    pairs.forEach(([term, description]) => {
      resets.append(makeElement('dt', '', term));
      resets.append(makeElement('dd', '', description));
    });
    card.append(resets);
    if (!profile.ok) card.append(makeElement('p', 'account-error', `${profile.label} 数据读取失败`));
    return card;
  }

  function renderSnapshot() {
    if (!snapshot) return;
    const freshness = CodexMobileModel.getFreshness(snapshot.publishedAt);
    elements.accounts.replaceChildren(...snapshot.profiles.map((profile) => createAccountCard(profile, freshness)));
    elements.empty.hidden = snapshot.profiles.length !== 0;
    setText(elements.lastSync, `${new Date(snapshot.publishedAt).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })} · ${CodexMobileModel.formatAge(snapshot.publishedAt)}`);

    if (!navigator.onLine) {
      setPill('离线', 'danger');
      setBanner('当前离线', '无法获取最新额度；当前数字仅来自本次打开期间最后收到的数据。', 'danger');
    } else if (freshness.level === 'fresh') {
      setPill('已连接', 'good');
      setBanner('Windows 电脑在线', `最近更新 ${CodexMobileModel.formatAge(snapshot.publishedAt)}`, 'good');
    } else if (freshness.level === 'aging') {
      setPill('数据变旧', 'warning');
      setBanner('数据未更新', `最近更新 ${CodexMobileModel.formatAge(snapshot.publishedAt)}`, 'warning');
    } else if (freshness.level === 'stale') {
      setPill('可能离线', 'danger');
      setBanner('电脑可能离线', `数据未更新 · 最近更新 ${CodexMobileModel.formatAge(snapshot.publishedAt)}`, 'danger');
    } else {
      setPill('已过期', 'danger');
      setBanner('数据已过期', `最近更新 ${CodexMobileModel.formatAge(snapshot.publishedAt)}`, 'danger');
    }
  }

  async function processCiphertext(cipherText) {
    let plain;
    try {
      plain = await CodexCrypto.decryptRemoteMessage(cipherText, connection.pairKey);
    } catch (error) {
      if (error && error.name === 'AuthenticationError') {
        setPill('密钥错误', 'danger');
        setBanner('配对密钥不正确或数据已损坏', '请检查 Windows 与手机上的配对密钥是否完全相同。', 'danger');
      }
      throw error;
    }
    let value;
    try { value = JSON.parse(plain); } catch (_) { throw new Error('已认证的数据不是有效 JSON'); }
    if (value.version !== 1 || value.type !== 'usage_snapshot') return false;
    snapshot = CodexMobileModel.validateSnapshot(value);
    renderSnapshot();
    return true;
  }

  async function fetchLatest() {
    if (!connection) return;
    if (!navigator.onLine) {
      renderSnapshot();
      if (!snapshot) setBanner('当前离线', '无法获取最新额度', 'danger');
      return;
    }
    elements.refresh.disabled = true;
    setBanner('正在连接…', '正在获取最近的额度快照', 'muted');
    try {
      const response = await fetch(`${connection.relay}/${connection.topic}/json?poll=1&since=all`, { cache: 'no-store', headers: { Accept: 'application/x-ndjson, application/json' } });
      if (!response.ok) throw new Error(`relay ${response.status}`);
      const messages = (await response.text()).split(/\r?\n/).filter(Boolean).map((line) => {
        try { return JSON.parse(line); } catch (_) { return null; }
      }).filter((item) => item && item.event === 'message' && typeof item.message === 'string');
      let accepted = false;
      let authError = null;
      for (let index = messages.length - 1; index >= 0 && !accepted; index -= 1) {
        try { accepted = await processCiphertext(messages[index].message); }
        catch (error) { if (error.name === 'AuthenticationError') authError = error; }
      }
      if (!accepted && authError) throw authError;
      if (!accepted) {
        setPill('等待数据', 'muted');
        setBanner('等待电脑发送额度…', '请确认 Windows 已启用手机额度同步并完成一次刷新。', 'muted');
      }
    } catch (error) {
      if (error.name !== 'AuthenticationError') {
        setPill('连接失败', 'danger');
        setBanner('中继服务器无法连接', '请检查网络和中继地址，然后重试。', 'danger');
      }
    } finally {
      elements.refresh.disabled = false;
    }
  }

  function startEventSource() {
    if (eventSource) eventSource.close();
    eventSource = new EventSource(`${connection.relay}/${connection.topic}/sse`);
    eventSource.onopen = () => { if (!snapshot) setPill('已连接', 'good'); };
    eventSource.onmessage = async (event) => {
      try {
        const envelope = JSON.parse(event.data);
        if (envelope.event !== 'message' || typeof envelope.message !== 'string') return;
        await processCiphertext(envelope.message);
      } catch (_) { /* UI state was set without exposing details. */ }
    };
    eventSource.onerror = () => {
      if (!snapshot && navigator.onLine) {
        setPill('正在重连', 'warning');
        setBanner('中继服务器无法连接', '连接会自动重试。', 'warning');
      }
    };
  }

  async function connect(relayValue, pairKey, remember) {
    const relay = normalizeRelay(relayValue);
    const normalizedKey = String(pairKey || '').trim();
    if (normalizedKey.length < 12) throw new Error('配对密钥至少需要 12 个字符');
    const topic = await CodexCrypto.deriveUsageTopic(normalizedKey);
    saveConnection(relay, normalizedKey, remember);
    connection = { relay, pairKey: normalizedKey, topic };
    showDashboard();
    setPill('正在连接', 'muted');
    await fetchLatest();
    startEventSource();
  }

  function openSettings() {
    elements.settingsRelay.value = connection ? connection.relay : (localStorage.getItem(STORAGE.relay) || DEFAULT_RELAY);
    elements.settingsKey.value = connection ? connection.pairKey : getPairKey();
    elements.settingsRemember.checked = Boolean(localStorage.getItem(STORAGE.rememberedKey));
    setText(elements.settingsError, '');
    elements.dialog.showModal();
  }

  function clearDeviceData() {
    Object.values(STORAGE).forEach((key) => { localStorage.removeItem(key); sessionStorage.removeItem(key); });
    if (eventSource) eventSource.close();
    eventSource = null;
    connection = null;
    snapshot = null;
    elements.accounts.replaceChildren();
    elements.dialog.close();
    elements.relay.value = DEFAULT_RELAY;
    elements.pairKey.value = '';
    elements.remember.checked = false;
    showSetup('此设备上的连接信息已清除。');
  }

  function bindElements() {
    Object.assign(elements, {
      setup: byId('setup-view'), dashboard: byId('dashboard-view'), pill: byId('connection-pill'), banner: byId('state-banner'),
      stateTitle: byId('state-title'), stateDetail: byId('state-detail'), accounts: byId('accounts'), empty: byId('empty-state'),
      lastSync: byId('last-sync'), refresh: byId('refresh-button'), setupForm: byId('setup-form'), relay: byId('relay-input'),
      pairKey: byId('pair-key-input'), remember: byId('remember-input'), setupError: byId('setup-error'), dialog: byId('settings-dialog'),
      settingsForm: byId('settings-form'), settingsRelay: byId('settings-relay'), settingsKey: byId('settings-key'),
      settingsRemember: byId('settings-remember'), settingsError: byId('settings-error')
    });
  }

  async function initialize() {
    bindElements();
    elements.setupForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      setText(elements.setupError, '');
      try { await connect(elements.relay.value, elements.pairKey.value, elements.remember.checked); }
      catch (error) { setText(elements.setupError, error.message || '无法连接'); }
    });
    elements.settingsForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      setText(elements.settingsError, '');
      try {
        await connect(elements.settingsRelay.value, elements.settingsKey.value, elements.settingsRemember.checked);
        elements.dialog.close();
      } catch (error) { setText(elements.settingsError, error.message || '无法连接'); }
    });
    byId('settings-button').addEventListener('click', openSettings);
    byId('close-settings').addEventListener('click', () => elements.dialog.close());
    byId('clear-device').addEventListener('click', clearDeviceData);
    elements.refresh.addEventListener('click', fetchLatest);
    window.addEventListener('online', fetchLatest);
    window.addEventListener('offline', renderSnapshot);
    document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') fetchLatest(); });
    ticker = window.setInterval(renderSnapshot, 15000);

    const relay = localStorage.getItem(STORAGE.relay) || DEFAULT_RELAY;
    const pairKey = getPairKey();
    elements.relay.value = relay;
    elements.remember.checked = Boolean(localStorage.getItem(STORAGE.rememberedKey));
    if (pairKey) {
      try { await connect(relay, pairKey, elements.remember.checked); }
      catch (_) { showSetup('已保存的连接信息无效，请重新输入。'); }
    } else showSetup();

    if ('serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js').catch(() => {});
  }

  window.addEventListener('DOMContentLoaded', initialize, { once: true });
  window.addEventListener('pagehide', () => { if (eventSource) eventSource.close(); if (ticker) window.clearInterval(ticker); });
})();

(function (scope) {
  'use strict';

  function clampPercent(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) return null;
    return Math.max(0, Math.min(100, number));
  }

  function validDate(value) {
    return typeof value === 'string' && value.length > 0 && Number.isFinite(Date.parse(value));
  }

  function normalizeWindow(value, expectedKind) {
    if (value === null || value === undefined) return null;
    if (typeof value !== 'object' || typeof value.kind !== 'string') throw new Error('额度窗口格式无效');
    if (expectedKind && value.kind !== expectedKind) throw new Error('额度窗口类型无效');
    const remainingPercent = clampPercent(value.remainingPercent);
    if (remainingPercent === null) throw new Error('额度百分比无效');
    if (value.resetsAt !== null && value.resetsAt !== undefined && !validDate(value.resetsAt)) throw new Error('恢复时间无效');
    return {
      kind: value.kind,
      label: typeof value.label === 'string' ? value.label.slice(0, 60) : value.kind,
      remainingPercent,
      resetsAt: value.resetsAt || null
    };
  }

  function validateSnapshot(value) {
    if (!value || value.version !== 1 || value.type !== 'usage_snapshot') throw new Error('不支持的额度消息');
    if (!validDate(value.publishedAt) || !Array.isArray(value.profiles)) throw new Error('额度消息格式无效');
    const profiles = value.profiles.map((profile) => {
      if (!profile || !['personal', 'work'].includes(profile.id) || typeof profile.ok !== 'boolean') throw new Error('账号数据格式无效');
      if (profile.fetchedAt !== null && profile.fetchedAt !== undefined && !validDate(profile.fetchedAt)) throw new Error('账号更新时间无效');
      const longTerm = normalizeWindow(profile.longTerm);
      if (longTerm && !['weekly', 'workspace'].includes(longTerm.kind)) throw new Error('长周期类型无效');
      return {
        id: profile.id,
        label: typeof profile.label === 'string' && profile.label.trim() ? profile.label.trim().slice(0, 40) : profile.id,
        ok: profile.ok,
        status: profile.status === 'ok' ? 'ok' : 'error',
        fetchedAt: profile.fetchedAt || null,
        fiveHour: normalizeWindow(profile.fiveHour, '5h'),
        longTerm
      };
    });
    return {
      version: 1,
      type: 'usage_snapshot',
      deviceId: typeof value.deviceId === 'string' ? value.deviceId.slice(0, 80) : '',
      deviceName: typeof value.deviceName === 'string' ? value.deviceName.slice(0, 80) : '',
      publishedAt: value.publishedAt,
      profiles
    };
  }

  function getFreshness(publishedAt, now = Date.now()) {
    const ageMs = Math.max(0, now - Date.parse(publishedAt));
    const minutes = ageMs / 60000;
    if (minutes < 2) return { level: 'fresh', minutes };
    if (minutes <= 10) return { level: 'aging', minutes };
    if (minutes <= 1440) return { level: 'stale', minutes };
    return { level: 'expired', minutes };
  }

  function formatCountdown(resetsAt, now = Date.now()) {
    if (!validDate(resetsAt)) return '未提供';
    const remainingMinutes = Math.ceil((Date.parse(resetsAt) - now) / 60000);
    if (remainingMinutes <= 0) return '等待电脑确认';
    if (remainingMinutes >= 1440) {
      const days = Math.floor(remainingMinutes / 1440);
      const hours = Math.floor((remainingMinutes % 1440) / 60);
      return `${days}天${hours}小时`;
    }
    if (remainingMinutes >= 60) return `${Math.floor(remainingMinutes / 60)}小时${remainingMinutes % 60}分`;
    return `${Math.max(1, remainingMinutes)}分钟`;
  }

  function formatAge(publishedAt, now = Date.now()) {
    const minutes = Math.max(0, Math.floor((now - Date.parse(publishedAt)) / 60000));
    if (minutes < 1) return '刚刚';
    if (minutes < 60) return `${minutes} 分钟前`;
    if (minutes < 1440) return `${Math.floor(minutes / 60)} 小时前`;
    return `${Math.floor(minutes / 1440)} 天前`;
  }

  function quotaTone(value, stale) {
    const percentage = clampPercent(value);
    if (stale || percentage === null) return 'muted';
    if (percentage <= 15) return 'danger';
    if (percentage <= 35) return 'warning';
    return 'normal';
  }

  scope.CodexMobileModel = Object.freeze({ clampPercent, validateSnapshot, getFreshness, formatCountdown, formatAge, quotaTone });
})(globalThis);

(function (scope) {
  'use strict';

  const encoder = new TextEncoder();
  const decoder = new TextDecoder('utf-8', { fatal: true });

  function bytesToHex(bytes) {
    return Array.from(bytes, (value) => value.toString(16).padStart(2, '0')).join('');
  }

  async function sha256Bytes(text) {
    return new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(text)));
  }

  async function deriveUsageTopic(pairKey) {
    if (typeof pairKey !== 'string' || pairKey.length < 12) throw new Error('配对密钥至少需要 12 个字符');
    const digest = await sha256Bytes(`codex-mobile-usage-topic-v1|${pairKey}`);
    return `codex-usage-${bytesToHex(digest).slice(0, 48)}`;
  }

  function decodeBase64(value) {
    try {
      const raw = atob(String(value).replace(/\s+/g, ''));
      return Uint8Array.from(raw, (character) => character.charCodeAt(0));
    } catch (_) {
      throw new Error('加密数据格式无效');
    }
  }

  async function decryptRemoteMessage(cipherText, pairKey) {
    const payload = decodeBase64(cipherText);
    if (payload.length < 65) throw new Error('加密数据长度无效');

    const body = payload.slice(0, -32);
    const receivedTag = payload.slice(-32);
    const macKeyBytes = await sha256Bytes(`codex-remote-mac-v1|${pairKey}`);
    const macKey = await crypto.subtle.importKey('raw', macKeyBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['verify']);
    const authenticated = await crypto.subtle.verify('HMAC', macKey, receivedTag, body);
    if (!authenticated) {
      const error = new Error('配对密钥不正确或数据已损坏');
      error.name = 'AuthenticationError';
      throw error;
    }

    const iv = body.slice(0, 16);
    const ciphertext = body.slice(16);
    const encKeyBytes = await sha256Bytes(`codex-remote-enc-v1|${pairKey}`);
    const encKey = await crypto.subtle.importKey('raw', encKeyBytes, { name: 'AES-CBC' }, false, ['decrypt']);
    let plain;
    try {
      plain = await crypto.subtle.decrypt({ name: 'AES-CBC', iv }, encKey, ciphertext);
    } catch (_) {
      throw new Error('已认证的数据无法解密');
    }
    return decoder.decode(plain);
  }

  scope.CodexCrypto = Object.freeze({ deriveUsageTopic, decryptRemoteMessage, bytesToHex });
})(globalThis);

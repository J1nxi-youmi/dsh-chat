const $ = (selector) => document.querySelector(selector);

const state = {
  token: localStorage.getItem('chat.token') || '',
  server: (localStorage.getItem('chat.server') || location.origin).replace(/\/+$/, ''),
  conversations: [],
  conversation: null,
  busy: false,
  events: null,
  pendingAttachments: [],
  /** 还没拿到服务端 ack 的消息（断线重发用），按会话存 localStorage。 */
  pending: [],
  /** 本会话已收到的最大 seq，断线重连后从这里往后补。 */
  lastSeq: 0,
  flushing: false,
};

// ---------------------------------------------------------------- 网络

async function api(path, options = {}) {
  const response = await fetch(state.server + path, {
    ...options,
    headers: {
      ...(options.body ? { 'content-type': 'application/json' } : {}),
      ...(state.token ? { authorization: `Bearer ${state.token}` } : {}),
      ...(options.headers ?? {}),
    },
  });
  if (response.status === 401) {
    showLogin('令牌不对');
    throw new Error('unauthorized');
  }
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.ok === false) {
    throw new Error(data.error || `请求失败（${response.status}）`);
  }
  return data;
}

// ---------------------------------------------------------------- 登录

function showLogin(message) {
  $('#login').classList.remove('hidden');
  $('#loginError').textContent = message || '';
  const serverField = $('#loginServer');
  if (serverField) serverField.value = state.server === location.origin ? '' : state.server;
  $('#loginToken').focus();
}

$('#loginBtn').addEventListener('click', async () => {
  state.token = $('#loginToken').value.trim();
  const typedServer = ($('#loginServer')?.value || '').trim().replace(/\/+$/, '');
  state.server = typedServer || location.origin;
  localStorage.setItem('chat.token', state.token);
  localStorage.setItem('chat.server', state.server);
  try {
    await api('/api/conversations');
    $('#login').classList.add('hidden');
    await boot();
  } catch (error) {
    $('#loginError').textContent = error.message;
  }
});

$('#loginToken').addEventListener('keydown', (event) => {
  if (event.key === 'Enter') $('#loginBtn').click();
});

// ---------------------------------------------------------------- 会话

async function boot() {
  await loadConversations();
  if (state.conversations.length > 0) await openConversation(state.conversations[0].id);
  else await newConversation();
  startEvents();
  $('#status').textContent = '已连接';
}

async function loadConversations() {
  const data = await api('/api/conversations');
  state.conversations = data.conversations;
  renderConversations();
}

function renderConversations() {
  const list = $('#conversationList');
  list.replaceChildren();
  for (const conversation of state.conversations) {
    const button = document.createElement('button');
    button.className = 'conversation' + (state.conversation?.id === conversation.id ? ' active' : '');

    const title = document.createElement('span');
    title.className = 'c-title';
    title.textContent = conversation.title || '新对话';

    const preview = document.createElement('span');
    preview.className = 'c-preview';
    preview.textContent = conversation.preview || '';

    const remove = document.createElement('button');
    remove.className = 'c-del';
    remove.textContent = '×';
    remove.title = '删除这个对话';
    remove.addEventListener('click', async (event) => {
      event.stopPropagation();
      if (!confirm(`删除「${conversation.title || '新对话'}」？`)) return;
      try {
        await api(`/api/conversations/${conversation.id}`, { method: 'DELETE' });
      } catch (error) {
        return flashError(error.message);
      }
      await loadConversations();
      if (state.conversation?.id === conversation.id) {
        state.conversation = null;
        const next = state.conversations[0];
        if (next) await openConversation(next.id);
        else await newConversation();
      }
    });

    button.append(title, preview, remove);
    button.addEventListener('click', () => {
      openConversation(conversation.id);
      document.body.classList.remove('drawer-open');
    });
    list.appendChild(button);
  }
}

async function newConversation() {
  const data = await api('/api/conversations', { method: 'POST', body: '{}' });
  state.conversations.unshift({
    id: data.conversation.id,
    title: '新对话',
    preview: '新对话',
    updatedAt: data.conversation.updatedAt,
    count: 0,
  });
  renderConversations();
  await openConversation(data.conversation.id);
}

async function openConversation(id) {
  const data = await api(`/api/conversations/${id}`);
  state.conversation = data.conversation;
  state.lastSeq = (state.conversation.messages ?? []).reduce(
    (max, message) => Math.max(max, Number(message.seq) || 0),
    0,
  );
  loadPending(id);
  $('#title').textContent = state.conversation.title || '聊天';
  renderMessages();
  renderConversations();
  // 断线期间可能在别的设备上聊过：补一下，再重发没 ack 的。
  syncSince().catch(() => {});
  flushPending();
}

// ---------------------------------------------------------------- 未 ack 队列

const newId = () =>
  globalThis.crypto?.randomUUID
    ? crypto.randomUUID()
    : `${Date.now()}-${Math.random().toString(16).slice(2)}`;

const pendingKey = (conversationId) => `chat.pending.${conversationId}`;

/** 读这个会话没发出去的消息；页面刷新后一律当 failed，等重连重发。 */
function loadPending(conversationId) {
  try {
    const raw = JSON.parse(localStorage.getItem(pendingKey(conversationId)) || '[]');
    state.pending = Array.isArray(raw)
      ? raw.map((item) => ({ ...item, status: 'failed' }))
      : [];
  } catch {
    state.pending = [];
  }
}

function savePending() {
  if (!state.conversation) return;
  try {
    if (state.pending.length === 0) localStorage.removeItem(pendingKey(state.conversation.id));
    else localStorage.setItem(pendingKey(state.conversation.id), JSON.stringify(state.pending));
  } catch {
    /* 存不下就先放着 */
  }
}

/** 把一条消息并进当前会话：按 id 去重、按 seq 保序。 */
function ingest(message) {
  if (!message || !state.conversation) return false;
  if (state.conversation.messages.some((item) => item.id === message.id)) return false;
  state.conversation.messages.push(message);
  state.conversation.messages.sort((left, right) => (Number(left.seq) || 0) - (Number(right.seq) || 0));
  state.lastSeq = Math.max(state.lastSeq, Number(message.seq) || 0);
  return true;
}

/** 从 lastSeq 往后补消息（断线重连 / 打开会话时）。 */
async function syncSince() {
  if (!state.conversation) return;
  const conversationId = state.conversation.id;
  for (let round = 0; round < 20; round += 1) {
    const data = await api(
      `/api/conversations/${conversationId}/messages?since=${state.lastSeq}&limit=200`,
    );
    if (state.conversation?.id !== conversationId) return;
    let changed = false;
    for (const message of data.messages ?? []) changed = ingest(message) || changed;
    if (data.lastSeq) state.lastSeq = Math.max(state.lastSeq, Number(data.lastSeq));
    if (changed) renderMessages();
    if (!data.hasMore) break;
  }
}

/** 发一条已经排队的消息；成功返回 true。 */
async function deliver(item) {
  try {
    const data = await api(`/api/conversations/${state.conversation.id}/messages`, {
      method: 'POST',
      body: JSON.stringify({
        text: item.text,
        attachments: (item.attachments ?? []).map((attachment) => ({ id: attachment.id })),
        clientMessageId: item.clientMessageId,
      }),
    });
    state.pending = state.pending.filter((entry) => entry.clientMessageId !== item.clientMessageId);
    savePending();
    ingest(data.user);
    for (const reply of data.replies ?? []) ingest(reply);
    if (data.conversation) {
      state.conversation.title = data.conversation.title;
      $('#title').textContent = data.conversation.title;
    }
    renderMessages();
    await loadConversations();
    return true;
  } catch (error) {
    item.status = 'failed';
    savePending();
    renderMessages();
    flashError(error.message);
    return false;
  }
}

/** 按顺序重发没 ack 的消息；失败就停，等下次重连。 */
async function flushPending() {
  if (state.flushing || !state.conversation || state.pending.length === 0) return;
  state.flushing = true;
  try {
    for (const item of [...state.pending]) {
      if (!state.pending.some((entry) => entry.clientMessageId === item.clientMessageId)) continue;
      const ok = await deliver(item);
      if (!ok) break;
    }
  } finally {
    state.flushing = false;
  }
}

// ---------------------------------------------------------------- 渲染

function formatTime(iso) {
  const date = new Date(iso);
  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
}

function assetUrl(url) {
  if (!url) return url;
  return url.startsWith('/') ? state.server + url : url;
}

function attachmentNode(attachment) {
  if (attachment.kind === 'image') {
    const link = document.createElement('a');
    link.href = assetUrl(attachment.url);
    link.target = '_blank';
    link.rel = 'noreferrer';
    const image = document.createElement('img');
    image.src = assetUrl(attachment.url);
    image.alt = attachment.name;
    image.loading = 'lazy';
    link.appendChild(image);
    return link;
  }
  if (attachment.kind === 'voice') {
    const audio = document.createElement('audio');
    audio.controls = true;
    audio.preload = 'metadata';
    audio.src = assetUrl(attachment.url);
    return audio;
  }
  const link = document.createElement('a');
  link.className = 'file-chip';
  link.href = assetUrl(attachment.url);
  link.target = '_blank';
  link.rel = 'noreferrer';
  link.textContent = `📄 ${attachment.name}`;
  return link;
}

/** 把文字里的网址变成可点的链接，其余原样输出（不用 innerHTML）。 */
function renderTextWithLinks(element, value) {
  const pattern = /https?:\/\/[^\s<>"'）)】」]+/g;
  const text = String(value ?? '');
  let lastIndex = 0;
  for (const match of text.matchAll(pattern)) {
    if (match.index > lastIndex) {
      element.appendChild(document.createTextNode(text.slice(lastIndex, match.index)));
    }
    const link = document.createElement('a');
    link.href = match[0];
    link.target = '_blank';
    link.rel = 'noreferrer';
    link.textContent = match[0];
    element.appendChild(link);
    lastIndex = match.index + match[0].length;
  }
  if (lastIndex < text.length) {
    element.appendChild(document.createTextNode(text.slice(lastIndex)));
  }
}

function renderMessages() {
  const container = $('#messages');
  const atBottom = container.scrollHeight - container.scrollTop - container.clientHeight < 80;
  container.replaceChildren();
  for (const message of state.conversation?.messages ?? []) {
    const row = document.createElement('div');
    row.className = `row ${message.role === 'user' ? 'me' : 'her'}`;
    const bubble = document.createElement('div');
    bubble.className = 'bubble';
    for (const attachment of message.attachments ?? []) {
      bubble.appendChild(attachmentNode(attachment));
    }
    if (message.text) {
      const text = document.createElement('div');
      text.className = 'text';
      renderTextWithLinks(text, message.text);
      bubble.appendChild(text);
    }
    const time = document.createElement('time');
    time.textContent = formatTime(message.at);
    bubble.appendChild(time);
    row.appendChild(bubble);
    container.appendChild(row);
  }

  // 还没 ack 的消息：本体已显示，旁边给一个状态点，失败可以点着重发。
  for (const item of state.pending) {
    const row = document.createElement('div');
    row.className = 'row me pending-row';
    const bubble = document.createElement('div');
    bubble.className = 'bubble';
    for (const attachment of item.attachments ?? []) {
      bubble.appendChild(attachmentNode(attachment));
    }
    if (item.text) {
      const text = document.createElement('div');
      text.className = 'text';
      renderTextWithLinks(text, item.text);
      bubble.appendChild(text);
    }
    const state_ = document.createElement('span');
    state_.className = `msg-state ${item.status}`;
    state_.textContent = item.status === 'failed' ? '发送失败，点这里重发' : '发送中…';
    if (item.status === 'failed') {
      state_.addEventListener('click', () => {
        item.status = 'sending';
        savePending();
        renderMessages();
        deliver(item);
      });
    }
    bubble.appendChild(state_);
    row.appendChild(bubble);
    container.appendChild(row);
  }

  if (atBottom) container.scrollTop = container.scrollHeight;
}

function appendMessage(message) {
  if (ingest(message)) renderMessages();
}

// ---------------------------------------------------------------- 发送

function setBusy(busy) {
  state.busy = busy;
  $('#pending').classList.toggle('hidden', !busy);
  $('#send').disabled = busy;
}

async function sendText() {
  if (!state.conversation || state.busy) return;
  const text = $('#input').value.trim();
  const attachments = state.pendingAttachments.slice();
  if (!text && attachments.length === 0) return;

  $('#input').value = '';
  autosize();
  state.pendingAttachments = [];
  renderAttachmentBar();

  // 先上屏再发：哪怕网断了，用户也能看到「这条在发送中/失败了」。
  const item = {
    clientMessageId: newId(),
    text,
    attachments,
    at: new Date().toISOString(),
    status: 'sending',
  };
  state.pending.push(item);
  savePending();
  renderMessages();
  setBusy(true);
  try {
    await deliver(item);
  } finally {
    setBusy(false);
  }
}

$('#composer').addEventListener('submit', (event) => {
  event.preventDefault();
  sendText();
});

$('#input').addEventListener('input', autosize);
$('#input').addEventListener('keydown', (event) => {
  if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
    event.preventDefault();
    sendText();
  }
});

function autosize() {
  const input = $('#input');
  input.style.height = 'auto';
  input.style.height = `${Math.min(160, input.scrollHeight)}px`;
}

// ---------------------------------------------------------------- 附件

$('#attach').addEventListener('click', () => $('#filePicker').click());
$('#filePicker').addEventListener('change', async (event) => {
  const files = [...event.target.files];
  event.target.value = '';
  for (const file of files) await uploadFile(file);
});

const TEXT_EXTENSIONS = ['.txt', '.md', '.json', '.csv', '.log', '.js', '.mjs', '.ts', '.py', '.html', '.css', '.yaml', '.yml'];

const extension = (name) => {
  const index = name.lastIndexOf('.');
  return index < 0 ? '' : name.slice(index).toLowerCase();
};

function base64(buffer) {
  let binary = '';
  const bytes = new Uint8Array(buffer);
  const chunk = 0x8000;
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk));
  }
  return btoa(binary);
}

async function uploadFile(file) {
  if (file.size > 96 * 1024 * 1024) return flashError(`${file.name} 超过 96MB`);
  const buffer = await file.arrayBuffer();
  const isText = file.type.startsWith('text/') || TEXT_EXTENSIONS.includes(extension(file.name));
  const textPreview = isText && file.size < 200 * 1024
    ? new TextDecoder().decode(buffer).slice(0, 4000)
    : undefined;
  try {
    const result = await api('/api/upload', {
      method: 'POST',
      body: JSON.stringify({
        name: file.name,
        mime: file.type || 'application/octet-stream',
        data: base64(buffer),
        textPreview,
      }),
    });
    state.pendingAttachments.push(result.attachment);
    renderAttachmentBar();
  } catch (error) {
    flashError(error.message);
  }
}

function renderAttachmentBar() {
  const bar = $('#attachmentBar');
  bar.replaceChildren();
  if (state.pendingAttachments.length === 0) {
    bar.classList.add('hidden');
    return;
  }
  bar.classList.remove('hidden');
  for (const attachment of state.pendingAttachments) {
    const chip = document.createElement('span');
    chip.className = 'chip';
    chip.textContent = attachment.kind === 'voice'
      ? `🎙️ ${Math.round(attachment.duration || 0)}s`
      : `📎 ${attachment.name}`;
    const remove = document.createElement('button');
    remove.textContent = '×';
    remove.addEventListener('click', () => {
      state.pendingAttachments = state.pendingAttachments.filter((item) => item.id !== attachment.id);
      renderAttachmentBar();
    });
    chip.appendChild(remove);
    bar.appendChild(chip);
  }
}

// ---------------------------------------------------------------- 语音

// 录 16kHz 单声道 WAV：Windows 自带的中文识别器只认这个格式，也省掉转码。
let audioCtx = null;
let processor = null;
let sourceNode = null;
let sink = null;
let streamRef = null;
let pcmChunks = [];
let recordStart = 0;
let recordTimer = 0;
let starting = false;

function micBlocker() {
  const secure = location.protocol === 'https:' || ['localhost', '127.0.0.1'].includes(location.hostname);
  if (!secure) return '浏览器只允许在 https 或 localhost 下用麦克风——换隧道那个 https 地址打开。';
  if (!navigator.mediaDevices?.getUserMedia) return '这个浏览器不支持录音。';
  return '';
}

/** 把 [-1,1] 的浮点采样写成 16 位单声道 WAV。 */
function encodeWav(samples, sampleRate) {
  const buffer = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(buffer);
  const write = (offset, text) => {
    for (let i = 0; i < text.length; i += 1) view.setUint8(offset + i, text.charCodeAt(i));
  };
  write(0, 'RIFF');
  view.setUint32(4, 36 + samples.length * 2, true);
  write(8, 'WAVE');
  write(12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  write(36, 'data');
  view.setUint32(40, samples.length * 2, true);
  let offset = 44;
  for (let i = 0; i < samples.length; i += 1) {
    const sample = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
    offset += 2;
  }
  return new Blob([view], { type: 'audio/wav' });
}

/** 浏览器未必听 16k 的请求，这里再线性重采样一次。 */
function resample(samples, from, to) {
  if (from === to) return samples;
  const ratio = to / from;
  const length = Math.floor(samples.length * ratio);
  const out = new Float32Array(length);
  for (let i = 0; i < length; i += 1) {
    const position = i / ratio;
    const index = Math.floor(position);
    const fraction = position - index;
    const a = samples[index] ?? 0;
    const b = samples[index + 1] ?? a;
    out[i] = a + (b - a) * fraction;
  }
  return out;
}

async function startRecording() {
  if (starting || audioCtx) return;
  const blocker = micBlocker();
  if (blocker) return flashError(blocker);
  starting = true;

  try {
    streamRef = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true },
    });
  } catch (error) {
    starting = false;
    return flashError(`拿不到麦克风：${error.message}`);
  }

  audioCtx = new AudioContext({ sampleRate: 16000 });
  await audioCtx.resume();
  sourceNode = audioCtx.createMediaStreamSource(streamRef);
  processor = audioCtx.createScriptProcessor(4096, 1, 1);
  sink = audioCtx.createGain();
  sink.gain.value = 0; // 别把自己的声音放出来
  pcmChunks = [];

  processor.onaudioprocess = (event) => {
    pcmChunks.push(new Float32Array(event.inputBuffer.getChannelData(0)));
  };
  sourceNode.connect(processor);
  processor.connect(sink);
  sink.connect(audioCtx.destination);

  recordStart = Date.now();
  starting = false;
  $('#recording').classList.remove('hidden');
  $('#mic').classList.add('rec-on');
  $('#recTime').textContent = '0.0s';
  recordTimer = setInterval(() => {
    $('#recTime').textContent = `${((Date.now() - recordStart) / 1000).toFixed(1)}s`;
  }, 100);
}

async function stopRecording() {
  if (!audioCtx) return;
  const duration = (Date.now() - recordStart) / 1000;
  clearInterval(recordTimer);
  $('#recording').classList.add('hidden');
  $('#mic').classList.remove('rec-on');

  const rate = audioCtx.sampleRate;
  try {
    processor?.disconnect();
    sourceNode?.disconnect();
    sink?.disconnect();
  } catch {
    /* 已经断了 */
  }
  streamRef?.getTracks().forEach((track) => track.stop());
  await audioCtx.close();
  audioCtx = null;
  processor = null;
  sourceNode = null;
  sink = null;
  streamRef = null;

  if (duration < 0.5) return flashError('太短了，再说长一点');
  if (pcmChunks.length === 0) return flashError('没录到声音');

  const total = pcmChunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const merged = new Float32Array(total);
  let offset = 0;
  for (const chunk of pcmChunks) {
    merged.set(chunk, offset);
    offset += chunk.length;
  }
  pcmChunks = [];

  const samples = resample(merged, rate, 16000);
  const blob = encodeWav(samples, 16000);
  const buffer = await blob.arrayBuffer();
  try {
    const result = await api('/api/upload', {
      method: 'POST',
      body: JSON.stringify({
        name: `语音-${new Date().toISOString().slice(11, 19)}.wav`,
        mime: 'audio/wav',
        data: base64(buffer),
        kind: 'voice',
        duration,
      }),
    });
    state.pendingAttachments.push(result.attachment);
    renderAttachmentBar();
    await sendText();
  } catch (error) {
    flashError(error.message);
  }
}

// 点一下开始，再点一下发送
$('#mic').addEventListener('click', (event) => {
  event.preventDefault();
  if (audioCtx) stopRecording();
  else startRecording();
});

// ---------------------------------------------------------------- 其他

$('#toggleDrawer').addEventListener('click', () => document.body.classList.toggle('drawer-open'));
$('#newChat').addEventListener('click', () => newConversation());

$('#clearChats').addEventListener('click', async () => {
  if (state.conversations.length === 0) return;
  const ok = confirm(`清空全部 ${state.conversations.length} 个对话？DSH 那边的会话也会一起删掉。`);
  if (!ok) return;
  try {
    await api('/api/conversations', { method: 'DELETE' });
  } catch (error) {
    return flashError(error.message);
  }
  state.conversation = null;
  await loadConversations();
  await newConversation();
});

function flashError(message) {
  $('#status').textContent = message;
  $('#status').classList.add('err');
  setTimeout(() => {
    $('#status').textContent = '已连接';
    $('#status').classList.remove('err');
  }, 5000);
}

/** 实时事件：新回复和 DSH 主动推来的消息都从这里到，不再轮询。 */
function startEvents() {
  state.events?.close();
  const source = new EventSource(`${state.server}/api/events?t=${encodeURIComponent(state.token)}`);
  state.events = source;
  source.onopen = () => {
    $('#status').textContent = '已连接';
    $('#status').classList.remove('err');
    // 断线期间可能错过了几条：补增量，再把没 ack 的发出去。
    syncSince().catch(() => {});
    flushPending();
  };
  source.onerror = () => {
    $('#status').textContent = '连接中…';
    $('#status').classList.add('err');
  };
  source.onmessage = (event) => {
    let data;
    try {
      data = JSON.parse(event.data);
    } catch {
      return;
    }
    if (data?.type !== 'message' || !data.message) return;
    loadConversations();
    if (!state.conversation || data.conversationId !== state.conversation.id) return;
    const seq = Number(data.message.seq) || 0;
    // 有缺口（中间漏了事件）就整段补一次，别只追这一条。
    if (seq > state.lastSeq + 1) {
      syncSince().catch(() => {});
      return;
    }
    if (ingest(data.message)) renderMessages();
  };
  // EventSource 自己会重连，这里不用管
}

// 网络恢复 / 页面重新可见时，主动补一次并重发队列。
window.addEventListener('online', () => {
  syncSince().catch(() => {});
  flushPending();
});
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') flushPending();
});

// ---------------------------------------------------------------- 启动

if (state.token) {
  api('/api/conversations').then(boot).catch(() => showLogin('令牌不对'));
} else {
  showLogin();
}

// ---------------------------------------------------------------- 设置

const settingsDialog = $('#settingsDialog');

async function openSettings() {
  try {
    const data = await api('/api/settings');
    const s = data.settings;
    $('#setPrompt').value = s.systemPrompt || '';
    $('#setFetchLinks').checked = Boolean(s.fetchLinks);
    $('#setBubbles').checked = Boolean(s.bubbles);
    $('#setMaxMb').value = Math.round((s.maxUploadBytes || 0) / 1024 / 1024);
    $('#settingsMsg').textContent = '';
    settingsDialog.showModal();
  } catch (error) {
    flashError(error.message);
  }
}

$('#settingsBtn')?.addEventListener('click', openSettings);
$('#settingsCancel')?.addEventListener('click', () => settingsDialog.close());
$('#settingsSave')?.addEventListener('click', async () => {
  try {
    await api('/api/settings', {
      method: 'POST',
      body: JSON.stringify({
        systemPrompt: $('#setPrompt').value,
        fetchLinks: $('#setFetchLinks').checked,
        bubbles: $('#setBubbles').checked,
        maxUploadMb: Number($('#setMaxMb').value),
      }),
    });
    $('#settingsMsg').textContent = '已保存';
    setTimeout(() => settingsDialog.close(), 600);
  } catch (error) {
    $('#settingsMsg').textContent = error.message;
  }
});

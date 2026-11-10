/**
 * 极简中转：只是「按房间转发」，不认识业务数据。
 *
 *   wss://<host>/ws?room=<房间>&key=<密钥>&role=host|client
 *
 * - 两端都主动往外连，所以谁在 NAT 后面都无所谓。
 * - 同一个 room 里，client → host 的帧原样转，host → client 的帧广播给所有 client。
 * - 主机不在线时，client 的帧丢掉；client 全都不在时，host 的帧最多留 50 条等它回来。
 */
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

function encodeFrame(text) {
  const payload = Buffer.from(text, 'utf8');
  const length = payload.length;
  let header;
  if (length < 126) {
    header = Buffer.from([0x81, length]);
  } else if (length < 65_536) {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x81;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  return Buffer.concat([header, payload]);
}

function createFrameParser(onText, onClose) {
  let buffer = Buffer.alloc(0);
  return (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    for (;;) {
      if (buffer.length < 2) return;
      const opcode = buffer[0] & 0x0f;
      const masked = (buffer[1] & 0x80) !== 0;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffer.length < 4) return;
        length = buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffer.length < 10) return;
        length = Number(buffer.readBigUInt64BE(2));
        offset = 10;
      }
      const maskLength = masked ? 4 : 0;
      if (buffer.length < offset + maskLength + length) return;
      const mask = masked ? buffer.subarray(offset, offset + 4) : null;
      offset += maskLength;
      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      if (mask) for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
      buffer = buffer.subarray(offset + length);
      if (opcode === 0x8) {
        onClose?.();
        return;
      }
      if (opcode === 0x1) onText(payload.toString('utf8'));
    }
  };
}

/** @type {Map<string, {key:string, host:any, clients:Set<any>, backlog:string[]}>} */
const rooms = new Map();

const port = Number(process.env.RELAY_PORT ?? 8793);
const publicUrl = process.env.RELAY_PUBLIC_URL ?? `http://127.0.0.1:${port}`;

const server = createServer((req, res) => {
  if (req.url?.startsWith('/healthz')) {
    const roomsInfo = [...rooms].map(([room, entry]) => ({
      room,
      host: Boolean(entry.host),
      clients: entry.clients.size,
    }));
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, rooms: roomsInfo }));
    return;
  }
  res.writeHead(404);
  res.end();
});

server.on('upgrade', (request, socket) => {
  const url = new URL(request.url ?? '/', 'http://relay');
  const room = url.searchParams.get('room') ?? '';
  const key = url.searchParams.get('key') ?? '';
  const role = url.searchParams.get('role') ?? '';
  if (!room || !key || (role !== 'host' && role !== 'client')) {
    socket.write('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }

  let entry = rooms.get(room);
  if (!entry) {
    entry = { key, host: null, clients: new Set(), backlog: [] };
    rooms.set(room, entry);
  }
  // 房间密钥不对就直接拒绝，别人猜不到房间也不该能连进来。
  if (entry.key !== key) {
    socket.write('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
    socket.destroy();
    return;
  }

  const accept = createHash('sha1')
    .update(String(request.headers['sec-websocket-key']) + GUID)
    .digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\nConnection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  socket.setNoDelay?.(true);

  const send = (text) => {
    if (!socket.destroyed) socket.write(encodeFrame(text));
  };

  if (role === 'host') {
    if (entry.host && !entry.host.destroyed) entry.host.destroy();
    entry.host = socket;
    // 主机回来了，把积累的帧补给它
    for (const frame of entry.backlog.splice(0)) send(frame);
    console.log(`[relay] host 上线 room=${room}`);
  } else {
    entry.clients.add(socket);
    console.log(`[relay] client 上线 room=${room}（共 ${entry.clients.size}）`);
  }

  const cleanup = () => {
    if (role === 'host') {
      if (entry.host === socket) entry.host = null;
    } else {
      entry.clients.delete(socket);
    }
    if (!entry.host && entry.clients.size === 0) rooms.delete(room);
  };

  const parse = createFrameParser(
    (text) => {
      if (role === 'client') {
        if (entry.host && !entry.host.destroyed) entry.host.write(encodeFrame(text));
        return;
      }
      // host 发出来的帧：广播给所有 client；没人时留一点尾巴
      if (entry.clients.size === 0) {
        entry.backlog.push(text);
        if (entry.backlog.length > 50) entry.backlog.shift();
        return;
      }
      for (const client of entry.clients) {
        if (!client.destroyed) client.write(encodeFrame(text));
      }
    },
    cleanup,
  );

  socket.on('data', parse);
  socket.on('close', cleanup);
  socket.on('error', cleanup);
});

server.listen(port, () => {
  console.log(`[relay] 监听 ${port}，对外地址 ${publicUrl}`);
});

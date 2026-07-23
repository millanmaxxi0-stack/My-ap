#!/bin/bash
echo "================================"
echo "  PeyamApp v5 - Installing..."
echo "================================"
pkill -9 node 2>/dev/null
rm -rf ~/peyamapp
mkdir -p ~/peyamapp/public
cd ~/peyamapp

cat > package.json << 'PKGEOF'
{
  "name": "peyamapp",
  "version": "5.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.18.2",
    "socket.io": "^4.6.1",
    "cors": "^2.8.5"
  }
}
PKGEOF

cat > server.js << 'SRVEOF'
const express = require('express');
const https = require('https');
const http = require('http');
const fs = require('fs');
const { Server } = require('socket.io');
const cors = require('cors');
const path = require('path');

const PORT = 1415;
const app = express();

// ===== HTTPS (required by real browsers for mic access + push notifications) =====
// install-1.sh generates a self-signed cert/key into ~/peyamapp/cert.pem + key.pem.
// If they're missing for any reason we fall back to plain HTTP (mic/notifications
// will NOT work over HTTP on a phone, only on http://localhost).
let server;
const certPath = path.join(__dirname, 'cert.pem');
const keyPath = path.join(__dirname, 'key.pem');
if (fs.existsSync(certPath) && fs.existsSync(keyPath)) {
  server = https.createServer({ cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath) }, app);
} else {
  console.log('⚠️  No cert.pem/key.pem found — running over plain HTTP. Mic & notifications will only work on http://localhost.');
  server = http.createServer(app);
}

const io = new Server(server, {
  maxHttpBufferSize: 50 * 1024 * 1024 // allow ~50MB messages so photos/videos over socket.io don't get silently dropped
});
app.use(cors());
app.use(express.json({ limit: '50mb' }));
app.use(express.static(path.join(__dirname, 'public')));

function nowTime() {
  const d = new Date();
  return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
}

const users = {};        // email -> user
const sessions = {};     // token -> email
const codes = {};        // email -> { code, expires }
const messages = {};     // chatId -> [msg]
const onlineSockets = {}; // socketId -> email
const stories = {};      // username -> [{ id, image, text, time, expires }]

function genToken() { return Math.random().toString(36).slice(2) + Date.now().toString(36); }
function genCode() { return '1234'; }
function gen2FACode() { return '123456'; }
function chatId(a, b) { return [a, b].sort().join('::'); }
function newUser(email) {
  return {
    email, username: '', name: '', about: 'Hey there! I am using PeyamApp.',
    avatar: '', twoFA: false, twoFALastVerified: 0, twoFAPending: false,
    passkey: '', privacy: { lastSeen: 'everyone', profilePic: 'everyone', about: 'everyone', status: 'everyone', readReceipts: true }
  };
}

function cleanStories() {
  const now = Date.now();
  for (const u in stories) stories[u] = stories[u].filter(s => s.expires > now);
}
setInterval(cleanStories, 60 * 1000);

// ===== AUTH =====
app.post('/api/send-code', (req, res) => {
  const { email } = req.body;
  if (!email) return res.json({ ok: false, msg: 'Email required' });
  codes[email] = { code: genCode(), expires: Date.now() + 10 * 60 * 1000 };
  console.log(`[TEST] Login code for ${email}: ${codes[email].code}`);
  res.json({ ok: true });
});

app.post('/api/verify-code', (req, res) => {
  const { email, code } = req.body;
  const rec = codes[email];
  if (!rec || rec.code !== code || Date.now() > rec.expires) return res.json({ ok: false, msg: 'Wrong or expired code' });
  delete codes[email];
  const isNew = !users[email];
  if (isNew) users[email] = newUser(email);
  const token = genToken();
  sessions[token] = email;
  res.json({ ok: true, token, isNew });
});

app.post('/api/setup-profile', (req, res) => {
  const { token, username, name } = req.body;
  const email = sessions[token];
  if (!email) return res.json({ ok: false, msg: 'Not authenticated' });
  if (!username || !name) return res.json({ ok: false, msg: 'Username and name required' });
  if (username[0] !== '@') return res.json({ ok: false, msg: 'Username must start with @' });
  const taken = Object.values(users).find(u => u.username === username && u.email !== email);
  if (taken) return res.json({ ok: false, msg: 'Username already taken' });
  users[email].username = username;
  users[email].name = name;
  res.json({ ok: true });
});

app.get('/api/me', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email || !users[email]) return res.json({ ok: false });
  const u = users[email];
  const needs2FA = u.twoFA && (Date.now() - u.twoFALastVerified > 24 * 60 * 60 * 1000);
  res.json({ ok: true, user: sanitize(u), needs2FA });
});

function sanitize(u) {
  return { email: u.email, username: u.username, name: u.name, about: u.about, avatar: u.avatar, twoFA: u.twoFA, passkeySet: !!u.passkey, privacy: u.privacy };
}

app.post('/api/update-profile', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  const { name, username, about, avatar } = req.body;
  if (username && username[0] !== '@') return res.json({ ok: false, msg: 'Username must start with @' });
  if (username) {
    const taken = Object.values(users).find(u => u.username === username && u.email !== email);
    if (taken) return res.json({ ok: false, msg: 'Username taken' });
    users[email].username = username;
  }
  if (name !== undefined) users[email].name = name;
  if (about !== undefined) users[email].about = about;
  if (avatar !== undefined) users[email].avatar = avatar;
  res.json({ ok: true });
});

app.post('/api/change-email', (req, res) => {
  const token = req.headers.authorization;
  const oldEmail = sessions[token];
  if (!oldEmail) return res.json({ ok: false });
  const { newEmail, code } = req.body;
  const rec = codes[newEmail];
  if (!rec || rec.code !== code || Date.now() > rec.expires) return res.json({ ok: false, msg: 'Wrong or expired code' });
  if (users[newEmail]) return res.json({ ok: false, msg: 'Email already in use' });
  const u = users[oldEmail];
  u.email = newEmail;
  users[newEmail] = u;
  delete users[oldEmail];
  delete codes[newEmail];
  sessions[token] = newEmail;
  res.json({ ok: true });
});

// ===== 2FA (real toggle flow with setup code) =====
app.post('/api/request-2fa-code', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  const code = gen2FACode();
  users[email].twoFASetupCode = code;
  console.log(`[TEST] 2FA setup code for ${email}: ${code}`);
  res.json({ ok: true });
});

app.post('/api/confirm-2fa-setup', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  const { code } = req.body;
  if (code !== users[email].twoFASetupCode) return res.json({ ok: false, msg: 'Wrong code' });
  users[email].twoFA = true;
  users[email].twoFALastVerified = Date.now();
  users[email].twoFASetupCode = null;
  res.json({ ok: true });
});

app.post('/api/disable-2fa', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  users[email].twoFA = false;
  res.json({ ok: true });
});

app.post('/api/request-2fa-recheck', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  console.log(`[TEST] 2FA recheck code for ${email}: 123456`);
  res.json({ ok: true });
});

app.post('/api/verify-2fa-recheck', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  const { code } = req.body;
  if (code !== '123456') return res.json({ ok: false, msg: 'Wrong code' });
  users[email].twoFALastVerified = Date.now();
  res.json({ ok: true });
});

// ===== PASSKEY =====
app.post('/api/set-passkey', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  const { passkey } = req.body;
  if (!passkey || passkey.length !== 6) return res.json({ ok: false, msg: 'Passkey must be 6 digits' });
  users[email].passkey = passkey;
  res.json({ ok: true });
});
app.post('/api/remove-passkey', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  users[email].passkey = '';
  res.json({ ok: true });
});

// ===== PRIVACY =====
app.post('/api/update-privacy', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  const { privacy } = req.body;
  users[email].privacy = { ...users[email].privacy, ...privacy };
  res.json({ ok: true });
});

// ===== USER LOOKUP (privacy-aware) =====
app.get('/api/user/:username', (req, res) => {
  const u = Object.values(users).find(u => u.username === req.params.username);
  if (!u) return res.json({ ok: false, msg: 'User not found' });
  const isOnline = Object.values(onlineSockets).includes(u.email);
  const priv = u.privacy || {};
  const showLastSeen = priv.lastSeen !== 'nobody';
  res.json({
    ok: true,
    user: {
      username: u.username,
      name: u.name,
      about: priv.about !== 'nobody' ? u.about : '',
      avatar: priv.profilePic !== 'nobody' ? u.avatar : '',
      online: showLastSeen ? isOnline : null,
      readReceipts: priv.readReceipts
    }
  });
});

app.get('/api/messages/:chatId', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  res.json({ ok: true, messages: messages[req.params.chatId] || [] });
});

app.get('/api/chats', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  const myUsername = users[email]?.username;
  const myChats = [];
  for (const [cid, msgs] of Object.entries(messages)) {
    const parts = cid.split('::');
    if (parts.includes(myUsername)) {
      const last = msgs[msgs.length - 1];
      const other = parts.find(p => p !== myUsername) || parts[0];
      let preview = last?.text || '';
      if (last?.image) preview = '📷 Photo';
      if (last?.video) preview = '🎥 Video';
      myChats.push({ chatId: cid, other, lastMsg: preview, lastTime: last?.time || '' });
    }
  }
  res.json({ ok: true, chats: myChats });
});

// ===== STORIES =====
app.post('/api/post-story', (req, res) => {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) return res.json({ ok: false });
  const username = users[email].username;
  const { image, text } = req.body;
  if (!stories[username]) stories[username] = [];
  stories[username].push({ id: Date.now(), image: image || null, text: text || '', time: nowTime(), expires: Date.now() + 24 * 60 * 60 * 1000 });
  res.json({ ok: true });
});

app.get('/api/stories', (req, res) => {
  cleanStories();
  const all = [];
  for (const [username, list] of Object.entries(stories)) {
    if (list.length) {
      const u = Object.values(users).find(u => u.username === username);
      all.push({ username, avatar: u?.avatar || '', items: list });
    }
  }
  res.json({ ok: true, stories: all });
});

app.get('/api/stories/:username', (req, res) => {
  cleanStories();
  res.json({ ok: true, items: stories[req.params.username] || [] });
});

// ===== SOCKET =====
io.on('connection', (socket) => {
  socket.on('auth', (token) => {
    const email = sessions[token];
    if (!email || !users[email]) return;
    socket.email = email;
    socket.username = users[email].username;
    onlineSockets[socket.id] = email;
    io.emit('online', Object.values(onlineSockets).map(e => users[e]?.username).filter(Boolean));
  });

  socket.on('sendMsg', ({ to, text, image, video }) => {
    if (!socket.username) return;
    const cid = chatId(socket.username, to);
    if (!messages[cid]) messages[cid] = [];
    const msg = { from: socket.username, to, text: text || '', image: image || null, video: video || null, time: nowTime(), id: Date.now(), edited: false, deleted: false };
    messages[cid].push(msg);
    Object.entries(onlineSockets).forEach(([sid, email]) => {
      const u = users[email];
      if (u && (u.username === to || u.username === socket.username)) io.to(sid).emit('newMsg', { ...msg, chatId: cid });
    });
  });

  // ===== EDIT MESSAGE =====
  socket.on('editMsg', ({ chatId: cid, id, text }) => {
    if (!socket.username || !messages[cid]) return;
    const msg = messages[cid].find(m => m.id === id);
    if (!msg || msg.from !== socket.username || msg.deleted) return; // only the sender can edit, own message only
    msg.text = text;
    msg.edited = true;
    const parts = cid.split('::');
    Object.entries(onlineSockets).forEach(([sid, email]) => {
      const u = users[email];
      if (u && parts.includes(u.username)) io.to(sid).emit('msgEdited', { chatId: cid, id, text });
    });
  });

  // ===== DELETE MESSAGE (for everyone) =====
  socket.on('deleteMsg', ({ chatId: cid, id }) => {
    if (!socket.username || !messages[cid]) return;
    const msg = messages[cid].find(m => m.id === id);
    if (!msg || msg.from !== socket.username) return; // only the sender can delete-for-everyone
    msg.deleted = true;
    msg.text = ''; msg.image = null; msg.video = null;
    const parts = cid.split('::');
    Object.entries(onlineSockets).forEach(([sid, email]) => {
      const u = users[email];
      if (u && parts.includes(u.username)) io.to(sid).emit('msgDeleted', { chatId: cid, id });
    });
  });

  socket.on('callUser', ({ to }) => {
    Object.entries(onlineSockets).forEach(([sid, email]) => { const u = users[email]; if (u && u.username === to) io.to(sid).emit('incomingCall', { from: socket.username }); });
  });
  socket.on('callResponse', ({ to, accepted }) => {
    Object.entries(onlineSockets).forEach(([sid, email]) => { const u = users[email]; if (u && u.username === to) io.to(sid).emit('callResponse', { accepted, from: socket.username }); });
  });
  socket.on('endCall', ({ to }) => {
    Object.entries(onlineSockets).forEach(([sid, email]) => { const u = users[email]; if (u && u.username === to) io.to(sid).emit('callEnded'); });
  });

  // ===== WEBRTC SIGNALING (real voice call audio) =====
  socket.on('rtc-offer', ({ to, offer }) => {
    Object.entries(onlineSockets).forEach(([sid, email]) => { const u = users[email]; if (u && u.username === to) io.to(sid).emit('rtc-offer', { from: socket.username, offer }); });
  });
  socket.on('rtc-answer', ({ to, answer }) => {
    Object.entries(onlineSockets).forEach(([sid, email]) => { const u = users[email]; if (u && u.username === to) io.to(sid).emit('rtc-answer', { from: socket.username, answer }); });
  });
  socket.on('rtc-ice', ({ to, candidate }) => {
    Object.entries(onlineSockets).forEach(([sid, email]) => { const u = users[email]; if (u && u.username === to) io.to(sid).emit('rtc-ice', { from: socket.username, candidate }); });
  });

  socket.on('disconnect', () => {
    delete onlineSockets[socket.id];
    io.emit('online', Object.values(onlineSockets).map(e => users[e]?.username).filter(Boolean));
  });
});

server.listen(PORT, () => {
  const proto = (fs.existsSync(certPath) && fs.existsSync(keyPath)) ? 'https' : 'http';
  console.log(`✅ PeyamApp v5: ${proto}://localhost:${PORT}  (or ${proto}://<your-phone-ip>:${PORT} from other devices)`);
});
SRVEOF

cat > public/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<title>PeyamApp</title>
<script src="/socket.io/socket.io.js"></script>
<style>
*{margin:0;padding:0;box-sizing:border-box;-webkit-tap-highlight-color:transparent}
:root{--bg:#0b141a;--hdr:#1a2630;--sf:#1f2c34;--sf2:#2a3942;--pr:#7c5cff;--pr2:#9b7eff;--tx:#e9edef;--mu:#8696a0;--bd:#2a3942;--bme:#5b4bdb;--bot:#202c33;--red:#ef4444;--grn:#4ade80}
body{font-family:-apple-system,Helvetica,Arial,sans-serif;background:var(--bg);color:var(--tx);height:100vh;overflow:hidden}
.screen{width:100%;max-width:480px;height:100vh;position:fixed;top:0;left:50%;transform:translateX(-50%);display:flex;flex-direction:column;opacity:0;pointer-events:none;transition:opacity .25s;overflow:hidden}
.screen.active{opacity:1;pointer-events:all}
input,button,select{font-family:inherit}
.pa-logo-svg{width:100%;height:100%}
#splash{align-items:center;justify-content:center;gap:16px;background:radial-gradient(circle at 50% 30%,#1a1230,#0b141a 70%)}
.slogo{width:96px;height:96px;border-radius:28px;background:linear-gradient(135deg,var(--pr),var(--pr2));display:flex;align-items:center;justify-content:center;box-shadow:0 0 50px rgba(124,92,255,.45);animation:pulse 2.2s infinite}
@keyframes pulse{0%,100%{transform:scale(1) rotate(0)}50%{transform:scale(1.05) rotate(2deg)}}
.slogo svg{width:54px;height:54px}
.sname{font-size:27px;font-weight:700;letter-spacing:.3px;background:linear-gradient(90deg,var(--pr2),#fff);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.sdots{display:flex;gap:6px;margin-top:6px}
.dot{width:7px;height:7px;border-radius:50%;background:var(--pr2);animation:bop 1.4s infinite}
.dot:nth-child(2){animation-delay:.2s}.dot:nth-child(3){animation-delay:.4s}
@keyframes bop{0%,80%,100%{opacity:.3;transform:translateY(0)}40%{opacity:1;transform:translateY(-5px)}}

/* LANGUAGE */
#language-screen{overflow-y:auto;padding:52px 18px 24px;background:var(--bg)}
.ltitle{font-size:20px;font-weight:600;margin-bottom:5px}
.lsub{color:var(--mu);font-size:13px;margin-bottom:18px}
.litem{background:var(--sf);border:1.5px solid transparent;border-radius:12px;padding:12px 14px;display:flex;align-items:center;gap:11px;cursor:pointer;margin-bottom:8px;transition:border-color .2s}
.litem.sel{border-color:var(--pr2)}
.lflag{font-size:23px}
.linfo{flex:1}
.lname{font-size:14px;font-weight:500}
.lnat{font-size:11px;color:var(--mu);margin-top:1px}
.lcheck{width:20px;height:20px;border-radius:50%;border:2px solid var(--mu);display:flex;align-items:center;justify-content:center}
.litem.sel .lcheck{background:var(--pr2);border-color:var(--pr2)}
.litem.sel .lcheck::after{content:'✓';color:#fff;font-size:11px;font-weight:700}
.btn{width:100%;padding:14px;background:linear-gradient(135deg,var(--pr),var(--pr2));color:#fff;border:none;border-radius:28px;font-size:15px;font-weight:600;cursor:pointer;margin-top:10px}
.btn:disabled{opacity:.4}

#auth-screen{background:var(--bg);padding:0}
.auth-hdr{background:var(--hdr);padding:48px 16px 14px;display:flex;align-items:center;gap:12px}
.back-btn{background:none;border:none;color:var(--tx);font-size:22px;cursor:pointer;width:30px;flex-shrink:0}
.auth-hdr-title{font-size:18px;font-weight:500}
.auth-body{padding:28px 22px;flex:1;display:flex;flex-direction:column;overflow-y:auto}
.auth-logo{width:78px;height:78px;border-radius:22px;background:linear-gradient(135deg,var(--pr),var(--pr2));display:flex;align-items:center;justify-content:center;margin:0 auto 20px}
.auth-logo svg{width:44px;height:44px}
.auth-title{font-size:22px;font-weight:500;text-align:center;margin-bottom:8px}
.auth-sub{color:var(--mu);font-size:13px;text-align:center;line-height:1.6;margin-bottom:28px}
.field-lbl{color:var(--pr2);font-size:11px;font-weight:600;letter-spacing:.5px;margin-bottom:6px}
.field-row{border-bottom:1.5px solid var(--bd);margin-bottom:24px;padding-bottom:8px}
.field-row input,.field-row select{width:100%;background:transparent;border:none;color:var(--tx);font-size:16px;outline:none;padding:4px 0}
.field-row input::placeholder{color:var(--mu)}
.field-row:focus-within{border-color:var(--pr2)}
.btn-main{width:100%;padding:14px;background:linear-gradient(135deg,var(--pr),var(--pr2));color:#fff;border:none;border-radius:28px;font-size:15px;font-weight:600;cursor:pointer;margin-top:4px;transition:opacity .2s}
.btn-main:disabled{opacity:.4}
.btn-main:active{opacity:.8}
.hint-txt{color:var(--mu);font-size:12px;text-align:center;margin-top:12px;line-height:1.6}
.otp-boxes{display:flex;gap:12px;justify-content:center;margin:24px 0 16px}
.otp-box{width:52px;height:56px;background:var(--sf);border:none;border-bottom:2px solid var(--mu);border-radius:6px 6px 0 0;font-size:24px;font-weight:700;text-align:center;color:var(--tx);outline:none}
.otp-box:focus{border-color:var(--pr2)}
.test-badge{background:rgba(124,92,255,.12);border:1px solid rgba(124,92,255,.3);border-radius:8px;padding:9px 14px;font-size:12px;color:var(--pr2);text-align:center;margin-bottom:16px}

#setup-screen{background:var(--bg)}
.setup-body{padding:24px 22px;flex:1;overflow-y:auto}
.setup-avatar{width:84px;height:84px;border-radius:50%;background:var(--sf2);display:flex;align-items:center;justify-content:center;font-size:32px;margin:0 auto 22px;cursor:pointer;overflow:hidden;position:relative;color:var(--mu);border:2px dashed var(--bd)}
.setup-avatar img{width:100%;height:100%;object-fit:cover;position:absolute;inset:0}

#main-screen{background:var(--bg)}
.main-hdr{background:var(--hdr);padding:48px 14px 12px;display:flex;align-items:center;justify-content:space-between;flex-shrink:0}
.main-hdr-left{display:flex;align-items:center;gap:10px}
.main-logo-sm{width:32px;height:32px;border-radius:9px;background:linear-gradient(135deg,var(--pr),var(--pr2));display:flex;align-items:center;justify-content:center;flex-shrink:0}
.main-logo-sm svg{width:19px;height:19px}
.main-title{font-size:20px;font-weight:600}
.main-icons{display:flex;gap:2px;position:relative}
.icon-btn{background:none;border:none;color:var(--tx);font-size:18px;cursor:pointer;width:36px;height:36px;display:flex;align-items:center;justify-content:center;border-radius:50%}
.icon-btn:active{background:var(--sf2)}
.search-bar{margin:8px 12px;background:var(--sf);border-radius:10px;padding:10px 14px;display:flex;align-items:center;gap:8px;color:var(--mu);font-size:14px;flex-shrink:0;cursor:pointer}
.tabs{display:flex;gap:4px;padding:6px 12px 10px;flex-shrink:0}
.tab{padding:6px 14px;border-radius:16px;font-size:12px;background:var(--sf);color:var(--mu);cursor:pointer}
.tab.a{background:rgba(124,92,255,.22);color:var(--pr2);font-weight:600}
.tab-content{flex:1;overflow-y:auto;display:none}
.tab-content.show{display:block}
.chat-list{flex:1;overflow-y:auto}
.chat-item{display:flex;align-items:center;gap:12px;padding:10px 14px;cursor:pointer}
.chat-item:active{background:var(--sf)}
.ci-avatar{width:50px;height:50px;border-radius:50%;background:linear-gradient(135deg,var(--pr),var(--pr2));display:flex;align-items:center;justify-content:center;font-size:20px;flex-shrink:0;overflow:hidden;position:relative;color:#fff}
.ci-avatar img{width:100%;height:100%;object-fit:cover}
.verified-badge{position:absolute;bottom:-1px;right:-1px;width:16px;height:16px;background:#3b9ddd;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:9px;border:2px solid var(--bg)}
.ci-info{flex:1;border-bottom:1px solid var(--bd);padding-bottom:10px;min-width:0}
.ci-name{font-size:15px;font-weight:500;margin-bottom:3px;display:flex;align-items:center;gap:6px}
.ci-preview{font-size:12.5px;color:var(--mu);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.ci-meta{display:flex;flex-direction:column;align-items:flex-end;gap:4px;padding-bottom:10px}
.ci-time{font-size:11px;color:var(--mu)}
.ci-badge{background:var(--pr2);color:#0b141a;font-size:11px;font-weight:700;min-width:20px;height:20px;border-radius:10px;display:flex;align-items:center;justify-content:center;padding:0 5px}
.fab{position:absolute;bottom:20px;right:16px;width:54px;height:54px;background:linear-gradient(135deg,var(--pr),var(--pr2));border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:26px;box-shadow:0 3px 16px rgba(124,92,255,.5);cursor:pointer;border:none;color:#fff;z-index:10}
.fab:active{transform:scale(.92)}
.dropdown{position:absolute;top:46px;right:0;background:var(--sf);border-radius:10px;padding:6px 0;box-shadow:0 4px 20px rgba(0,0,0,.5);z-index:100;min-width:170px;display:none}
.dropdown.open{display:block;animation:fadein .15s}
@keyframes fadein{from{opacity:0;transform:translateY(-6px)}to{opacity:1;transform:translateY(0)}}
.dd-item{padding:12px 18px;font-size:14px;cursor:pointer;display:flex;align-items:center;gap:10px}
.dd-item:active{background:var(--sf2)}

/* STORIES STRIP */
.stories-strip{display:flex;gap:12px;padding:12px 14px;overflow-x:auto;flex-shrink:0;border-bottom:1px solid var(--bd)}
.story-item{display:flex;flex-direction:column;align-items:center;gap:5px;cursor:pointer;flex-shrink:0;width:62px}
.story-ring{width:56px;height:56px;border-radius:50%;padding:2px;background:linear-gradient(135deg,var(--pr),var(--pr2));display:flex;align-items:center;justify-content:center}
.story-ring.seen{background:var(--bd)}
.story-ring.add{background:var(--sf2)}
.story-av{width:100%;height:100%;border-radius:50%;background:var(--sf2);display:flex;align-items:center;justify-content:center;font-size:22px;overflow:hidden;color:#fff;border:2px solid var(--bg)}
.story-av img{width:100%;height:100%;object-fit:cover}
.story-label{font-size:10.5px;color:var(--mu);text-align:center;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;width:100%}
.add-story-plus{position:absolute;bottom:-2px;right:-2px;width:18px;height:18px;background:var(--pr2);border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:12px;color:#fff;border:2px solid var(--bg)}

/* STORY VIEWER */
#story-viewer{background:#000}
.sv-progress{display:flex;gap:4px;padding:48px 10px 8px}
.sv-bar{flex:1;height:2.5px;background:rgba(255,255,255,.3);border-radius:2px;overflow:hidden}
.sv-bar-fill{height:100%;background:#fff;width:0%}
.sv-header{display:flex;align-items:center;gap:10px;padding:6px 14px 10px}
.sv-av{width:34px;height:34px;border-radius:50%;background:var(--sf2);overflow:hidden;flex-shrink:0}
.sv-av img{width:100%;height:100%;object-fit:cover}
.sv-name{font-size:14px;font-weight:600;color:#fff}
.sv-time{font-size:11px;color:rgba(255,255,255,.6)}
.sv-close{color:#fff;font-size:24px;margin-left:auto;cursor:pointer}
.sv-body{flex:1;display:flex;align-items:center;justify-content:center;position:relative;overflow:hidden}
.sv-img{max-width:100%;max-height:100%;object-fit:contain}
.sv-text{color:#fff;font-size:20px;text-align:center;padding:30px;font-weight:500}
.sv-tap-zone{position:absolute;top:0;bottom:0;width:50%}

/* CREATE STORY */
#create-story-screen{background:#000}
.cs-hdr{padding:48px 16px 12px;display:flex;align-items:center;justify-content:space-between}
.cs-hdr button{background:rgba(255,255,255,.15);border:none;color:#fff;width:36px;height:36px;border-radius:50%;font-size:18px}
.cs-preview{flex:1;display:flex;align-items:center;justify-content:center;padding:0 16px;overflow:hidden}
.cs-preview img{max-width:100%;max-height:100%;border-radius:12px;object-fit:contain}
.cs-text-input{width:100%;background:rgba(0,0,0,.4);border:none;color:#fff;font-size:18px;text-align:center;padding:16px;outline:none}
.cs-footer{padding:16px;display:flex;gap:10px}
.cs-footer .btn-main{flex:1}

#chat-screen{background:var(--bg)}
.chat-hdr{background:var(--hdr);padding:46px 10px 10px;display:flex;align-items:center;gap:9px;flex-shrink:0}
.chat-back{color:var(--tx);font-size:22px;cursor:pointer;width:28px;flex-shrink:0}
.chat-av{width:38px;height:38px;border-radius:50%;background:linear-gradient(135deg,var(--pr),var(--pr2));display:flex;align-items:center;justify-content:center;font-size:16px;flex-shrink:0;overflow:hidden;cursor:pointer;color:#fff}
.chat-av img{width:100%;height:100%;object-fit:cover}
.chat-hdr-info{flex:1;cursor:pointer;min-width:0}
.chat-name{font-size:15px;font-weight:500;display:flex;align-items:center;gap:5px}
.chat-sub{font-size:12px;color:var(--mu)}
.chat-sub.on{color:var(--grn)}
.call-btn{background:none;border:none;color:var(--tx);font-size:19px;cursor:pointer;width:36px;height:36px;flex-shrink:0}
.msgs{flex:1;overflow-y:auto;-webkit-overflow-scrolling:touch;padding:10px 8px;display:flex;flex-direction:column;gap:4px;background:#0b141a;overscroll-behavior:contain}
.msgs::-webkit-scrollbar{width:0}
.bbl{max-width:80%;padding:7px 10px 4px;border-radius:10px;font-size:14.5px;line-height:1.45;word-break:break-word;position:relative}
.bbl.me{background:var(--bme);align-self:flex-end;border-top-right-radius:2px}
.bbl.ot{background:var(--bot);align-self:flex-start;border-top-left-radius:2px}
.bbl.sy{background:rgba(255,255,255,.05);align-self:center;color:var(--mu);font-size:11.5px;border-radius:8px;padding:5px 12px}
.bbl.saved{background:var(--sf);align-self:flex-start;border-top-left-radius:2px}
.bbl img.msg-img{max-width:100%;border-radius:8px;display:block;margin-top:2px}
.bbl video.msg-vid{max-width:100%;border-radius:8px;display:block;margin-top:2px}
.btime{font-size:10px;color:rgba(255,255,255,.4);float:right;margin-left:8px;margin-top:4px}
.read-tick{font-size:10px;color:rgba(255,255,255,.6);margin-left:3px}
.cin-wrap{background:var(--hdr);padding:8px 8px 24px;display:flex;align-items:center;gap:7px;flex-shrink:0;border-top:1px solid var(--bd)}
.cin{flex:1;background:var(--sf);border:none;border-radius:24px;padding:11px 15px;color:var(--tx);font-size:15px;outline:none;min-width:0}
.cin::placeholder{color:var(--mu)}
.attach-btn{width:40px;height:40px;background:none;border:none;color:var(--mu);font-size:22px;cursor:pointer;display:flex;align-items:center;justify-content:center;flex-shrink:0}
.snd-btn{width:42px;height:42px;background:linear-gradient(135deg,var(--pr),var(--pr2));border:none;border-radius:50%;color:#fff;font-size:19px;cursor:pointer;display:flex;align-items:center;justify-content:center;flex-shrink:0}
.snd-btn:active{opacity:.8}
#file-input,#video-input,#story-file-input{display:none}
.img-preview-bar{background:var(--hdr);padding:8px 12px;display:none;align-items:center;gap:10px;border-top:1px solid var(--bd)}
.img-preview-bar img,.img-preview-bar video{width:46px;height:46px;border-radius:8px;object-fit:cover}
.img-preview-bar .cancel-img{color:var(--red);font-size:13px;cursor:pointer;margin-left:auto}

#profile-screen,#user-profile-screen,#security-screen,#privacy-screen,#find-user-screen,#change-email-screen,#passkey-screen{background:var(--bg)}
.prof-hdr{background:var(--hdr);padding:46px 14px 14px;display:flex;align-items:center;gap:12px;flex-shrink:0}
.prof-body{flex:1;overflow-y:auto}
.prof-cover{background:linear-gradient(180deg,var(--pr) 0%,var(--hdr) 100%);padding:28px 20px 16px;display:flex;flex-direction:column;align-items:center;gap:10px}
.prof-avatar{width:90px;height:90px;border-radius:50%;background:var(--sf2);display:flex;align-items:center;justify-content:center;font-size:36px;overflow:hidden;cursor:pointer;position:relative;color:#fff}
.prof-avatar img{width:100%;height:100%;object-fit:cover;position:absolute;inset:0}
.prof-name{font-size:22px;font-weight:600;display:flex;align-items:center;gap:6px}
.prof-username{color:var(--pr2);font-size:14px}
.prof-section{padding:8px 0;border-bottom:1px solid var(--bd)}
.prof-section:last-child{border-bottom:none}
.prof-section-title{padding:14px 20px 6px;color:var(--pr2);font-size:12px;font-weight:600;letter-spacing:.4px}
.toggle-row{padding:14px 20px;display:flex;align-items:center;justify-content:space-between}
.toggle{width:46px;height:26px;background:var(--sf2);border-radius:13px;cursor:pointer;position:relative;transition:background .2s;flex-shrink:0}
.toggle.on{background:var(--pr)}
.toggle-knob{width:22px;height:22px;background:white;border-radius:50%;position:absolute;top:2px;left:2px;transition:left .2s}
.toggle.on .toggle-knob{left:22px}
.sec-info{padding:14px 20px;color:var(--mu);font-size:13px;line-height:1.6}
.prof-edit-input{width:100%}
.nav-row{padding:14px 20px;display:flex;align-items:center;gap:14px;cursor:pointer}
.nav-row:active{background:var(--sf)}
.nav-icon{font-size:18px;width:24px}
.nav-label{flex:1;font-size:15px}
.nav-val{color:var(--mu);font-size:13px}
.nav-arrow{color:var(--mu)}
.radio-row{padding:13px 20px;display:flex;align-items:center;justify-content:space-between;cursor:pointer}
.radio-row:active{background:var(--sf)}
.radio-circle{width:20px;height:20px;border-radius:50%;border:2px solid var(--mu);display:flex;align-items:center;justify-content:center}
.radio-circle.sel{border-color:var(--pr2)}
.radio-circle.sel::after{content:'';width:10px;height:10px;border-radius:50%;background:var(--pr2)}

.find-input-wrap{padding:14px 16px;border-bottom:1px solid var(--bd)}
.find-input{flex:1;width:100%;background:var(--sf);border:none;border-radius:24px;padding:11px 16px;color:var(--tx);font-size:15px;outline:none}
.find-input::placeholder{color:var(--mu)}
.saved-row{display:flex;align-items:center;gap:14px;padding:14px 16px;cursor:pointer;border-bottom:1px solid var(--bd)}
.saved-row:active{background:var(--sf)}
.saved-row-av{width:48px;height:48px;border-radius:50%;background:linear-gradient(135deg,var(--pr),var(--pr2));display:flex;align-items:center;justify-content:center;font-size:22px;flex-shrink:0;position:relative;color:#fff}
.user-card{padding:16px 16px;display:flex;align-items:center;gap:14px;cursor:pointer}
.user-card:active{background:var(--sf)}
.uc-av{width:50px;height:50px;border-radius:50%;background:linear-gradient(135deg,var(--pr),var(--pr2));display:flex;align-items:center;justify-content:center;font-size:20px;overflow:hidden;flex-shrink:0;color:#fff}
.uc-av img{width:100%;height:100%;object-fit:cover}
.uc-name{font-size:15px;font-weight:500}
.uc-un{color:var(--pr2);font-size:13px;margin-top:1px}
.uc-about{color:var(--mu);font-size:12.5px;margin-top:2px}
.empty-state{display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1;color:var(--mu);gap:10px;padding:40px;text-align:center}
.empty-icon{font-size:46px;opacity:.4}
.overlay{position:fixed;inset:0;background:rgba(0,0,0,.8);z-index:500;display:none;align-items:center;justify-content:center;padding:24px}
.overlay.open{display:flex}
.tfa-card{background:var(--sf);border-radius:18px;padding:28px 22px;width:100%;max-width:340px;text-align:center}
.tfa-icon{font-size:38px;margin-bottom:10px}
.tfa-title{font-size:18px;font-weight:600;margin-bottom:8px}
.tfa-sub{color:var(--mu);font-size:13px;line-height:1.6;margin-bottom:20px}
.toast{position:fixed;bottom:82px;left:50%;transform:translateX(-50%);background:var(--sf);border:1px solid var(--pr2);color:var(--pr2);padding:9px 22px;border-radius:24px;font-size:13px;opacity:0;transition:opacity .3s;pointer-events:none;z-index:600;white-space:nowrap;max-width:90%;text-align:center;cursor:pointer}
.toast.show{opacity:1;pointer-events:all}
.badge-blue-sm{display:inline-flex;align-items:center;justify-content:center;width:15px;height:15px;background:#3b9ddd;border-radius:50%;font-size:8px;color:white;flex-shrink:0}
#call-screen{background:linear-gradient(160deg,#1a1230,#0b141a);align-items:center;justify-content:space-between;padding:60px 30px 50px}
.call-top{display:flex;flex-direction:column;align-items:center;gap:14px;margin-top:40px}
.call-av{width:120px;height:120px;border-radius:50%;background:linear-gradient(135deg,var(--pr),var(--pr2));display:flex;align-items:center;justify-content:center;font-size:48px;color:#fff;overflow:hidden;animation:ringPulse 1.6s infinite}
@keyframes ringPulse{0%,100%{box-shadow:0 0 0 0 rgba(124,92,255,.5)}50%{box-shadow:0 0 0 20px rgba(124,92,255,0)}}
.call-av img{width:100%;height:100%;object-fit:cover}
.call-name{font-size:22px;font-weight:600}
.call-status{font-size:14px;color:var(--mu)}
.call-actions{display:flex;gap:30px;align-items:center}
.bbl{position:relative}
.msg-ctx-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.35);z-index:500;align-items:flex-end;justify-content:center}
.msg-ctx-overlay.open{display:flex}
.msg-ctx-sheet{background:var(--bg,#fff);width:100%;max-width:480px;border-radius:14px 14px 0 0;padding:8px 0;animation:slideUp .15s ease-out}
@keyframes slideUp{from{transform:translateY(20px);opacity:0}to{transform:translateY(0);opacity:1}}
.msg-ctx-item{padding:14px 20px;font-size:15px;cursor:pointer;display:flex;align-items:center;gap:10px}
.msg-ctx-item:active{background:rgba(0,0,0,.06)}
.msg-ctx-item.danger{color:#ef4444}
.msg-edited-tag{font-size:10px;opacity:.6;margin-left:4px}
.msg-deleted{font-style:italic;opacity:.6}
.call-mic-row{display:flex;justify-content:center;margin-top:14px}
.call-mic-btn{width:46px;height:46px;border-radius:50%;border:none;font-size:18px;background:rgba(255,255,255,.18);color:#fff;cursor:pointer}
.call-mic-btn.muted{background:#ef4444}
.btn-secondary{width:100%;padding:12px;border-radius:10px;border:1px solid #ccc;background:transparent;font-size:14px;cursor:pointer}
.call-btn-round{width:64px;height:64px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:26px;cursor:pointer;border:none}
.call-decline{background:var(--red);color:#fff}
.call-accept{background:var(--grn);color:#fff}
.call-hangup{background:var(--red);color:#fff;width:60px;height:60px}
</style>
</head>
<body>

<div class="screen active" id="splash">
  <div class="slogo"><svg class="pa-logo-svg" viewBox="0 0 48 48" fill="none"><path d="M24 4C12.96 4 4 12.06 4 22c0 5.1 2.32 9.7 6.13 12.97-.2 2.46-.93 5.1-2.13 7.03 3.05-.3 6.4-1.36 8.9-2.84A23.6 23.6 0 0024 40c11.04 0 20-8.06 20-18S35.04 4 24 4z" fill="white"/><path d="M16 22.5l16-6-5 16-3.2-6.2-6.4 4.2 1.6-5.4-3-2.6z" fill="#7c5cff"/></svg></div>
  <div class="sname">PeyamApp</div>
  <div class="sdots"><div class="dot"></div><div class="dot"></div><div class="dot"></div></div>
</div>

<!-- LANGUAGE -->
<div class="screen" id="language-screen">
  <div class="ltitle" id="lt">Choose your language</div>
  <div class="lsub" id="ls">Select your preferred language</div>
  <div id="lgrid"></div>
  <button class="btn" id="lbtn" onclick="goAuth()">Continue</button>
</div>

<div class="screen" id="auth-screen">
  <div class="auth-hdr"><button class="back-btn" id="auth-back" onclick="authBack()">←</button><div class="auth-hdr-title">PeyamApp</div></div>
  <div class="auth-body">
    <div id="step-email">
      <div class="auth-logo"><svg class="pa-logo-svg" viewBox="0 0 48 48" fill="none"><path d="M24 4C12.96 4 4 12.06 4 22c0 5.1 2.32 9.7 6.13 12.97-.2 2.46-.93 5.1-2.13 7.03 3.05-.3 6.4-1.36 8.9-2.84A23.6 23.6 0 0024 40c11.04 0 20-8.06 20-18S35.04 4 24 4z" fill="white"/><path d="M16 22.5l16-6-5 16-3.2-6.2-6.4 4.2 1.6-5.4-3-2.6z" fill="#7c5cff"/></svg></div>
      <div class="auth-title" id="atitle">Enter your email</div>
      <div class="auth-sub" id="asub">PeyamApp will send a free verification code to your email.</div>
      <div class="field-lbl" id="aemaillbl">EMAIL ADDRESS</div>
      <div class="field-row"><input type="email" id="email-in" placeholder="you@example.com" inputmode="email"></div>
      <div class="test-badge" id="atestbadge">🧪 Test mode — any email, code is <strong>1234</strong></div>
      <button class="btn-main" id="anextbtn" onclick="sendCode()">Next</button>
    </div>
    <div id="step-otp" style="display:none">
      <div class="auth-title" id="otitle">Enter verification code</div>
      <div class="auth-sub" id="osub">We sent a 4-digit code to<br><strong id="otp-email-show" style="color:var(--pr2)"></strong></div>
      <div class="otp-boxes">
        <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="o0">
        <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="o1">
        <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="o2">
        <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="o3">
      </div>
      <div class="test-badge">🧪 Use code <strong>1234</strong></div>
      <div class="hint-txt" style="cursor:pointer;color:var(--pr2)" id="ochangeemail" onclick="goStep('email')">← Change email</div>
    </div>
  </div>
</div>

<!-- SETUP PROFILE (professional, with avatar) -->
<div class="screen" id="setup-screen">
  <div class="auth-hdr" style="padding-top:48px"><div class="auth-hdr-title" id="setuptitle">Set up your profile</div></div>
  <div class="setup-body">
    <div class="auth-sub" style="text-align:left;margin-bottom:20px" id="setupsub">Add a photo and choose how others will see and find you.</div>
    <div class="setup-avatar" id="setup-avatar" onclick="document.getElementById('setup-av-input').click()">📷</div>
    <input type="file" id="setup-av-input" accept="image/*" style="display:none" onchange="handleSetupAvatar(event)">
    <div class="field-lbl" id="setupunlbl">USERNAME (starts with @)</div>
    <div class="field-row"><input type="text" id="setup-username" placeholder="@yourname"></div>
    <div class="field-lbl" id="setupnamelbl">DISPLAY NAME</div>
    <div class="field-row"><input type="text" id="setup-name" placeholder="Your name"></div>
    <div class="field-lbl" id="setupaboutlbl">ABOUT</div>
    <div class="field-row"><input type="text" id="setup-about" placeholder="Hey there! I am using PeyamApp."></div>
    <button class="btn-main" id="setupcontinuebtn" onclick="setupProfile()">Continue</button>
  </div>
</div>

<div class="screen" id="main-screen">
  <div class="main-hdr">
    <div class="main-hdr-left">
      <div class="main-logo-sm"><svg class="pa-logo-svg" viewBox="0 0 48 48" fill="none"><path d="M24 4C12.96 4 4 12.06 4 22c0 5.1 2.32 9.7 6.13 12.97-.2 2.46-.93 5.1-2.13 7.03 3.05-.3 6.4-1.36 8.9-2.84A23.6 23.6 0 0024 40c11.04 0 20-8.06 20-18S35.04 4 24 4z" fill="white"/><path d="M16 22.5l16-6-5 16-3.2-6.2-6.4 4.2 1.6-5.4-3-2.6z" fill="#7c5cff"/></svg></div>
      <div class="main-title">PeyamApp</div>
    </div>
    <div class="main-icons">
      <button class="icon-btn" onclick="show('find-user-screen')">🔍</button>
      <button class="icon-btn" id="menu-btn" onclick="toggleMenu()">⋮</button>
      <div class="dropdown" id="main-menu">
        <div class="dd-item" onclick="closeMenu();show('profile-screen');loadProfile()">👤 Profile</div>
        <div class="dd-item" onclick="closeMenu();show('find-user-screen')">🔗 Find by username</div>
        <div class="dd-item" onclick="closeMenu();markAllRead()">✅ Read all</div>
      </div>
    </div>
  </div>
  <div class="search-bar" onclick="show('find-user-screen')">🔍 <span>Search or find user...</span></div>
  <div class="tabs">
    <div class="tab a" id="tab-chats" onclick="switchTab('chats')">Chats</div>
    <div class="tab" id="tab-calls" onclick="switchTab('calls')">Calls</div>
    <div class="tab" id="tab-updates" onclick="switchTab('updates')">Updates</div>
  </div>
  <div class="tab-content show" id="content-chats">
    <div class="chat-list" id="chat-list"></div>
  </div>
  <div class="tab-content" id="content-calls">
    <div class="empty-state"><div class="empty-icon">📞</div><div>No call history yet</div></div>
  </div>
  <div class="tab-content" id="content-updates" style="overflow-y:auto">
    <div class="stories-strip" id="stories-strip"></div>
    <div id="stories-list"></div>
  </div>
  <button class="fab" id="main-fab" onclick="show('find-user-screen')">+</button>
</div>

<div class="screen" id="find-user-screen">
  <div class="prof-hdr"><button class="back-btn" onclick="show('main-screen')">←</button><div style="font-size:18px;font-weight:500">New chat</div></div>
  <div class="saved-row" onclick="openSaved()">
    <div class="saved-row-av">🔖</div>
    <div><div style="font-size:15px;font-weight:500;display:flex;align-items:center;gap:6px">Saved Messages <span class="badge-blue-sm">✓</span></div>
    <div style="font-size:12.5px;color:var(--mu)">Your personal notes</div></div>
  </div>
  <div class="find-input-wrap"><input class="find-input" type="text" id="find-input" placeholder="Enter @username..." oninput="findUser()"></div>
  <div id="find-result" style="flex:1;overflow-y:auto"><div class="empty-state"><div class="empty-icon">🔍</div><div>Search by @username</div></div></div>
</div>

<div class="screen" id="chat-screen">
  <div class="chat-hdr">
    <span class="chat-back" onclick="show('main-screen');loadChats()">←</span>
    <div class="chat-av" id="chat-av" onclick="viewUserProfile()">👤</div>
    <div class="chat-hdr-info" onclick="viewUserProfile()">
      <div class="chat-name" id="chat-name">Chat</div>
      <div class="chat-sub" id="chat-sub">tap for info</div>
    </div>
    <button class="call-btn" onclick="startCall()">📞</button>
  </div>
  <div class="msgs" id="msgs"></div>
  <div class="img-preview-bar" id="img-preview-bar">
    <img id="img-preview-thumb" src="" style="display:none">
    <video id="video-preview-thumb" style="display:none" muted></video>
    <span style="font-size:13px;color:var(--mu)" id="preview-label">Image ready to send</span>
    <span class="cancel-img" onclick="cancelImage()">Cancel</span>
  </div>
  <div class="cin-wrap">
    <button class="attach-btn" onclick="openAttachMenu()">📎</button>
    <input type="file" id="file-input" accept="image/*" onchange="handleImagePick(event)">
    <input type="file" id="video-input" accept="video/*" onchange="handleVideoPick(event)">
    <input class="cin" type="text" id="cin" placeholder="Message" autocomplete="off">
    <button class="snd-btn" id="snd-btn" onclick="sendMsg()">➤</button>
  </div>
</div>

<!-- MESSAGE CONTEXT MENU (long-press / right-click on a bubble) -->
<div class="msg-ctx-overlay" id="msg-ctx-overlay" onclick="if(event.target===this) closeMsgCtx()">
  <div class="msg-ctx-sheet" id="msg-ctx-sheet"></div>
</div>

<!-- EDIT MESSAGE OVERLAY -->
<div class="overlay" id="edit-msg-overlay">
  <div class="tfa-card">
    <div class="tfa-icon">✏️</div>
    <div class="tfa-title">Edit message</div>
    <div class="field-row"><input class="prof-edit-input" type="text" id="edit-msg-input" placeholder="Message"></div>
    <button class="btn-main" onclick="confirmEditMsg()">Save</button>
    <button class="btn-secondary" onclick="document.getElementById('edit-msg-overlay').classList.remove('open')" style="margin-top:8px">Cancel</button>
  </div>
</div>

<div class="screen" id="saved-screen">
  <div class="chat-hdr">
    <span class="chat-back" onclick="show('find-user-screen')">←</span>
    <div class="chat-av" style="background:linear-gradient(135deg,var(--pr),var(--pr2));font-size:18px">🔖</div>
    <div class="chat-hdr-info"><div class="chat-name">Saved Messages <span class="badge-blue-sm">✓</span></div><div class="chat-sub" style="color:var(--pr2)">Official PeyamApp space</div></div>
  </div>
  <div class="msgs" id="saved-msgs"></div>
  <div class="cin-wrap"><input class="cin" type="text" id="saved-cin" placeholder="Save a note..." autocomplete="off"><button class="snd-btn" onclick="sendSaved()">➤</button></div>
</div>

<div class="screen" id="profile-screen">
  <div class="prof-hdr">
    <button class="back-btn" onclick="show('main-screen')">←</button>
    <div style="font-size:18px;font-weight:500">Profile</div>
    <button class="btn-main" style="width:auto;padding:8px 18px;margin:0;margin-left:auto;font-size:13px" onclick="saveProfile()">Save</button>
  </div>
  <div class="prof-body">
    <div class="prof-cover">
      <div class="prof-avatar" id="my-avatar-big" onclick="document.getElementById('av-input').click()">👤</div>
      <input type="file" id="av-input" accept="image/*" style="display:none" onchange="handleAvatarChange(event)">
      <div class="prof-name" id="prof-name-show"></div>
      <div class="prof-username" id="prof-un-show"></div>
    </div>
    <div style="padding:16px 20px">
      <div class="field-lbl">DISPLAY NAME</div>
      <div class="field-row"><input class="prof-edit-input" type="text" id="edit-name" placeholder="Your name"></div>
      <div class="field-lbl">USERNAME</div>
      <div class="field-row"><input class="prof-edit-input" type="text" id="edit-username" placeholder="@username"></div>
      <div class="field-lbl">ABOUT / BIO</div>
      <div class="field-row"><input class="prof-edit-input" type="text" id="edit-about" placeholder="About me..."></div>
      <div style="height:8px"></div>
      <button class="btn-main" style="background:var(--sf2);color:var(--tx)" onclick="show('security-screen')">🔐 Security</button>
    </div>
  </div>
</div>

<div class="screen" id="user-profile-screen">
  <div class="prof-hdr"><button class="back-btn" id="upback-btn" onclick="history.back()">←</button><div style="font-size:18px;font-weight:500">Profile</div></div>
  <div class="prof-body">
    <div class="prof-cover">
      <div class="prof-avatar" id="up-avatar">👤</div>
      <div class="prof-name" id="up-name"></div>
      <div class="prof-username" id="up-username"></div>
      <div class="chat-sub" id="up-online" style="color:var(--grn)"></div>
    </div>
    <div style="padding:18px 20px">
      <div class="field-lbl">ABOUT</div>
      <div style="font-size:15px;color:var(--tx);padding:10px 0;border-bottom:1px solid var(--bd);margin-bottom:20px" id="up-about"></div>
      <button class="btn-main" onclick="chatWithViewed()">💬 Message</button>
    </div>
  </div>
</div>

<!-- SECURITY -->
<div class="screen" id="security-screen">
  <div class="prof-hdr"><button class="back-btn" onclick="show('profile-screen')">←</button><div style="font-size:18px;font-weight:500">Security</div></div>
  <div class="prof-body" style="padding:0 0 16px">
    <div class="nav-row" onclick="openTwoFAFlow()">
      <span class="nav-icon">🔐</span>
      <div class="nav-label">Two-step verification</div>
      <span class="nav-val" id="twofa-status-label">Off</span>
      <span class="nav-arrow">›</span>
    </div>
    <div class="nav-row" onclick="show('passkey-screen');loadPasskeyStatus()">
      <span class="nav-icon">🔑</span>
      <div class="nav-label">Passkey</div>
      <span class="nav-val" id="passkey-status-label">Not set</span>
      <span class="nav-arrow">›</span>
    </div>
    <div class="nav-row" onclick="show('change-email-screen')">
      <span class="nav-icon">✉️</span>
      <div class="nav-label">Change email</div>
      <span class="nav-arrow">›</span>
    </div>
    <div class="nav-row" onclick="show('privacy-screen');loadPrivacy()">
      <span class="nav-icon">🛡️</span>
      <div class="nav-label">Privacy</div>
      <span class="nav-arrow">›</span>
    </div>
  </div>
</div>

<!-- TWO-FA SETUP/RECHECK FLOW SCREEN -->
<div class="screen" id="twofa-flow-screen">
  <div class="prof-hdr"><button class="back-btn" onclick="show('security-screen')">←</button><div style="font-size:18px;font-weight:500">Two-step verification</div></div>
  <div class="prof-body">
    <div style="padding:24px 20px">
      <div id="twofa-flow-off" style="display:none">
        <div class="sec-info" style="padding:0 0 20px">Two-step verification adds extra security. A 6-digit code will be required every 24 hours when you open PeyamApp.</div>
        <button class="btn-main" onclick="requestTwoFASetup()">Enable Two-Step Verification</button>
      </div>
      <div id="twofa-flow-code" style="display:none">
        <div class="sec-info" style="padding:0 0 16px">Enter the 6-digit code to confirm and enable Two-step verification.</div>
        <div class="otp-boxes" style="justify-content:flex-start">
          <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="s0">
          <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="s1">
          <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="s2">
          <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="s3">
          <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="s4">
          <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="s5">
        </div>
        <div class="test-badge">🧪 Test code: <strong>123456</strong></div>
        <button class="btn-main" onclick="confirmTwoFASetup()">Confirm & Enable</button>
      </div>
      <div id="twofa-flow-on" style="display:none">
        <div class="sec-info" style="padding:0 0 20px">✓ Two-step verification is enabled. You'll be asked for a code every 24 hours.</div>
        <button class="btn-main" style="background:var(--red)" onclick="disableTwoFA()">Turn Off</button>
      </div>
    </div>
  </div>
</div>

<!-- PASSKEY SCREEN -->
<div class="screen" id="passkey-screen">
  <div class="prof-hdr"><button class="back-btn" onclick="show('security-screen')">←</button><div style="font-size:18px;font-weight:500">Passkey</div></div>
  <div class="prof-body">
    <div style="padding:24px 20px">
      <div class="sec-info" style="padding:0 0 20px">Set a 6-digit passkey to lock PeyamApp. You'll need to enter it to open the app.</div>
      <div class="field-lbl">6-DIGIT PASSKEY</div>
      <div class="field-row"><input class="prof-edit-input" type="password" id="passkey-in" maxlength="6" inputmode="numeric" placeholder="••••••"></div>
      <button class="btn-main" onclick="savePasskey()">Set Passkey</button>
      <button class="btn-main" style="background:var(--sf2);color:var(--tx);margin-top:10px" id="remove-passkey-btn" onclick="removePasskey()">Remove Passkey</button>
    </div>
  </div>
</div>

<!-- CHANGE EMAIL SCREEN -->
<div class="screen" id="change-email-screen">
  <div class="prof-hdr"><button class="back-btn" onclick="show('security-screen')">←</button><div style="font-size:18px;font-weight:500">Change email</div></div>
  <div class="prof-body">
    <div style="padding:24px 20px">
      <div id="ce-step1">
        <div class="field-lbl">NEW EMAIL ADDRESS</div>
        <div class="field-row"><input class="prof-edit-input" type="email" id="new-email-in" placeholder="newemail@example.com"></div>
        <button class="btn-main" onclick="sendChangeEmailCode()">Send Code</button>
      </div>
      <div id="ce-step2" style="display:none">
        <div class="sec-info" style="padding:0 0 16px">Enter the 4-digit code sent to your new email.</div>
        <div class="otp-boxes" style="justify-content:flex-start">
          <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="ce0">
          <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="ce1">
          <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="ce2">
          <input class="otp-box" type="tel" maxlength="1" inputmode="numeric" id="ce3">
        </div>
        <div class="test-badge">🧪 Test code: <strong>1234</strong></div>
        <button class="btn-main" onclick="confirmChangeEmail()">Confirm</button>
      </div>
    </div>
  </div>
</div>

<!-- PRIVACY SCREEN -->
<div class="screen" id="privacy-screen">
  <div class="prof-hdr"><button class="back-btn" onclick="show('security-screen')">←</button><div style="font-size:18px;font-weight:500">Privacy</div></div>
  <div class="prof-body" style="padding-bottom:20px">
    <div class="prof-section-title">WHO CAN SEE MY...</div>
    <div class="nav-row" onclick="openPrivacyPicker('lastSeen','Last seen online')">
      <span class="nav-icon">🕐</span><div class="nav-label">Last seen online</div>
      <span class="nav-val" id="priv-lastSeen-val">Everyone</span><span class="nav-arrow">›</span>
    </div>
    <div class="nav-row" onclick="openPrivacyPicker('profilePic','Profile picture')">
      <span class="nav-icon">🖼️</span><div class="nav-label">Profile picture</div>
      <span class="nav-val" id="priv-profilePic-val">Everyone</span><span class="nav-arrow">›</span>
    </div>
    <div class="nav-row" onclick="openPrivacyPicker('about','About')">
      <span class="nav-icon">ℹ️</span><div class="nav-label">About</div>
      <span class="nav-val" id="priv-about-val">Everyone</span><span class="nav-arrow">›</span>
    </div>
    <div class="nav-row" onclick="openPrivacyPicker('status','Status / Updates')">
      <span class="nav-icon">⭐</span><div class="nav-label">Status</div>
      <span class="nav-val" id="priv-status-val">Everyone</span><span class="nav-arrow">›</span>
    </div>
    <div class="prof-section-title">MESSAGES</div>
    <div class="toggle-row">
      <div><div style="font-size:15px">Read receipts</div><div style="font-size:12px;color:var(--mu);margin-top:3px">Let others see when you've read their messages</div></div>
      <div class="toggle" id="readreceipts-toggle" onclick="toggleReadReceipts()"><div class="toggle-knob"></div></div>
    </div>
  </div>
</div>

<!-- PRIVACY OPTION PICKER MODAL -->
<div class="overlay" id="privacy-picker-overlay">
  <div class="tfa-card" style="text-align:left">
    <div class="tfa-title" id="pp-title">Last seen online</div>
    <div style="margin-top:14px">
      <div class="radio-row" onclick="selectPrivacyOption('everyone')"><span>Everyone</span><div class="radio-circle" id="pp-radio-everyone"></div></div>
      <div class="radio-row" onclick="selectPrivacyOption('contacts')"><span>My contacts</span><div class="radio-circle" id="pp-radio-contacts"></div></div>
      <div class="radio-row" onclick="selectPrivacyOption('nobody')"><span>Nobody</span><div class="radio-circle" id="pp-radio-nobody"></div></div>
    </div>
    <button class="btn-main" style="margin-top:18px;background:var(--sf2);color:var(--tx)" onclick="closePrivacyPicker()">Close</button>
  </div>
</div>

<!-- STORY VIEWER -->
<div class="screen" id="story-viewer">
  <div class="sv-progress" id="sv-progress"></div>
  <div class="sv-header">
    <div class="sv-av" id="sv-av">👤</div>
    <div><div class="sv-name" id="sv-name"></div><div class="sv-time" id="sv-time"></div></div>
    <div class="sv-close" onclick="closeStoryViewer()">✕</div>
  </div>
  <div class="sv-body" id="sv-body">
    <div class="sv-tap-zone" style="left:0" onclick="storyPrev()"></div>
    <div class="sv-tap-zone" style="right:0" onclick="storyNext()"></div>
  </div>
</div>

<!-- CREATE STORY -->
<div class="screen" id="create-story-screen">
  <div class="cs-hdr"><button onclick="show('main-screen')">✕</button><div style="color:#fff;font-weight:600">New Update</div><div style="width:36px"></div></div>
  <div class="cs-preview" id="cs-preview">
    <input class="cs-text-input" id="cs-text" placeholder="Type something...">
  </div>
  <div class="cs-footer">
    <button class="btn-main" style="background:var(--sf2);color:#fff" onclick="document.getElementById('story-file-input').click()">📷 Add Photo</button>
    <button class="btn-main" onclick="postStory()">Share</button>
  </div>
  <input type="file" id="story-file-input" accept="image/*" onchange="handleStoryImage(event)">
</div>

<div class="screen" id="call-screen">
  <div class="call-top">
    <div class="call-av" id="call-av">👤</div>
    <div class="call-name" id="call-name"></div>
    <div class="call-status" id="call-status">Calling...</div>
    <div class="call-mic-row"><button class="call-mic-btn" id="call-mute-btn" onclick="toggleMute()">🎤</button></div>
  </div>
  <div class="call-actions" id="call-actions-outgoing">
    <button class="call-btn-round call-hangup" onclick="endCall()">📞</button>
  </div>
  <div class="call-actions" id="call-actions-incoming" style="display:none">
    <button class="call-btn-round call-decline" onclick="declineCall()">📞</button>
    <button class="call-btn-round call-accept" onclick="acceptCall()">📞</button>
  </div>
</div>
<audio id="remote-audio" autoplay playsinline></audio>

<div class="overlay" id="tfa-overlay">
  <div class="tfa-card">
    <div class="tfa-icon">🔐</div>
    <div class="tfa-title">Two-step verification</div>
    <div class="tfa-sub">It's been 24 hours. Enter the 6-digit code to continue.</div>
    <div class="otp-boxes" style="justify-content:center;margin-bottom:14px">
      <input class="otp-box" style="width:38px;height:46px;font-size:18px" type="tel" maxlength="1" inputmode="numeric" id="t0">
      <input class="otp-box" style="width:38px;height:46px;font-size:18px" type="tel" maxlength="1" inputmode="numeric" id="t1">
      <input class="otp-box" style="width:38px;height:46px;font-size:18px" type="tel" maxlength="1" inputmode="numeric" id="t2">
      <input class="otp-box" style="width:38px;height:46px;font-size:18px" type="tel" maxlength="1" inputmode="numeric" id="t3">
      <input class="otp-box" style="width:38px;height:46px;font-size:18px" type="tel" maxlength="1" inputmode="numeric" id="t4">
      <input class="otp-box" style="width:38px;height:46px;font-size:18px" type="tel" maxlength="1" inputmode="numeric" id="t5">
    </div>
    <div class="test-badge">🧪 Test code: <strong>123456</strong></div>
    <button class="btn-main" onclick="verify2FARecheck()">Verify</button>
  </div>
</div>

<!-- PASSKEY LOCK OVERLAY -->
<div class="overlay" id="passkey-lock-overlay">
  <div class="tfa-card">
    <div class="tfa-icon">🔑</div>
    <div class="tfa-title">Enter Passkey</div>
    <div class="tfa-sub">Enter your 6-digit passkey to unlock PeyamApp.</div>
    <div class="field-row"><input class="prof-edit-input" type="password" id="passkey-lock-in" maxlength="6" inputmode="numeric" placeholder="••••••" style="text-align:center;font-size:22px;letter-spacing:6px"></div>
    <button class="btn-main" onclick="unlockWithPasskey()">Unlock</button>
  </div>
</div>

<div class="toast" id="toast"></div>
<audio id="notif-sound"><source src="data:audio/wav;base64,UklGRoQJAABXQVZFZm10IBAAAAABAAEAQB8AAIA+AAACABAAZGF0YWAJAAAAAHgHggtEClAEYfwc9mD0+/dE/+MGWQuaCv0EFv2F9k70dveJ/kcGJQvlCqUFzv359kj0+fbO/aUF5QolC0cGif529070hfYW/f0EmgpZC+MGRP/792D0HPZh/FAERAqCC3gHAACI+H70vPWw+58D5AmgCwUIvAAd+af0ZvUD++oCewmyC4oIdwG5+dv0G/Vb+jICBwm4CwcJMgJb+hv12/S5+XcBigiyC3sJ6gID+2b1p/Qd+bwABQigC+QJnwOw+7z1fvSI+AAAeAeCC0QKUARh/Bz2YPT790T/4wZZC5oK/QQW/YX2TvR294n+RwYlC+UKpQXO/fn2SPT59s79pQXlCiULRwaJ/nb3TvSF9hb9/QSaClkL4wZE//v3YPQc9mH8UARECoILeAcAAIj4fvS89bD7nwPkCaALBQi8AB35p/Rm9QP76gJ7CbILigh3Abn52/Qb9Vv6MgIHCbgLBwkyAlv6G/Xb9Ln5dwGKCLILewnqAgP7ZvWn9B35vAAFCKAL5AmfA7D7vPV+9Ij4AAB4B4ILRApQBGH8HPZg9Pv3RP/jBlkLmgr9BBb9hfZO9Hb3if5HBiUL5QqlBc79+fZI9Pn2zv2lBeUKJQtHBon+dvdO9IX2Fv39BJoKWQvjBkT/+/dg9Bz2YfxQBEQKggt4BwAAiPh+9Lz1sPufA+QJoAsFCLwAHfmn9Gb1A/vqAnsJsguKCHcBufnb9Bv1W/oyAgcJuAsHCTICW/ob9dv0ufl3AYoIsgt7CeoCA/tm9af0Hfm8AAUIoAvkCZ8DsPu89X70iPgAAHgHggtEClAEYfwc9mD0+/dE/+MGWQuaCv0EFv2F9k70dveJ/kcGJQvlCqUFzv359kj0+fbO/aUF5QolC0cGif529070hfYW/f0EmgpZC+MGRP/792D0HPZh/FAERAqCC3gHAACI+H70vPWw+58D5AmgCwUIvAAd+af0ZvUD++oCewmyC4oIdwG5+dv0G/Vb+jICBwm4CwcJMgJb+hv12/S5+XcBigiyC3sJ6gID+2b1p/Qd+bwABQigC+QJnwOw+7z1fvSI+AAAeAeCC0QKUARh/Bz2YPT790T/4wZZC5oK/QQW/YX2TvR294n+RwYlC+UKpQXO/fn2SPT59s79pQXlCiULRwaJ/nb3TvSF9hb9/QSaClkL4wZE//v3YPQc9mH8UARECoILeAcAAIj4fvS89bD7nwPkCaALBQi8AB35p/Rm9QP76gJ7CbILigh3Abn52/Qb9Vv6MgIHCbgLBwkyAlv6G/Xb9Ln5dwGKCLILewnqAgP7ZvWn9B35vAAFCKAL5AmfA7D7vPV+9Ij4AAB4B4ILRApQBGH8HPZg9Pv3RP/jBlkLmgr9BBb9hfZO9Hb3if5HBiUL5QqlBc79+fZI9Pn2zv2lBeUKJQtHBon+dvdO9IX2Fv39BJoKWQvjBkT/+/dg9Bz2YfxQBEQKggt4BwAAiPh+9Lz1sPufA+QJoAsFCLwAHfmn9Gb1A/vqAnsJsguKCHcBufnb9Bv1W/oyAgcJuAsHCTICW/ob9dv0ufl3AYoIsgt7CeoCA/tm9af0Hfm8AAUIoAvkCZ8DsPu89X70iPgAAHgHggtEClAEYfwc9mD0+/dE/+MGWQuaCv0EFv2F9k70dveJ/kcGJQvlCqUFzv359kj0+fbO/aUF5QolC0cGif529070hfYW/f0EmgpZC+MGRP/792D0HPZh/FAERAqCC3gHAACI+H70vPWw+58D5AmgCwUIvAAd+af0ZvUD++oCewmyC4oIdwG5+dv0G/Vb+jICBwm4CwcJMgJb+hv12/S5+XcBigiyC3sJ6gID+2b1p/Qd+bwABQigC+QJnwOw+7z1fvSI+AAAeAeCC0QKUARh/Bz2YPT790T/4wZZC5oK/QQW/YX2TvR294n+RwYlC+UKpQXO/fn2SPT59s79pQXlCiULRwaJ/nb3TvSF9hb9/QSaClkL4wZE//v3YPQc9mH8UARECoILeAcAAIj4fvS89bD7nwPkCaALBQi8AB35p/Rm9QP76gJ7CbILigh3Abn52/Qb9Vv6MgIHCbgLBwkyAlv6G/Xb9Ln5dwGKCLILewnqAgP7ZvWn9B35vAAFCKAL5AmfA7D7vPV+9Ij4AAB4B4ILRApQBGH8HPZg9Pv3RP/jBlkLmgr9BBb9hfZO9Hb3if5HBiUL5QqlBc79+fZI9Pn2zv2lBeUKJQtHBon+dvdO9IX2Fv39BJoKWQvjBkT/+/dg9Bz2YfxQBEQKggt4BwAAiPh+9Lz1sPufA+QJoAsFCLwAHfmn9Gb1A/vqAnsJsguKCHcBufnb9Bv1W/oyAgcJuAsHCTICW/ob9dv0ufl3AYoIsgt7CeoCA/tm9af0Hfm8AAUIoAvkCZ8DsPu89X70iPgAAHgHggtEClAEYfwc9mD0+/dE/+MGWQuaCv0EFv2F9k70dveJ/kcGJQvlCqUFzv359kj0+fbO/aUF5QolC0cGif529070hfYW/f0EmgpZC+MGRP/792D0HPZh/FAERAqCC3gHAACI+H70vPWw+58D5AmgCwUIvAAd+af0ZvUD++oCewmyC4oIdwG5+dv0G/Vb+jICBwm4CwcJMgJb+hv12/S5+XcBigiyC3sJ6gID+2b1p/Qd+bwABQigC+QJnwOw+7z1fvSI+AAAeAeCC0QKUARh/Bz2YPT790T/4wZZC5oK/QQW/YX2TvR294n+RwYlC+UKpQXO/fn2SPT59s79pQXlCiULRwaJ/nb3TvSF9hb9/QSaClkL4wZE//v3YPQc9mH8UARECoILeAcAAIj4fvS89bD7nwPkCaALBQi8AB35p/Rm9QP76gJ7CbILigh3Abn52/Qb9Vv6MgIHCbgLBwkyAlv6G/Xb9Ln5dwGKCLILewnqAgP7ZvWn9B35vAAFCKAL5AmfA7D7vPV+9Ij4AAB4B4ILRApQBGH8HPZg9Pv3RP/jBlkLmgr9BBb9hfZO9Hb3if5HBiUL5QqlBc79+fZI9Pn2zv2lBeUKJQtHBon+dvdO9IX2Fv39BJoKWQvjBkT/+/dg9Bz2YfxQBEQKggt4BwAAiPh+9Lz1sPufA+QJoAsFCLwAHfmn9Gb1A/vqAnsJsguKCHcBufnb9Bv1W/oyAgcJuAsHCTICW/ob9dv0ufl3AYoIsgt7CeoCA/tm9af0Hfm8AAUIoAvkCZ8DsPu89X70iPg=" type="audio/wav"></audio>

<script>
function nowTime() { const d = new Date(); return String(d.getHours()).padStart(2,'0') + ':' + String(d.getMinutes()).padStart(2,'0'); }
if ('serviceWorker' in navigator) { navigator.serviceWorker.register('/sw.js').catch(()=>{}); }
const socket = io();
let token = localStorage.getItem('pa_token') || '';
let myUser = null;
let currentChat = null;
let viewedUser = null;
let savedMsgs = JSON.parse(localStorage.getItem('pa_saved') || '[]');
let unreadCounts = {};
let chatPreviews = {};
let pendingImage = null, pendingVideo = null;
let twoFAEnabled = false;
let activeCallWith = null;
let notifPermission = false;
let selLang = 'en';
let pendingStoryImage = null;
let privacySettings = { lastSeen:'everyone', profilePic:'everyone', about:'everyone', status:'everyone', readReceipts:true };
let currentPrivacyField = null;
let storyViewerData = null, storyViewerIdx = 0, storyTimer = null;
let appLocked = false;

const langs = [
  {code:'fa',flag:'🇮🇷',name:'Persian',nat:'فارسی',dir:'rtl'},
  {code:'en',flag:'🇺🇸',name:'English',nat:'English',dir:'ltr'},
  {code:'ar',flag:'🇸🇦',name:'Arabic',nat:'العربية',dir:'rtl'},
  {code:'tr',flag:'🇹🇷',name:'Turkish',nat:'Türkçe',dir:'ltr'},
  {code:'ru',flag:'🇷🇺',name:'Russian',nat:'Русский',dir:'ltr'},
  {code:'de',flag:'🇩🇪',name:'German',nat:'Deutsch',dir:'ltr'},
  {code:'fr',flag:'🇫🇷',name:'French',nat:'Français',dir:'ltr'},
  {code:'es',flag:'🇪🇸',name:'Spanish',nat:'Español',dir:'ltr'},
  {code:'zh',flag:'🇨🇳',name:'Chinese',nat:'中文',dir:'ltr'},
  {code:'hi',flag:'🇮🇳',name:'Hindi',nat:'हिंदी',dir:'ltr'},
];
const T = {
  fa:{lt:'زبان خود را انتخاب کنید',ls:'زبان مورد نظر خود را انتخاب کنید',lb:'ادامه'},
  en:{lt:'Choose your language',ls:'Select your preferred language',lb:'Continue'},
  ar:{lt:'اختر لغتك',ls:'حدد لغتك المفضلة',lb:'متابعة'},
  tr:{lt:'Dilinizi seçin',ls:'Tercih ettiğiniz dili seçin',lb:'Devam'},
  ru:{lt:'Выберите язык',ls:'Выберите предпочтительный язык',lb:'Продолжить'},
  de:{lt:'Sprache wählen',ls:'Wählen Sie Ihre bevorzugte Sprache',lb:'Weiter'},
  fr:{lt:'Choisissez votre langue',ls:'Sélectionnez votre langue préférée',lb:'Continuer'},
  es:{lt:'Elige tu idioma',ls:'Selecciona tu idioma preferido',lb:'Continuar'},
  zh:{lt:'选择您的语言',ls:'选择您的首选语言',lb:'继续'},
  hi:{lt:'अपनी भाषा चुनें',ls:'अपनी पसंदीदा भाषा चुनें',lb:'जारी रखें'},
};

function bl(){
  document.getElementById('lgrid').innerHTML = langs.map(l=>`
    <div class="litem ${l.code===selLang?'sel':''}" onclick="pl('${l.code}')">
      <span class="lflag">${l.flag}</span>
      <div class="linfo"><div class="lname">${l.name}</div><div class="lnat">${l.nat}</div></div>
      <div class="lcheck"></div>
    </div>`).join('');
}
function pl(c){ selLang=c; bl(); applyLang(); }
function applyLang(){
  const t = T[selLang];
  document.getElementById('lt').textContent = t.lt;
  document.getElementById('ls').textContent = t.ls;
  document.getElementById('lbtn').textContent = t.lb;
  document.documentElement.dir = langs.find(l=>l.code===selLang).dir;
}
function goAuth(){ show('auth-screen'); }

function show(id) {
  document.querySelectorAll('.screen').forEach(s => s.classList.remove('active'));
  document.getElementById(id).classList.add('active');
}
function showToast(msg, dur=3000, onClick) {
  const t = document.getElementById('toast');
  t.textContent = msg; t.classList.add('show');
  t.onclick = onClick || null;
  setTimeout(() => t.classList.remove('show'), dur);
}
function vEmail(e) { return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e); }
async function api(url, body, method='POST') {
  const opts = { method, headers: { 'Content-Type': 'application/json', 'Authorization': token } };
  if (body) opts.body = JSON.stringify(body);
  const r = await fetch(url, opts);
  return r.json();
}

async function requestNotifPermission() {
  if ('Notification' in window) {
    if (Notification.permission === 'granted') { notifPermission = true; return; }
    if (Notification.permission !== 'denied') {
      const p = await Notification.requestPermission();
      notifPermission = p === 'granted';
    }
  }
}
function fireNotification(title, body) {
  try { if (notifPermission && 'Notification' in window && document.visibilityState !== 'visible') new Notification(title, { body }); } catch(e) {}
  try { document.getElementById('notif-sound').play().catch(()=>{}); } catch(e) {}
}

// ───── AUTH ─────
let authEmail = '';
function authBack() { if (document.getElementById('step-otp').style.display !== 'none') goStep('email'); else show('language-screen'); }
function goStep(s) {
  document.getElementById('step-email').style.display = s === 'email' ? '' : 'none';
  document.getElementById('step-otp').style.display = s === 'otp' ? '' : 'none';
}
async function sendCode() {
  const email = document.getElementById('email-in').value.trim();
  if (!vEmail(email)) { showToast('Enter a valid email'); return; }
  authEmail = email;
  const d = await api('/api/send-code', { email });
  if (d.ok) { document.getElementById('otp-email-show').textContent = email; goStep('otp'); document.getElementById('o0').focus(); showToast('Code sent ✓'); }
}
async function verifyOTP() {
  const code = [0,1,2,3].map(i => document.getElementById('o'+i).value).join('');
  if (code.length < 4) return;
  const d = await api('/api/verify-code', { email: authEmail, code });
  if (d.ok) {
    token = d.token;
    localStorage.setItem('pa_token', token);
    if (d.isNew) show('setup-screen');
    else { await loadMe(); show('main-screen'); loadChats(); socketAuth(); checkNeeds2FA(); requestNotifPermission(); }
  } else {
    [0,1,2,3].forEach(i => { const b = document.getElementById('o'+i); b.style.borderColor = '#ef4444'; setTimeout(() => b.style.borderColor = '', 1200); });
    showToast('Wrong code');
  }
}
[0,1,2,3].forEach(i => {
  document.getElementById('o'+i).addEventListener('input', e => {
    if (e.target.value && i < 3) document.getElementById('o'+(i+1)).focus();
    if (i === 3 && [0,1,2,3].every(j => document.getElementById('o'+j).value)) verifyOTP();
  });
  document.getElementById('o'+i).addEventListener('keydown', e => { if (e.key === 'Backspace' && !e.target.value && i > 0) document.getElementById('o'+(i-1)).focus(); });
});
document.getElementById('email-in').addEventListener('keydown', e => { if (e.key === 'Enter') sendCode(); });

function handleSetupAvatar(e) {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = (ev) => { pendingSetupAvatar = ev.target.result; document.getElementById('setup-avatar').innerHTML = `<img src="${pendingSetupAvatar}">`; };
  reader.readAsDataURL(file);
}
let pendingSetupAvatar = null;

async function setupProfile() {
  let username = document.getElementById('setup-username').value.trim();
  const name = document.getElementById('setup-name').value.trim();
  const about = document.getElementById('setup-about').value.trim();
  if (!username || !name) { showToast('Fill in all fields'); return; }
  if (!username.startsWith('@')) username = '@' + username;
  const d = await api('/api/setup-profile', { token, username, name });
  if (d.ok) {
    if (about || pendingSetupAvatar) await api('/api/update-profile', { about, avatar: pendingSetupAvatar });
    await loadMe(); show('main-screen'); loadChats(); socketAuth(); requestNotifPermission();
  } else showToast(d.msg || 'Error');
}

async function loadMe() {
  const d = await api('/api/me', null, 'GET');
  if (d.ok) {
    myUser = d.user;
    twoFAEnabled = d.user.twoFA;
    privacySettings = d.user.privacy || privacySettings;
  }
  return d;
}

async function checkNeeds2FA() {
  const d = await api('/api/me', null, 'GET');
  if (d.ok && d.needs2FA) {
    await api('/api/request-2fa-recheck', null);
    document.getElementById('tfa-overlay').classList.add('open');
  }
}
async function verify2FARecheck() {
  const code = [0,1,2,3,4,5].map(i => document.getElementById('t'+i).value).join('');
  if (code.length < 6) { showToast('Enter all 6 digits'); return; }
  const d = await api('/api/verify-2fa-recheck', { code });
  if (d.ok) { document.getElementById('tfa-overlay').classList.remove('open'); showToast('Verified ✓'); }
  else showToast(d.msg || 'Wrong code');
}
[0,1,2,3,4,5].forEach(i => { document.getElementById('t'+i).addEventListener('input', e => { if (e.target.value && i < 5) document.getElementById('t'+(i+1)).focus(); }); });

function socketAuth() { socket.emit('auth', token); }
socket.on('connect', () => { if (token) socketAuth(); });
socket.on('newMsg', (msg) => {
  if (currentChat && msg.chatId === currentChat.chatId) {
    appendMsg(msg);
  } else {
    unreadCounts[msg.chatId] = (unreadCounts[msg.chatId] || 0) + 1;
    const other = msg.from === myUser?.username ? msg.to : msg.from;
    let prevText = msg.text;
    if (msg.image) prevText = '📷 Photo'; if (msg.video) prevText = '🎥 Video';
    chatPreviews[msg.chatId] = { text: prevText, time: msg.time, other };
    updateChatList();
  }
  if (msg.from !== myUser?.username) {
    fireNotification(msg.from, msg.image ? '📷 Sent a photo' : msg.video ? '🎥 Sent a video' : msg.text);
    showToast('New message from ' + msg.from, 3500, () => openChat(msg.from));
  }
});
socket.on('online', (users) => {
  if (currentChat) {
    const isOn = users.includes(currentChat.username);
    const sub = document.getElementById('chat-sub');
    sub.textContent = isOn ? 'online' : 'last seen recently';
    sub.className = 'chat-sub' + (isOn ? ' on' : '');
  }
});

// ───── CALLS (real WebRTC voice) ─────
let localStream = null, peerConn = null, isMuted = false;
const RTC_CONFIG = { iceServers: [
  { urls: 'stun:stun.l.google.com:19302' },
  { urls: 'turn:openrelay.metered.ca:80', username: 'openrelayproject', credential: 'openrelayproject' },
  { urls: 'turn:openrelay.metered.ca:443', username: 'openrelayproject', credential: 'openrelayproject' },
  { urls: 'turn:openrelay.metered.ca:443?transport=tcp', username: 'openrelayproject', credential: 'openrelayproject' }
] };

async function getMic() {
  try {
    localStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    return true;
  } catch (e) {
    showToast('Microphone permission denied — enable it in your browser settings to use voice calls');
    return false;
  }
}
function createPeerConn(remoteUsername) {
  const pc = new RTCPeerConnection(RTC_CONFIG);
  localStream.getTracks().forEach(t => pc.addTrack(t, localStream));
  pc.onicecandidate = (e) => { if (e.candidate) socket.emit('rtc-ice', { to: remoteUsername, candidate: e.candidate }); };
  pc.ontrack = (e) => { document.getElementById('remote-audio').srcObject = e.streams[0]; };
  return pc;
}
function teardownCall() {
  if (peerConn) { peerConn.close(); peerConn = null; }
  if (localStream) { localStream.getTracks().forEach(t => t.stop()); localStream = null; }
  document.getElementById('remote-audio').srcObject = null;
  isMuted = false;
  document.getElementById('call-mute-btn').classList.remove('muted');
}
function toggleMute() {
  if (!localStream) return;
  isMuted = !isMuted;
  localStream.getAudioTracks().forEach(t => t.enabled = !isMuted);
  document.getElementById('call-mute-btn').classList.toggle('muted', isMuted);
}

socket.on('incomingCall', ({ from }) => {
  activeCallWith = from;
  document.getElementById('call-name').textContent = from;
  document.getElementById('call-status').textContent = 'Incoming call...';
  document.getElementById('call-actions-outgoing').style.display = 'none';
  document.getElementById('call-actions-incoming').style.display = 'flex';
  fireNotification('Incoming call', from + ' is calling you');
  show('call-screen');
});
socket.on('callResponse', ({ accepted }) => {
  if (accepted) document.getElementById('call-status').textContent = 'Connected';
  else { teardownCall(); showToast('Call declined'); show(currentChat ? 'chat-screen' : 'main-screen'); }
});
socket.on('callEnded', () => { teardownCall(); showToast('Call ended'); show(currentChat ? 'chat-screen' : 'main-screen'); });

socket.on('rtc-offer', async ({ from, offer }) => {
  // arrives right after the callee taps Accept and we already have the mic ready
  if (!localStream) { const ok = await getMic(); if (!ok) return; }
  peerConn = createPeerConn(from);
  await peerConn.setRemoteDescription(new RTCSessionDescription(offer));
  const answer = await peerConn.createAnswer();
  await peerConn.setLocalDescription(answer);
  socket.emit('rtc-answer', { to: from, answer });
});
socket.on('rtc-answer', async ({ answer }) => {
  if (peerConn) await peerConn.setRemoteDescription(new RTCSessionDescription(answer));
});
socket.on('rtc-ice', async ({ candidate }) => {
  if (peerConn) { try { await peerConn.addIceCandidate(new RTCIceCandidate(candidate)); } catch (e) {} }
});

async function startCall() {
  if (!currentChat) return;
  const ok = await getMic();
  if (!ok) return;
  activeCallWith = currentChat.username;
  document.getElementById('call-name').textContent = activeCallWith;
  document.getElementById('call-status').textContent = 'Calling...';
  document.getElementById('call-actions-outgoing').style.display = 'flex';
  document.getElementById('call-actions-incoming').style.display = 'none';
  socket.emit('callUser', { to: activeCallWith });
  show('call-screen');
  peerConn = createPeerConn(activeCallWith);
  const offer = await peerConn.createOffer();
  await peerConn.setLocalDescription(offer);
  socket.emit('rtc-offer', { to: activeCallWith, offer });
}
async function acceptCall() {
  const ok = await getMic();
  if (!ok) { declineCall(); return; }
  socket.emit('callResponse', { to: activeCallWith, accepted: true });
  document.getElementById('call-status').textContent = 'Connected';
  document.getElementById('call-actions-incoming').style.display = 'none';
  document.getElementById('call-actions-outgoing').style.display = 'flex';
  // peerConn is created when the offer arrives (rtc-offer handler above)
}
function declineCall() { teardownCall(); socket.emit('callResponse', { to: activeCallWith, accepted: false }); show(currentChat ? 'chat-screen' : 'main-screen'); }
function endCall() { teardownCall(); if (activeCallWith) socket.emit('endCall', { to: activeCallWith }); show(currentChat ? 'chat-screen' : 'main-screen'); }

// ───── TABS ─────
function switchTab(tab) {
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('a'));
  document.getElementById('tab-' + tab).classList.add('a');
  document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('show'));
  document.getElementById('content-' + tab).classList.add('show');
  document.getElementById('main-fab').onclick = tab === 'updates' ? () => show('create-story-screen') : () => show('find-user-screen');
  document.getElementById('main-fab').textContent = tab === 'updates' ? '📷' : '+';
  if (tab === 'updates') loadStories();
}

// ───── CHATS LIST ─────
async function loadChats() {
  const d = await api('/api/chats', null, 'GET');
  chatPreviews = {};
  if (d.ok) d.chats.forEach(c => { chatPreviews[c.chatId] = { text: c.lastMsg, time: c.lastTime, other: c.other }; });
  updateChatList();
}
function updateChatList() {
  const list = document.getElementById('chat-list');
  let html = `<div class="chat-item" onclick="openSaved()">
      <div class="ci-avatar" style="background:linear-gradient(135deg,var(--pr),var(--pr2))">🔖<div class="verified-badge">✓</div></div>
      <div class="ci-info"><div class="ci-name">Saved Messages</div><div class="ci-preview">Your personal notes</div></div>
      <div class="ci-meta"><div class="ci-time"></div></div>
    </div>`;
  const entries = Object.entries(chatPreviews);
  entries.forEach(([cid, info]) => {
    const badge = unreadCounts[cid] ? `<div class="ci-badge">${unreadCounts[cid]}</div>` : '';
    html += `<div class="chat-item" onclick="openChat('${info.other}','${cid}')">
      <div class="ci-avatar" id="cl-av-${cid.replace(/[^a-zA-Z0-9]/g,'')}">👤</div>
      <div class="ci-info"><div class="ci-name">${info.other}</div><div class="ci-preview">${info.text || ''}</div></div>
      <div class="ci-meta"><div class="ci-time">${info.time || ''}</div>${badge}</div>
    </div>`;
  });
  if (!entries.length) html += `<div class="empty-state" style="padding:30px"><div class="empty-icon">💬</div><div>No chats yet</div><div style="font-size:12px">Tap + to find someone</div></div>`;
  list.innerHTML = html;
  entries.forEach(([cid, info]) => {
    api('/api/user/' + encodeURIComponent(info.other), null, 'GET').then(d => {
      if (d.ok && d.user.avatar) {
        const el = document.getElementById('cl-av-' + cid.replace(/[^a-zA-Z0-9]/g,''));
        if (el) el.innerHTML = `<img src="${d.user.avatar}">`;
      }
    });
  });
}
function markAllRead() { unreadCounts = {}; updateChatList(); showToast('All marked as read'); }

// ───── FIND USER ─────
let findTimer = null;
function findUser() {
  clearTimeout(findTimer);
  findTimer = setTimeout(async () => {
    let q = document.getElementById('find-input').value.trim();
    const res = document.getElementById('find-result');
    if (!q) { res.innerHTML = '<div class="empty-state"><div class="empty-icon">🔍</div><div>Search by @username</div></div>'; return; }
    if (!q.startsWith('@')) q = '@' + q;
    const d = await api('/api/user/' + encodeURIComponent(q), null, 'GET');
    if (!d.ok) { res.innerHTML = '<div class="empty-state"><div class="empty-icon">🤷</div><div>User not found</div></div>'; return; }
    const u = d.user;
    const avHtml = u.avatar ? `<img src="${u.avatar}">` : '👤';
    res.innerHTML = `<div class="user-card" onclick="openFromFind('${u.username}')">
      <div class="uc-av">${avHtml}</div>
      <div><div class="uc-name">${u.name}</div><div class="uc-un">${u.username}</div><div class="uc-about">${u.about||''}</div></div>
    </div>`;
  }, 400);
}
function openFromFind(username) {
  api('/api/user/' + encodeURIComponent(username), null, 'GET').then(d => {
    if (d.ok) { viewedUser = d.user; renderUserProfile(); show('user-profile-screen'); document.getElementById('upback-btn').onclick = () => show('find-user-screen'); }
  });
}

// ───── OPEN CHAT ─────
function openChat(username, cid) {
  const cId = cid || [myUser.username, username].sort().join('::');
  currentChat = { username, chatId: cId };
  unreadCounts[cId] = 0;
  updateChatList();
  document.getElementById('chat-name').textContent = username;
  document.getElementById('chat-sub').textContent = 'tap for info';
  document.getElementById('chat-av').innerHTML = '👤';
  api('/api/user/' + encodeURIComponent(username), null, 'GET').then(d => { if (d.ok && d.user.avatar) document.getElementById('chat-av').innerHTML = `<img src="${d.user.avatar}">`; });
  show('chat-screen');
  loadMessages(cId);
}
async function loadMessages(cId) {
  const d = await api('/api/messages/' + encodeURIComponent(cId), null, 'GET');
  const msgs = document.getElementById('msgs');
  msgs.innerHTML = '';
  if (d.ok) d.messages.forEach(m => appendMsg(m, false));
  msgs.scrollTop = msgs.scrollHeight;
}
function appendMsg(msg, isLive) {
  const deletedLocal = JSON.parse(localStorage.getItem('pa_deleted_local') || '[]');
  if (deletedLocal.includes(msg.id)) return; // deleted for me — never render
  const msgs = document.getElementById('msgs');
  const wasNearBottom = msgs.scrollHeight - msgs.scrollTop - msgs.clientHeight < 80;
  const div = document.createElement('div');
  const isMe = msg.from === myUser?.username;
  div.className = 'bbl ' + (isMe ? 'me' : 'ot');
  div.dataset.id = msg.id;
  div.dataset.from = msg.from;
  renderBubbleContent(div, msg, isMe);
  // long-press (touch) and right-click (desktop) open the message menu
  let pressTimer;
  div.addEventListener('touchstart', () => { pressTimer = setTimeout(() => openMsgCtx(msg.id, isMe), 450); });
  div.addEventListener('touchend', () => clearTimeout(pressTimer));
  div.addEventListener('touchmove', () => clearTimeout(pressTimer));
  div.addEventListener('contextmenu', (e) => { e.preventDefault(); openMsgCtx(msg.id, isMe); });
  msgs.appendChild(div);
  if (isLive === false) return; // bulk initial load — scroll handled by caller
  if (isMe || wasNearBottom) msgs.scrollTop = msgs.scrollHeight;
}
function renderBubbleContent(div, msg, isMe) {
  let inner = '';
  if (msg.deleted) {
    inner = `<span class="msg-deleted">🚫 This message was deleted</span><span class="btime">${msg.time}</span>`;
  } else {
    if (msg.image) inner += `<img class="msg-img" src="${msg.image}">`;
    if (msg.video) inner += `<video class="msg-vid" src="${msg.video}" controls></video>`;
    if (msg.text) inner += `<span>${msg.text}</span>`;
    inner += `<span class="btime">${msg.edited ? '<span class=\"msg-edited-tag\">edited</span>' : ''}${msg.time}${isMe ? '<span class=\"read-tick\">✓✓</span>' : ''}</span>`;
  }
  div.innerHTML = inner;
}

// ───── MESSAGE CONTEXT MENU (edit / delete) ─────
let ctxMsgId = null;
function openMsgCtx(id, isMe) {
  ctxMsgId = id;
  const sheet = document.getElementById('msg-ctx-sheet');
  let html = '';
  if (isMe) html += `<div class="msg-ctx-item" onclick="openEditMsg(${id})">✏️ Edit message</div>`;
  html += `<div class="msg-ctx-item" onclick="deleteForMe(${id})">🗑️ Delete for me</div>`;
  if (isMe) html += `<div class="msg-ctx-item danger" onclick="deleteForEveryone(${id})">🗑️ Delete for everyone</div>`;
  sheet.innerHTML = html;
  document.getElementById('msg-ctx-overlay').classList.add('open');
}
function closeMsgCtx() { document.getElementById('msg-ctx-overlay').classList.remove('open'); }
function openEditMsg(id) {
  closeMsgCtx();
  const bubble = document.querySelector(`.bbl[data-id="${id}"]`);
  const span = bubble ? bubble.querySelector('span:not(.btime)') : null;
  document.getElementById('edit-msg-input').value = span ? span.textContent : '';
  document.getElementById('edit-msg-overlay').dataset.editId = id;
  document.getElementById('edit-msg-overlay').classList.add('open');
}
function confirmEditMsg() {
  const id = Number(document.getElementById('edit-msg-overlay').dataset.editId);
  const text = document.getElementById('edit-msg-input').value.trim();
  if (!text || !currentChat) return;
  socket.emit('editMsg', { chatId: currentChat.chatId, id, text });
  document.getElementById('edit-msg-overlay').classList.remove('open');
}
function deleteForMe(id) {
  closeMsgCtx();
  const deletedLocal = JSON.parse(localStorage.getItem('pa_deleted_local') || '[]');
  if (!deletedLocal.includes(id)) deletedLocal.push(id);
  localStorage.setItem('pa_deleted_local', JSON.stringify(deletedLocal));
  const bubble = document.querySelector(`.bbl[data-id="${id}"]`);
  if (bubble) bubble.remove();
  showToast('Message deleted for you');
}
function deleteForEveryone(id) {
  closeMsgCtx();
  if (!currentChat) return;
  socket.emit('deleteMsg', { chatId: currentChat.chatId, id });
}
socket.on('msgEdited', ({ chatId: cid, id, text }) => {
  if (currentChat && cid === currentChat.chatId) {
    const bubble = document.querySelector(`.bbl[data-id="${id}"]`);
    if (bubble) { const span = bubble.querySelector('span:not(.btime)'); if (span) span.textContent = text; const tag = bubble.querySelector('.btime'); if (tag && !bubble.querySelector('.msg-edited-tag')) tag.insertAdjacentHTML('afterbegin', '<span class="msg-edited-tag">edited</span>'); }
  }
});
socket.on('msgDeleted', ({ chatId: cid, id }) => {
  if (currentChat && cid === currentChat.chatId) {
    const bubble = document.querySelector(`.bbl[data-id="${id}"]`);
    if (bubble) renderBubbleContent(bubble, { deleted: true, time: bubble.querySelector('.btime')?.textContent.replace('edited','').trim() || '' }, bubble.classList.contains('me'));
  }
});

function openAttachMenu() {
  // simple: ask user which type via native file pickers (image input doubles as the primary path)
  document.getElementById('file-input').click();
}
function handleImagePick(e) {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = (ev) => {
    pendingImage = ev.target.result; pendingVideo = null;
    document.getElementById('img-preview-thumb').src = pendingImage;
    document.getElementById('img-preview-thumb').style.display = '';
    document.getElementById('video-preview-thumb').style.display = 'none';
    document.getElementById('preview-label').textContent = 'Image ready to send';
    document.getElementById('img-preview-bar').style.display = 'flex';
  };
  reader.readAsDataURL(file);
}
function handleVideoPick(e) {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = (ev) => {
    pendingVideo = ev.target.result; pendingImage = null;
    const vid = document.getElementById('video-preview-thumb');
    vid.src = pendingVideo;
    vid.style.display = '';
    document.getElementById('img-preview-thumb').style.display = 'none';
    document.getElementById('preview-label').textContent = 'Video ready to send';
    document.getElementById('img-preview-bar').style.display = 'flex';
  };
  reader.readAsDataURL(file);
}
function cancelImage() {
  pendingImage = null; pendingVideo = null;
  document.getElementById('img-preview-bar').style.display = 'none';
  document.getElementById('file-input').value = '';
  document.getElementById('video-input').value = '';
}
function sendMsg() {
  const cin = document.getElementById('cin');
  const text = cin.value.trim();
  if (!currentChat) return;
  if (!text && !pendingImage && !pendingVideo) return;
  socket.emit('sendMsg', { to: currentChat.username, text, image: pendingImage, video: pendingVideo });
  cin.value = '';
  cancelImage();
}
document.getElementById('cin').addEventListener('keydown', e => { if (e.key === 'Enter') sendMsg(); });

function openSaved() {
  show('saved-screen');
  const msgs = document.getElementById('saved-msgs');
  msgs.innerHTML = '';
  savedMsgs.forEach(m => {
    const div = document.createElement('div');
    div.className = 'bbl saved';
    div.innerHTML = `<span>${m.text}</span><span class="btime">${m.time}</span>`;
    msgs.appendChild(div);
  });
  msgs.scrollTop = msgs.scrollHeight;
}
function sendSaved() {
  const cin = document.getElementById('saved-cin');
  const text = cin.value.trim();
  if (!text) return;
  const msg = { text, time: nowTime() };
  savedMsgs.push(msg);
  localStorage.setItem('pa_saved', JSON.stringify(savedMsgs));
  const div = document.createElement('div');
  div.className = 'bbl saved';
  div.innerHTML = `<span>${text}</span><span class="btime">${msg.time}</span>`;
  document.getElementById('saved-msgs').appendChild(div);
  document.getElementById('saved-msgs').scrollTop = 999999;
  cin.value = '';
}
document.getElementById('saved-cin').addEventListener('keydown', e => { if (e.key === 'Enter') sendSaved(); });

function viewUserProfile() {
  if (!currentChat) return;
  api('/api/user/' + encodeURIComponent(currentChat.username), null, 'GET').then(d => {
    if (d.ok) { viewedUser = d.user; renderUserProfile(); show('user-profile-screen'); document.getElementById('upback-btn').onclick = () => show('chat-screen'); }
  });
}
function renderUserProfile() {
  const u = viewedUser;
  document.getElementById('up-name').textContent = u.name || u.username;
  document.getElementById('up-username').textContent = u.username;
  document.getElementById('up-about').textContent = u.about || '';
  document.getElementById('up-avatar').innerHTML = u.avatar ? `<img src="${u.avatar}">` : '👤';
  const onlineEl = document.getElementById('up-online');
  if (u.online === true) onlineEl.textContent = 'online';
  else if (u.online === false) onlineEl.textContent = 'last seen recently';
  else onlineEl.textContent = '';
}
function chatWithViewed() { if (viewedUser) openChat(viewedUser.username); }

async function loadProfile() {
  await loadMe();
  if (!myUser) return;
  document.getElementById('edit-name').value = myUser.name || '';
  document.getElementById('edit-username').value = myUser.username || '';
  document.getElementById('edit-about').value = myUser.about || '';
  document.getElementById('prof-name-show').textContent = myUser.name || '';
  document.getElementById('prof-un-show').textContent = myUser.username || '';
  document.getElementById('my-avatar-big').innerHTML = myUser.avatar ? `<img src="${myUser.avatar}">` : '👤';
}
async function saveProfile() {
  const name = document.getElementById('edit-name').value.trim();
  const username = document.getElementById('edit-username').value.trim();
  const about = document.getElementById('edit-about').value.trim();
  const d = await api('/api/update-profile', { name, username, about });
  if (d.ok) { showToast('Profile saved ✓'); await loadMe(); show('main-screen'); }
  else showToast(d.msg || 'Error');
}
function handleAvatarChange(e) {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = async (ev) => { await api('/api/update-profile', { avatar: ev.target.result }); showToast('Avatar updated ✓ — visible to everyone'); loadProfile(); };
  reader.readAsDataURL(file);
}

// ───── SECURITY: TWO-FA SETUP FLOW ─────
function openTwoFAFlow() {
  show('twofa-flow-screen');
  document.getElementById('twofa-flow-off').style.display = 'none';
  document.getElementById('twofa-flow-code').style.display = 'none';
  document.getElementById('twofa-flow-on').style.display = 'none';
  if (twoFAEnabled) document.getElementById('twofa-flow-on').style.display = '';
  else document.getElementById('twofa-flow-off').style.display = '';
}
async function requestTwoFASetup() {
  await api('/api/request-2fa-code', null);
  document.getElementById('twofa-flow-off').style.display = 'none';
  document.getElementById('twofa-flow-code').style.display = '';
  document.getElementById('s0').focus();
}
async function confirmTwoFASetup() {
  const code = [0,1,2,3,4,5].map(i => document.getElementById('s'+i).value).join('');
  if (code.length < 6) { showToast('Enter all 6 digits'); return; }
  const d = await api('/api/confirm-2fa-setup', { code });
  if (d.ok) {
    twoFAEnabled = true;
    document.getElementById('twofa-status-label').textContent = 'On';
    showToast('Two-step verification enabled ✓');
    openTwoFAFlow();
  } else showToast(d.msg || 'Wrong code');
}
[0,1,2,3,4,5].forEach(i => { document.getElementById('s'+i).addEventListener('input', e => { if (e.target.value && i < 5) document.getElementById('s'+(i+1)).focus(); }); });
async function disableTwoFA() {
  await api('/api/disable-2fa', null);
  twoFAEnabled = false;
  document.getElementById('twofa-status-label').textContent = 'Off';
  showToast('Two-step verification disabled');
  openTwoFAFlow();
}

// ───── PASSKEY ─────
function loadPasskeyStatus() {
  document.getElementById('passkey-status-label').textContent = myUser?.passkeySet ? 'On' : 'Not set';
  document.getElementById('remove-passkey-btn').style.display = myUser?.passkeySet ? '' : 'none';
}
async function savePasskey() {
  const pk = document.getElementById('passkey-in').value.trim();
  if (!/^\d{6}$/.test(pk)) { showToast('Passkey must be 6 digits'); return; }
  const d = await api('/api/set-passkey', { passkey: pk });
  if (d.ok) { showToast('Passkey set ✓'); await loadMe(); document.getElementById('passkey-status-label').textContent='On'; localStorage.setItem('pa_passkey_local', pk); show('security-screen'); }
  else showToast(d.msg || 'Error');
}
async function removePasskey() {
  await api('/api/remove-passkey', null);
  localStorage.removeItem('pa_passkey_local');
  showToast('Passkey removed');
  await loadMe();
  show('security-screen');
}

// ───── CHANGE EMAIL ─────
async function sendChangeEmailCode() {
  const email = document.getElementById('new-email-in').value.trim();
  if (!vEmail(email)) { showToast('Enter a valid email'); return; }
  pendingNewEmail = email;
  const d = await api('/api/send-code', { email });
  if (d.ok) { document.getElementById('ce-step1').style.display = 'none'; document.getElementById('ce-step2').style.display = ''; document.getElementById('ce0').focus(); showToast('Code sent ✓'); }
}
let pendingNewEmail = '';
async function confirmChangeEmail() {
  const code = [0,1,2,3].map(i => document.getElementById('ce'+i).value).join('');
  if (code.length < 4) return;
  const d = await api('/api/change-email', { newEmail: pendingNewEmail, code });
  if (d.ok) { showToast('Email changed ✓'); await loadMe(); show('security-screen'); }
  else showToast(d.msg || 'Error');
}

// ───── PRIVACY ─────
function loadPrivacy() {
  const labels = { everyone: 'Everyone', contacts: 'My contacts', nobody: 'Nobody' };
  ['lastSeen','profilePic','about','status'].forEach(f => {
    document.getElementById('priv-'+f+'-val').textContent = labels[privacySettings[f]] || 'Everyone';
  });
  updateToggle('readreceipts-toggle', privacySettings.readReceipts !== false);
}
function openPrivacyPicker(field, title) {
  currentPrivacyField = field;
  document.getElementById('pp-title').textContent = title;
  ['everyone','contacts','nobody'].forEach(opt => {
    document.getElementById('pp-radio-'+opt).className = 'radio-circle' + (privacySettings[field] === opt ? ' sel' : '');
  });
  document.getElementById('privacy-picker-overlay').classList.add('open');
}
function closePrivacyPicker() { document.getElementById('privacy-picker-overlay').classList.remove('open'); }
async function selectPrivacyOption(opt) {
  privacySettings[currentPrivacyField] = opt;
  const d = await api('/api/update-privacy', { privacy: { [currentPrivacyField]: opt } });
  if (d.ok) { loadPrivacy(); showToast('Privacy updated ✓'); }
  closePrivacyPicker();
}
async function toggleReadReceipts() {
  privacySettings.readReceipts = !privacySettings.readReceipts;
  updateToggle('readreceipts-toggle', privacySettings.readReceipts);
  await api('/api/update-privacy', { privacy: { readReceipts: privacySettings.readReceipts } });
  showToast(privacySettings.readReceipts ? 'Read receipts on' : 'Read receipts off');
}

function updateToggle(id, on) { const el = document.getElementById(id); if (on) el.classList.add('on'); else el.classList.remove('on'); }

// ───── STORIES ─────
function handleStoryImage(e) {
  const file = e.target.files[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = (ev) => {
    pendingStoryImage = ev.target.result;
    document.getElementById('cs-preview').innerHTML = `<img src="${pendingStoryImage}">`;
  };
  reader.readAsDataURL(file);
}
async function postStory() {
  const text = document.getElementById('cs-text') ? document.getElementById('cs-text').value.trim() : '';
  if (!pendingStoryImage && !text) { showToast('Add a photo or text'); return; }
  const d = await api('/api/post-story', { image: pendingStoryImage, text });
  if (d.ok) {
    showToast('Update shared ✓ — visible for 24 hours');
    pendingStoryImage = null;
    document.getElementById('cs-preview').innerHTML = `<input class="cs-text-input" id="cs-text" placeholder="Type something...">`;
    show('main-screen');
    switchTab('updates');
  }
}
async function loadStories() {
  const d = await api('/api/stories', null, 'GET');
  const strip = document.getElementById('stories-strip');
  const list = document.getElementById('stories-list');
  let stripHtml = `<div class="story-item" onclick="show('create-story-screen')">
    <div class="story-ring add" style="position:relative">
      <div class="story-av">${myUser?.avatar ? '<img src=\"'+myUser.avatar+'\">' : '➕'}</div>
      <div class="add-story-plus">+</div>
    </div>
    <div class="story-label">My Update</div>
  </div>`;
  let listHtml = '';
  if (!d.ok || !d.stories.length) {
    list.innerHTML = `<div class="empty-state" style="padding:30px"><div class="empty-icon">⭐</div><div>No updates yet</div></div>`;
  } else {
    d.stories.forEach(s => {
      const avHtml = s.avatar ? `<img src="${s.avatar}">` : '👤';
      stripHtml += `<div class="story-item" onclick="openStoryViewer('${s.username}')">
        <div class="story-ring"><div class="story-av">${avHtml}</div></div>
        <div class="story-label">${s.username}</div>
      </div>`;
      listHtml += `<div class="chat-item" onclick="openStoryViewer('${s.username}')">
        <div class="ci-avatar">${avHtml}</div>
        <div class="ci-info"><div class="ci-name">${s.username}</div><div class="ci-preview">${s.items.length} update${s.items.length>1?'s':''} · ${s.items[s.items.length-1].time}</div></div>
      </div>`;
    });
    list.innerHTML = listHtml;
  }
  strip.innerHTML = stripHtml;
}
async function openStoryViewer(username) {
  const d = await api('/api/stories/' + encodeURIComponent(username), null, 'GET');
  if (!d.ok || !d.items.length) return;
  storyViewerData = { username, items: d.items };
  storyViewerIdx = 0;
  const u = await api('/api/user/' + encodeURIComponent(username), null, 'GET');
  document.getElementById('sv-av').innerHTML = (u.ok && u.user.avatar) ? `<img src="${u.user.avatar}">` : '👤';
  document.getElementById('sv-name').textContent = username;
  buildProgressBars();
  show('story-viewer');
  renderStoryFrame();
}
function buildProgressBars() {
  const prog = document.getElementById('sv-progress');
  prog.innerHTML = storyViewerData.items.map(() => `<div class="sv-bar"><div class="sv-bar-fill"></div></div>`).join('');
}
function renderStoryFrame() {
  clearTimeout(storyTimer);
  const item = storyViewerData.items[storyViewerIdx];
  document.getElementById('sv-time').textContent = item.time;
  const body = document.getElementById('sv-body');
  body.innerHTML = `<div class="sv-tap-zone" style="left:0" onclick="storyPrev()"></div><div class="sv-tap-zone" style="right:0" onclick="storyNext()"></div>` +
    (item.image ? `<img class="sv-img" src="${item.image}">` : `<div class="sv-text">${item.text}</div>`);
  document.querySelectorAll('.sv-bar-fill').forEach((b, i) => { b.style.width = i < storyViewerIdx ? '100%' : '0%'; });
  const fill = document.querySelectorAll('.sv-bar-fill')[storyViewerIdx];
  if (fill) { fill.style.transition = 'width 5s linear'; requestAnimationFrame(() => fill.style.width = '100%'); }
  storyTimer = setTimeout(storyNext, 5000);
}
function storyNext() {
  storyViewerIdx++;
  if (storyViewerIdx >= storyViewerData.items.length) { closeStoryViewer(); return; }
  renderStoryFrame();
}
function storyPrev() {
  storyViewerIdx--;
  if (storyViewerIdx < 0) storyViewerIdx = 0;
  renderStoryFrame();
}
function closeStoryViewer() { clearTimeout(storyTimer); show('main-screen'); switchTab('updates'); }

// ───── MENU ─────
function toggleMenu() { document.getElementById('main-menu').classList.toggle('open'); }
function closeMenu() { document.getElementById('main-menu').classList.remove('open'); }
document.addEventListener('click', e => { if (!e.target.closest('#main-menu') && !e.target.closest('#menu-btn')) closeMenu(); });

// ───── PASSKEY LOCK (local, app-open gate) ─────
function unlockWithPasskey() {
  const val = document.getElementById('passkey-lock-in').value.trim();
  const stored = localStorage.getItem('pa_passkey_local');
  if (val === stored) { document.getElementById('passkey-lock-overlay').classList.remove('open'); appLocked = false; }
  else showToast('Wrong passkey');
}

// ───── INIT ─────
async function init() {
  await new Promise(r => setTimeout(r, 1800));
  bl();
  applyLang();
  if (token) {
    const d = await api('/api/me', null, 'GET');
    if (d.ok) {
      myUser = d.user;
      twoFAEnabled = d.user.twoFA;
      privacySettings = d.user.privacy || privacySettings;
      if (!myUser.username) { show('setup-screen'); return; }
      const storedPasskey = localStorage.getItem('pa_passkey_local');
      if (storedPasskey) { document.getElementById('passkey-lock-overlay').classList.add('open'); }
      show('main-screen');
      loadChats();
      socketAuth();
      requestNotifPermission();
      if (d.needs2FA) checkNeeds2FA();
      return;
    }
  }
  show('language-screen');
}
init();
</script>
</body>
</html>
HTMLEOF

cat > public/sw.js << 'SWEOF'
// Minimal service worker — lets the browser keep notification delivery
// working a bit more reliably while the app/tab is backgrounded.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));
self.addEventListener('message', (event) => {
  if (event.data && event.data.title) {
    self.registration.showNotification(event.data.title, { body: event.data.body || '' });
  }
});
SWEOF

echo ""
echo "Generating a self-signed HTTPS certificate (needed for mic + notifications to work on a phone)..."
if ! command -v openssl >/dev/null 2>&1; then
  pkg install -y openssl-tool 2>/dev/null || pkg install -y openssl 2>/dev/null
fi
if command -v openssl >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes -subj "/CN=peyamapp" 2>/dev/null
  echo "Certificate created ✓"
else
  echo "⚠️  openssl not found — could not create cert.pem/key.pem. The app will fall back to HTTP, and mic/notifications will only work on http://localhost on the same phone."
fi

echo ""
echo "Installing packages..."
npm install

echo ""
echo "================================"
echo "  Done! PeyamApp v5"
echo "  Run:  cd ~/peyamapp && node server.js"
echo "  On this phone open:    https://localhost:1415"
echo "  From another phone:    https://<this-phone-LAN-IP>:1415"
echo "  (run 'ifconfig' or 'ip addr' in Termux to find the IP)"
echo ""
echo "  First time you open the https:// link your browser will show"
echo "  a 'connection not private' / 'not secure' warning because the"
echo "  certificate is self-signed (made by you, not a public CA)."
echo "  Tap Advanced -> Proceed anyway. This is normal and only needs"
echo "  to be done once per device. Without this step over HTTPS,"
echo "  mic access and notification permission will be silently"
echo "  blocked by the browser — that is the real cause of those"
echo "  two problems, not a bug in the app itself."
echo "================================"

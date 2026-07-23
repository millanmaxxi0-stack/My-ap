const express = require('express');
const https = require('https');
const http = require('http');
const fs = require('fs');
const crypto = require('crypto');
const { Server } = require('socket.io');
const cors = require('cors');
const path = require('path');
const multer = require('multer');

let nodemailer = null;
try { nodemailer = require('nodemailer'); } catch (e) { /* optional until npm install runs */ }
let webpush = null;
try { webpush = require('web-push'); } catch (e) { /* optional until npm install runs */ }

const PORT = process.env.PORT || 1415;
const app = express();

// ===== HTTPS (required by real browsers for mic access + push notifications) =====
let server;
const certPath = path.join(__dirname, 'cert.pem');
const keyPath = path.join(__dirname, 'key.pem');
if (fs.existsSync(certPath) && fs.existsSync(keyPath)) {
  server = https.createServer({ cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath) }, app);
} else {
  console.log('⚠️  No cert.pem/key.pem found — running over plain HTTP. Mic, notifications & push will only work on http://localhost.');
  server = http.createServer(app);
}

const io = new Server(server, {
  maxHttpBufferSize: 10 * 1024 * 1024 // messages are now text-only over sockets; files go through /api/upload
});
app.use(cors());
app.use(express.json({ limit: '2mb' }));

// ===== UPLOADS (real photo / video / file sharing) =====
const UPLOAD_DIR = path.join(__dirname, 'public', 'uploads');
if (!fs.existsSync(UPLOAD_DIR)) fs.mkdirSync(UPLOAD_DIR, { recursive: true });
const upload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => cb(null, UPLOAD_DIR),
    filename: (req, file, cb) => {
      const safe = file.originalname.replace(/[^a-zA-Z0-9._-]/g, '_').slice(-80);
      cb(null, Date.now() + '-' + crypto.randomBytes(4).toString('hex') + '-' + safe);
    }
  }),
  limits: { fileSize: 100 * 1024 * 1024 } // 100MB
});

app.use(express.static(path.join(__dirname, 'public')));

function nowTime() {
  const d = new Date();
  return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
}

// ===== DATA (in-memory; persisted to disk so a restart doesn't wipe accounts) =====
const DB_FILE = path.join(__dirname, 'data.json');
let users = {};        // email -> user
let messages = {};     // chatId -> [msg]
let requests = {};     // "fromUsername::toUsername" -> { from, to, status, time }
let stories = {};      // username -> [{ id, image, text, time, expires }]
let groups = {};       // groupId -> group
const sessions = {};   // token -> email (not persisted — logging back in re-sends a code)
const codes = {};      // email -> { code, expires }
const onlineSockets = {}; // socketId -> email

function loadDB() {
  try {
    if (fs.existsSync(DB_FILE)) {
      const d = JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
      users = d.users || {};
      messages = d.messages || {};
      requests = d.requests || {};
      stories = d.stories || {};
      groups = d.groups || {};
    }
  } catch (e) { console.log('Could not load data.json, starting fresh.', e.message); }
}
let saveTimer = null;
function saveDB() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    try { fs.writeFileSync(DB_FILE, JSON.stringify({ users, messages, requests, stories, groups })); }
    catch (e) { console.log('Could not save data.json', e.message); }
  }, 300);
}
loadDB();

function genToken() { return crypto.randomBytes(24).toString('hex'); }
// 7-character alphanumeric verification code (unambiguous charset — no 0/O/1/I/l)
const CODE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
function genCode() {
  let c = '';
  for (let i = 0; i < 7; i++) c += CODE_CHARS[crypto.randomInt(0, CODE_CHARS.length)];
  return c;
}
function chatId(a, b) { return [a, b].sort().join('::'); }
function reqKey(from, to) { return from + '::' + to; }
function newUser(email) {
  return {
    email, username: '', name: '', lastName: '', about: 'Hey there! I am using PeyamApp.',
    avatar: '', twoFA: false, twoFALastVerified: 0,
    passkey: '', securityNotifications: true,
    privacy: {
      lastSeen: 'everyone', profilePic: 'everyone', about: 'everyone', links: 'everyone',
      statusAudience: 'contacts', readReceipts: true, disappearing: false,
      cameraEffects: true
    },
    friends: [], contacts: [], pushSubs: []
  };
}

function cleanStories() {
  const now = Date.now();
  let changed = false;
  for (const u in stories) { const before = stories[u].length; stories[u] = stories[u].filter(s => s.expires > now); if (stories[u].length !== before) changed = true; }
  if (changed) saveDB();
}
setInterval(cleanStories, 60 * 1000);
setInterval(() => { for (const e in codes) if (Date.now() > codes[e].expires) delete codes[e]; }, 5 * 60 * 1000);

// ===== EMAIL (real Gmail-only verification) =====
// Only @gmail.com addresses are accepted — no tempmail / other domains.
function isGmail(email) {
  if (typeof email !== 'string') return false;
  const e = email.trim().toLowerCase();
  return /^[a-z0-9](?:[a-z0-9._%+-]{0,63}[a-z0-9])?@gmail\.com$/.test(e);
}

// Real sending requires a Gmail account + App Password, configured via env vars
// GMAIL_USER and GMAIL_APP_PASSWORD (see README section printed on startup below).
let mailTransport = null;
const gmailUser = process.env.GMAIL_USER ? process.env.GMAIL_USER.trim() : '';
const gmailPass = process.env.GMAIL_APP_PASSWORD ? process.env.GMAIL_APP_PASSWORD.replace(/\s+/g, '') : ''; // Google shows the App Password with spaces for readability — the actual password has none
if (nodemailer && gmailUser && gmailPass) {
  mailTransport = nodemailer.createTransport({
    service: 'gmail',
    auth: { user: gmailUser, pass: gmailPass }
  });
  // fail fast with a clear message instead of silently falling back per-email
  mailTransport.verify((err) => {
    if (err) console.log('❌ Gmail SMTP login failed — check GMAIL_USER / GMAIL_APP_PASSWORD:', err.message);
    else console.log('✅ Gmail SMTP connected — real verification emails will be sent to ' + gmailUser);
  });
}
async function sendCodeEmail(toEmail, code) {
  if (!mailTransport) {
    // No real SMTP configured yet — code is only visible in the server console.
    console.log(`\n📧  [NO SMTP CONFIGURED] Verification code for ${toEmail}: ${code}\n    Set GMAIL_USER + GMAIL_APP_PASSWORD to send real emails (see README).\n`);
    return { sent: false };
  }
  try {
    await mailTransport.sendMail({
      from: `PeyamApp <${gmailUser}>`,
      to: toEmail,
      subject: `${code} is your PeyamApp verification code`,
      text: `Your PeyamApp verification code is: ${code}\n\nThis code expires in 10 minutes. If you didn't request this, ignore this email.`,
      html: `<div style="font-family:sans-serif;padding:24px">
        <h2 style="color:#7c5cff">PeyamApp</h2>
        <p>Your verification code is:</p>
        <div style="font-size:28px;font-weight:700;letter-spacing:4px;background:#f2f0ff;color:#4b3aad;padding:14px 20px;border-radius:10px;display:inline-block">${code}</div>
        <p style="color:#666;margin-top:16px;font-size:13px">This code expires in 10 minutes. If you didn't request this, you can safely ignore this email.</p>
      </div>`
    });
    return { sent: true };
  } catch (e) {
    console.log('Email send failed:', e.message);
    return { sent: false, error: e.message };
  }
}

// ===== WEB PUSH (real notifications when the app/tab is fully closed) =====
const VAPID_FILE = path.join(__dirname, 'vapid.json');
let vapidKeys = null;
if (webpush) {
  if (fs.existsSync(VAPID_FILE)) {
    vapidKeys = JSON.parse(fs.readFileSync(VAPID_FILE, 'utf8'));
  } else {
    vapidKeys = webpush.generateVAPIDKeys();
    fs.writeFileSync(VAPID_FILE, JSON.stringify(vapidKeys, null, 2));
  }
  webpush.setVapidDetails('mailto:admin@peyamapp.local', vapidKeys.publicKey, vapidKeys.privateKey);
}
function pushToUser(email, payload) {
  if (!webpush || !vapidKeys) return;
  const u = users[email];
  if (!u || !u.pushSubs || !u.pushSubs.length) return;
  const body = JSON.stringify(payload);
  u.pushSubs = u.pushSubs.filter(sub => {
    webpush.sendNotification(sub, body).catch(err => {
      if (err.statusCode === 410 || err.statusCode === 404) return false; // stale subscription, drop it
    });
    return true;
  });
}
function pushToUsername(username, payload) {
  const u = Object.values(users).find(u => u.username === username);
  if (u) pushToUser(u.email, payload);
}

// ===== AUTH =====
app.post('/api/send-code', async (req, res) => {
  const { email } = req.body || {};
  if (!email) return res.json({ ok: false, msg: 'Email required' });
  if (!isGmail(email)) return res.json({ ok: false, msg: 'Only real @gmail.com addresses are allowed. Temporary/disposable emails are blocked.' });
  const clean = email.trim().toLowerCase();
  const code = genCode();
  codes[clean] = { code, expires: Date.now() + 10 * 60 * 1000 };
  const result = await sendCodeEmail(clean, code);
  res.json({ ok: true, emailSent: result.sent });
});

app.post('/api/verify-code', (req, res) => {
  const { email, code } = req.body || {};
  if (!email || !isGmail(email)) return res.json({ ok: false, msg: 'Invalid email' });
  const clean = email.trim().toLowerCase();
  const rec = codes[clean];
  if (!rec || !code || rec.code !== String(code).toUpperCase() || Date.now() > rec.expires) return res.json({ ok: false, msg: 'Wrong or expired code' });
  delete codes[clean];
  const isNew = !users[clean];
  if (isNew) { users[clean] = newUser(clean); saveDB(); }
  const token = genToken();
  sessions[token] = clean;
  res.json({ ok: true, token, isNew });
});

app.post('/api/setup-profile', (req, res) => {
  const { token, username, name } = req.body || {};
  const email = sessions[token];
  if (!email) return res.json({ ok: false, msg: 'Not authenticated' });
  if (!username || !name) return res.json({ ok: false, msg: 'Username and name required' });
  let u2 = username.trim();
  if (u2[0] !== '@') u2 = '@' + u2;
  if (!/^@[a-zA-Z0-9_]{3,32}$/.test(u2)) return res.json({ ok: false, msg: 'Username must be 3-32 letters, numbers or _' });
  const taken = Object.values(users).find(u => u.username === u2 && u.email !== email);
  if (taken) return res.json({ ok: false, msg: 'Username already taken' });
  users[email].username = u2;
  users[email].name = name.trim();
  saveDB();
  res.json({ ok: true });
});

function requireAuth(req, res) {
  const token = req.headers.authorization;
  const email = sessions[token];
  if (!email) { res.json({ ok: false, msg: 'Not authenticated' }); return null; }
  return email;
}

app.get('/api/me', (req, res) => {
  const email = sessions[req.headers.authorization];
  if (!email || !users[email]) return res.json({ ok: false });
  const u = users[email];
  const needs2FA = u.twoFA && (Date.now() - u.twoFALastVerified > 24 * 60 * 60 * 1000);
  res.json({ ok: true, user: sanitize(u), needs2FA });
});

function sanitize(u) {
  return { email: u.email, username: u.username, name: u.name, lastName: u.lastName || '', about: u.about, avatar: u.avatar, twoFA: u.twoFA, passkeySet: !!u.passkey, securityNotifications: u.securityNotifications !== false, privacy: u.privacy };
}

app.post('/api/update-profile', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const { name, lastName, username, about, avatar, securityNotifications } = req.body || {};
  if (username) {
    let u2 = username.trim();
    if (u2[0] !== '@') u2 = '@' + u2;
    if (!/^@[a-zA-Z0-9_]{3,32}$/.test(u2)) return res.json({ ok: false, msg: 'Invalid username' });
    const taken = Object.values(users).find(u => u.username === u2 && u.email !== email);
    if (taken) return res.json({ ok: false, msg: 'Username taken' });
    users[email].username = u2;
  }
  if (name !== undefined) users[email].name = name;
  if (lastName !== undefined) users[email].lastName = lastName;
  if (about !== undefined) users[email].about = about;
  if (avatar !== undefined) users[email].avatar = avatar;
  if (securityNotifications !== undefined) users[email].securityNotifications = !!securityNotifications;
  saveDB();
  res.json({ ok: true });
});

app.post('/api/change-email', async (req, res) => {
  const oldEmail = requireAuth(req, res); if (!oldEmail) return;
  const { newEmail, code } = req.body || {};
  if (!isGmail(newEmail)) return res.json({ ok: false, msg: 'Only real @gmail.com addresses are allowed' });
  const clean = newEmail.trim().toLowerCase();
  const rec = codes[clean];
  if (!rec || !code || rec.code !== String(code).toUpperCase() || Date.now() > rec.expires) return res.json({ ok: false, msg: 'Wrong or expired code' });
  if (users[clean]) return res.json({ ok: false, msg: 'Email already in use' });
  const u = users[oldEmail];
  u.email = clean;
  users[clean] = u;
  delete users[oldEmail];
  delete codes[clean];
  for (const t in sessions) if (sessions[t] === oldEmail) sessions[t] = clean;
  saveDB();
  res.json({ ok: true });
});

// ===== 2FA =====
app.post('/api/request-2fa-code', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const code = genCode();
  users[email].twoFASetupCode = code;
  console.log(`[2FA setup code] ${email}: ${code}`);
  res.json({ ok: true });
});
app.post('/api/confirm-2fa-setup', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const { code } = req.body || {};
  if (!code || String(code).toUpperCase() !== users[email].twoFASetupCode) return res.json({ ok: false, msg: 'Wrong code' });
  users[email].twoFA = true;
  users[email].twoFALastVerified = Date.now();
  users[email].twoFASetupCode = null;
  saveDB();
  res.json({ ok: true });
});
app.post('/api/disable-2fa', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  users[email].twoFA = false;
  saveDB();
  res.json({ ok: true });
});
app.post('/api/request-2fa-recheck', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const code = genCode();
  users[email].twoFARecheckCode = code;
  console.log(`[2FA recheck code] ${email}: ${code}`);
  res.json({ ok: true });
});
app.post('/api/verify-2fa-recheck', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const { code } = req.body || {};
  if (!code || String(code).toUpperCase() !== users[email].twoFARecheckCode) return res.json({ ok: false, msg: 'Wrong code' });
  users[email].twoFALastVerified = Date.now();
  saveDB();
  res.json({ ok: true });
});

// ===== PASSKEY (system-generated 7-character security code) =====
app.post('/api/generate-passkey', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const code = genCode();
  users[email].passkey = code;
  saveDB();
  res.json({ ok: true, passkey: code });
});
app.post('/api/remove-passkey', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  users[email].passkey = '';
  saveDB();
  res.json({ ok: true });
});

// ===== PRIVACY =====
app.post('/api/update-privacy', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const { privacy } = req.body || {};
  users[email].privacy = { ...users[email].privacy, ...privacy };
  saveDB();
  res.json({ ok: true });
});

// ===== USER LOOKUP (privacy-aware, dedicated find-by-username endpoint) =====
app.get('/api/user/:username', (req, res) => {
  const meEmail = sessions[req.headers.authorization];
  const u = Object.values(users).find(u => u.username === req.params.username);
  if (!u) return res.json({ ok: false, msg: 'User not found' });
  const isOnline = Object.values(onlineSockets).includes(u.email);
  const priv = u.privacy || {};
  const showLastSeen = priv.lastSeen !== 'nobody';
  const meUsername = meEmail ? users[meEmail]?.username : null;
  const areFriends = meUsername ? (u.friends || []).includes(meUsername) : false;
  let friendStatus = 'none';
  if (areFriends) friendStatus = 'friends';
  else if (meUsername && requests[reqKey(meUsername, u.username)]?.status === 'pending') friendStatus = 'pending_sent';
  else if (meUsername && requests[reqKey(u.username, meUsername)]?.status === 'pending') friendStatus = 'pending_received';
  res.json({
    ok: true,
    user: {
      username: u.username,
      name: u.name,
      about: priv.about !== 'nobody' ? u.about : '',
      avatar: priv.profilePic !== 'nobody' ? u.avatar : '',
      online: showLastSeen ? isOnline : null,
      readReceipts: priv.readReceipts,
      friendStatus
    }
  });
});

// ===== FRIEND REQUESTS (must be accepted before messaging is allowed) =====
app.post('/api/send-request', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const me = users[email];
  if (!me.username) return res.json({ ok: false, msg: 'Set up your profile first' });
  const { toUsername } = req.body || {};
  const target = Object.values(users).find(u => u.username === toUsername);
  if (!target) return res.json({ ok: false, msg: 'User not found' });
  if (target.username === me.username) return res.json({ ok: false, msg: "You can't message yourself here — use Saved Messages" });
  if ((me.friends || []).includes(target.username)) return res.json({ ok: false, msg: 'Already connected' });
  const key = reqKey(me.username, target.username);
  const reverseKey = reqKey(target.username, me.username);
  if (requests[reverseKey]?.status === 'pending') return res.json({ ok: false, msg: 'They already sent you a request — check your Requests' });
  if (requests[key]?.status === 'pending') return res.json({ ok: false, msg: 'Request already sent' });
  requests[key] = { from: me.username, to: target.username, status: 'pending', time: Date.now() };
  saveDB();
  Object.entries(onlineSockets).forEach(([sid, em]) => { if (users[em]?.username === target.username) io.to(sid).emit('newRequest', { from: me.username }); });
  pushToUsername(target.username, { title: 'New message request', body: me.username + ' wants to message you', tag: 'request-' + me.username });
  res.json({ ok: true });
});

app.get('/api/requests', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const myUsername = users[email].username;
  const incoming = Object.values(requests).filter(r => r.to === myUsername && r.status === 'pending');
  const outgoing = Object.values(requests).filter(r => r.from === myUsername && r.status === 'pending');
  res.json({ ok: true, incoming, outgoing });
});

app.post('/api/respond-request', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const me = users[email];
  const { fromUsername, accept } = req.body || {};
  const key = reqKey(fromUsername, me.username);
  const r = requests[key];
  if (!r || r.status !== 'pending') return res.json({ ok: false, msg: 'Request not found' });
  if (accept) {
    r.status = 'accepted';
    const fromUser = Object.values(users).find(u => u.username === fromUsername);
    if (fromUser) {
      if (!fromUser.friends.includes(me.username)) fromUser.friends.push(me.username);
      if (!me.friends.includes(fromUsername)) me.friends.push(fromUsername);
    }
    Object.entries(onlineSockets).forEach(([sid, em]) => { if (users[em]?.username === fromUsername) io.to(sid).emit('requestAccepted', { by: me.username }); });
    pushToUsername(fromUsername, { title: 'Request accepted', body: me.username + ' accepted your message request', tag: 'accept-' + me.username });
  } else {
    r.status = 'declined';
  }
  saveDB();
  res.json({ ok: true });
});

// ===== CONTACTS (saved like a phone address book — resolved by username or email) =====
function resolveIdentifier(id) {
  if (!id) return null;
  const clean = id.trim();
  if (clean.includes('@') && !clean.startsWith('@')) return users[clean.toLowerCase()] || null; // email
  const uname = clean.startsWith('@') ? clean : '@' + clean;
  return Object.values(users).find(u => u.username === uname) || null;
}
app.post('/api/contacts/add', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const { firstName, lastName, identifier } = req.body || {};
  if (!firstName || !identifier) return res.json({ ok: false, msg: 'First name and username/email are required' });
  const target = resolveIdentifier(identifier);
  if (!target) return res.json({ ok: false, msg: 'No PeyamApp user found with that username/email' });
  if (target.email === email) return res.json({ ok: false, msg: "That's you!" });
  const me = users[email];
  const existing = me.contacts.find(c => c.username === target.username);
  if (existing) { existing.firstName = firstName; existing.lastName = lastName || ''; }
  else me.contacts.push({ firstName, lastName: lastName || '', username: target.username, addedAt: Date.now() });
  saveDB();
  res.json({ ok: true });
});
app.get('/api/contacts', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const me = users[email];
  const list = (me.contacts || []).map(c => {
    const u = Object.values(users).find(u => u.username === c.username);
    return { firstName: c.firstName, lastName: c.lastName, username: c.username, avatar: u?.avatar || '', online: Object.values(onlineSockets).includes(u?.email) };
  });
  res.json({ ok: true, contacts: list });
});
app.post('/api/contacts/remove', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const { username } = req.body || {};
  users[email].contacts = (users[email].contacts || []).filter(c => c.username !== username);
  saveDB();
  res.json({ ok: true });
});

// ===== GROUPS =====
function genGroupId() { return 'g_' + crypto.randomBytes(8).toString('hex'); }
function myGroups(username) { return Object.values(groups).filter(g => g.members.includes(username)); }
app.post('/api/groups/create', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const me = users[email];
  const { name, memberUsernames, photo, permissions } = req.body || {};
  if (!name || !Array.isArray(memberUsernames) || !memberUsernames.length) return res.json({ ok: false, msg: 'Name and at least one member required' });
  const id = genGroupId();
  const members = Array.from(new Set([me.username, ...memberUsernames]));
  groups[id] = {
    id, name, photo: photo || '', owner: me.username, admins: [me.username], members,
    pendingApprovals: [],
    permissions: { sendMessages: 'everyone', editGroupInfo: 'adminsOnly', addMembers: 'everyone', showHistoryToNew: true, approveNewMembers: false, ...(permissions || {}) },
    createdAt: Date.now()
  };
  saveDB();
  members.forEach(m => Object.entries(onlineSockets).forEach(([sid, em]) => { if (users[em]?.username === m) io.to(sid).emit('groupCreated', groups[id]); }));
  res.json({ ok: true, group: groups[id] });
});
app.get('/api/groups', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  res.json({ ok: true, groups: myGroups(users[email].username) });
});
app.get('/api/groups/:id', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const g = groups[req.params.id];
  if (!g || !g.members.includes(users[email].username)) return res.json({ ok: false, msg: 'Not found' });
  res.json({ ok: true, group: g });
});
app.post('/api/groups/:id/update', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const g = groups[req.params.id];
  const myUsername = users[email].username;
  if (!g || !g.members.includes(myUsername)) return res.json({ ok: false, msg: 'Not found' });
  const isAdmin = g.admins.includes(myUsername);
  if (g.permissions.editGroupInfo === 'adminsOnly' && !isAdmin) return res.json({ ok: false, msg: 'Only admins can edit group info' });
  const { name, photo, permissions } = req.body || {};
  if (name !== undefined) g.name = name;
  if (photo !== undefined) g.photo = photo;
  if (permissions !== undefined && isAdmin) g.permissions = { ...g.permissions, ...permissions };
  saveDB();
  g.members.forEach(m => Object.entries(onlineSockets).forEach(([sid, em]) => { if (users[em]?.username === m) io.to(sid).emit('groupUpdated', g); }));
  res.json({ ok: true, group: g });
});
app.post('/api/groups/:id/add-member', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const g = groups[req.params.id];
  const myUsername = users[email].username;
  if (!g || !g.members.includes(myUsername)) return res.json({ ok: false, msg: 'Not found' });
  const isAdmin = g.admins.includes(myUsername);
  if (g.permissions.addMembers === 'adminsOnly' && !isAdmin) return res.json({ ok: false, msg: 'Only admins can add members' });
  const { username } = req.body || {};
  const target = Object.values(users).find(u => u.username === username);
  if (!target) return res.json({ ok: false, msg: 'User not found' });
  if (g.permissions.approveNewMembers && !isAdmin) {
    if (!g.pendingApprovals.includes(username)) g.pendingApprovals.push(username);
  } else if (!g.members.includes(username)) g.members.push(username);
  saveDB();
  res.json({ ok: true, group: g });
});
app.post('/api/groups/:id/approve-member', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const g = groups[req.params.id];
  const myUsername = users[email].username;
  if (!g || !g.admins.includes(myUsername)) return res.json({ ok: false, msg: 'Admins only' });
  const { username, accept } = req.body || {};
  g.pendingApprovals = g.pendingApprovals.filter(u => u !== username);
  if (accept && !g.members.includes(username)) g.members.push(username);
  saveDB();
  res.json({ ok: true, group: g });
});
app.post('/api/groups/:id/leave', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const g = groups[req.params.id];
  const myUsername = users[email].username;
  if (!g) return res.json({ ok: false });
  g.members = g.members.filter(m => m !== myUsername);
  g.admins = g.admins.filter(m => m !== myUsername);
  saveDB();
  res.json({ ok: true });
});


app.post('/api/upload', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  upload.single('file')(req, res, (err) => {
    if (err) return res.json({ ok: false, msg: err.message });
    if (!req.file) return res.json({ ok: false, msg: 'No file received' });
    const mime = req.file.mimetype || '';
    let kind = 'file';
    if (mime.startsWith('image/')) kind = 'image';
    else if (mime.startsWith('video/')) kind = 'video';
    res.json({ ok: true, url: '/uploads/' + req.file.filename, name: req.file.originalname, size: req.file.size, kind, mime });
  });
});

function isGroupChat(cid) { return cid.startsWith('group:'); }
function chatMembers(cid) {
  if (isGroupChat(cid)) { const g = groups[cid.slice(6)]; return g ? g.members : []; }
  return cid.split('::');
}
app.get('/api/messages/:chatId', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const myUsername = users[email].username;
  if (!chatMembers(req.params.chatId).includes(myUsername)) return res.json({ ok: false, msg: 'Not your chat' });
  res.json({ ok: true, messages: messages[req.params.chatId] || [] });
});

app.get('/api/chats', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const myUsername = users[email]?.username;
  const myChats = [];
  for (const [cid, msgs] of Object.entries(messages)) {
    if (!chatMembers(cid).includes(myUsername)) continue;
    const last = msgs[msgs.length - 1];
    let other = null, groupName = null, groupPhoto = null;
    if (isGroupChat(cid)) { const g = groups[cid.slice(6)]; groupName = g?.name; groupPhoto = g?.photo; }
    else other = cid.split('::').find(p => p !== myUsername) || cid.split('::')[0];
    let preview = last?.text || '';
    if (last?.deleted) preview = 'This message was deleted';
    else if (last?.attachment?.kind === 'image') preview = '📷 Photo';
    else if (last?.attachment?.kind === 'video') preview = '🎥 Video';
    else if (last?.attachment?.kind === 'voice') preview = '🎤 Voice message';
    else if (last?.attachment?.kind === 'file') preview = '📄 ' + (last.attachment.name || 'File');
    myChats.push({ chatId: cid, other, isGroup: isGroupChat(cid), groupName, groupPhoto, lastMsg: preview, lastFrom: last?.from, lastTime: last?.time || '', lastTs: last?.id || 0, lastStatus: last?.status });
  }
  myChats.sort((a, b) => b.lastTs - a.lastTs);
  res.json({ ok: true, chats: myChats });
});


// ===== WEB PUSH SUBSCRIPTION =====
app.get('/api/vapid-public-key', (req, res) => {
  res.json({ ok: true, key: vapidKeys ? vapidKeys.publicKey : null });
});
app.post('/api/push-subscribe', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const { subscription } = req.body || {};
  if (!subscription || !subscription.endpoint) return res.json({ ok: false });
  const u = users[email];
  if (!u.pushSubs.find(s => s.endpoint === subscription.endpoint)) u.pushSubs.push(subscription);
  saveDB();
  res.json({ ok: true });
});
app.post('/api/push-unsubscribe', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const { endpoint } = req.body || {};
  users[email].pushSubs = (users[email].pushSubs || []).filter(s => s.endpoint !== endpoint);
  saveDB();
  res.json({ ok: true });
});

// ===== STORIES =====
app.post('/api/post-story', (req, res) => {
  const email = requireAuth(req, res); if (!email) return;
  const username = users[email].username;
  const { image, text } = req.body || {};
  if (!stories[username]) stories[username] = [];
  stories[username].push({ id: Date.now(), image: image || null, text: text || '', time: nowTime(), expires: Date.now() + 24 * 60 * 60 * 1000 });
  saveDB();
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
function emitToUsernames(usernames, event, payload) {
  Object.entries(onlineSockets).forEach(([sid, email]) => { const u = users[email]; if (u && usernames.includes(u.username)) io.to(sid).emit(event, payload); });
}
io.on('connection', (socket) => {
  socket.on('auth', (token) => {
    const email = sessions[token];
    if (!email || !users[email]) return;
    socket.email = email;
    socket.username = users[email].username;
    onlineSockets[socket.id] = email;
    io.emit('online', Object.values(onlineSockets).map(e => users[e]?.username).filter(Boolean));
    // flip any messages sent TO me while I was offline from 'sent' to 'delivered', and tell the senders
    const affectedSenders = new Set();
    for (const [cid, msgs] of Object.entries(messages)) {
      if (isGroupChat(cid)) continue; // delivered/read receipts are 1:1 only
      if (!cid.split('::').includes(socket.username)) continue;
      msgs.forEach(m => { if (m.to === socket.username && m.status === 'sent') { m.status = 'delivered'; affectedSenders.add(m.from); } });
    }
    if (affectedSenders.size) { saveDB(); emitToUsernames([...affectedSenders], 'msgsDelivered', { by: socket.username }); }
  });

  socket.on('sendMsg', ({ to, text, attachment, groupId }) => {
    if (!socket.username) return;
    const me = users[socket.email];
    let cid, members;
    if (groupId) {
      const g = groups[groupId];
      if (!g || !g.members.includes(socket.username)) return;
      const isAdmin = g.admins.includes(socket.username);
      if (g.permissions.sendMessages === 'adminsOnly' && !isAdmin) { socket.emit('msgBlocked', { msg: 'Only admins can send messages in this group.' }); return; }
      cid = 'group:' + groupId;
      members = g.members;
    } else {
      const target = Object.values(users).find(u => u.username === to);
      if (!target) return;
      if (!(me.friends || []).includes(to)) { socket.emit('msgBlocked', { to, msg: 'You must send a message request first.' }); return; }
      cid = chatId(socket.username, to);
      members = [socket.username, to];
    }
    if (!messages[cid]) messages[cid] = [];
    const recipientOnline = groupId ? true : members.some(m => m !== socket.username && Object.values(onlineSockets).some(sid => users[onlineSockets[sid]]?.username === m));
    const msg = { from: socket.username, to: to || null, groupId: groupId || null, text: text || '', attachment: attachment || null, time: nowTime(), id: Date.now(), edited: false, deleted: false, status: recipientOnline ? 'delivered' : 'sent', reactions: {} };
    messages[cid].push(msg);
    saveDB();
    emitToUsernames(members, 'newMsg', { ...msg, chatId: cid });
    let preview = msg.text;
    if (msg.attachment?.kind === 'image') preview = '📷 Photo';
    else if (msg.attachment?.kind === 'video') preview = '🎥 Video';
    else if (msg.attachment?.kind === 'voice') preview = '🎤 Voice message';
    else if (msg.attachment?.kind === 'file') preview = '📄 ' + (msg.attachment.name || 'File');
    if (groupId) members.filter(m => m !== socket.username).forEach(m => pushToUsername(m, { title: groups[groupId].name, body: socket.username + ': ' + preview, tag: 'chat-' + cid, chatId: cid, from: socket.username }));
    else pushToUsername(to, { title: socket.username, body: preview, tag: 'chat-' + cid, chatId: cid, from: socket.username });
  });

  socket.on('markRead', ({ chatId: cid }) => {
    if (!socket.username || !messages[cid]) return;
    let changed = false;
    const notifySenders = new Set();
    messages[cid].forEach(m => {
      const iAmRecipient = m.groupId ? (m.from !== socket.username) : (m.to === socket.username);
      if (iAmRecipient && m.status !== 'read') { m.status = 'read'; changed = true; notifySenders.add(m.from); }
    });
    if (changed) { saveDB(); emitToUsernames([...notifySenders, socket.username], 'msgsRead', { chatId: cid, reader: socket.username }); }
  });

  socket.on('reactMsg', ({ chatId: cid, id, emoji }) => {
    if (!socket.username || !messages[cid]) return;
    const msg = messages[cid].find(m => m.id === id);
    if (!msg) return;
    if (!msg.reactions) msg.reactions = {};
    if (msg.reactions[socket.username] === emoji) delete msg.reactions[socket.username]; // toggle off
    else msg.reactions[socket.username] = emoji;
    saveDB();
    emitToUsernames(chatMembers(cid), 'msgReacted', { chatId: cid, id, reactions: msg.reactions });
  });

  socket.on('editMsg', ({ chatId: cid, id, text }) => {
    if (!socket.username || !messages[cid]) return;
    const msg = messages[cid].find(m => m.id === id);
    if (!msg || msg.from !== socket.username || msg.deleted) return; // only the sender can edit, own message only
    msg.text = text;
    msg.edited = true;
    saveDB();
    emitToUsernames(chatMembers(cid), 'msgEdited', { chatId: cid, id, text });
  });

  socket.on('deleteMsg', ({ chatId: cid, id, scope }) => {
    // scope: 'everyone' (sender only) or 'me' is handled purely client-side
    if (!socket.username || !messages[cid]) return;
    const msg = messages[cid].find(m => m.id === id);
    if (!msg || msg.from !== socket.username) return; // only the sender can delete-for-everyone
    msg.deleted = true;
    msg.text = ''; msg.attachment = null;
    saveDB();
    emitToUsernames(chatMembers(cid), 'msgDeleted', { chatId: cid, id });
  });

  // ===== CALLING (voice or video) =====
  // Step 1: caller pings callee, no media/offer yet (no permission was silently used).
  socket.on('callUser', ({ to, video }) => {
    emitToUsernames([to], 'incomingCall', { from: socket.username, video: !!video });
    pushToUsername(to, { title: video ? 'Incoming video call' : 'Incoming call', body: socket.username + ' is calling you', tag: 'call-' + socket.username, call: true, from: socket.username });
  });
  // Step 2: callee accepts/declines. Only on accept does the caller create the WebRTC offer.
  socket.on('callResponse', ({ to, accepted }) => {
    emitToUsernames([to], 'callResponse', { accepted, from: socket.username });
  });
  socket.on('endCall', ({ to }) => {
    emitToUsernames([to], 'callEnded', {});
  });

  // ===== WEBRTC SIGNALING (real voice/video call media) =====
  socket.on('rtc-offer', ({ to, offer }) => { emitToUsernames([to], 'rtc-offer', { from: socket.username, offer }); });
  socket.on('rtc-answer', ({ to, answer }) => { emitToUsernames([to], 'rtc-answer', { from: socket.username, answer }); });
  socket.on('rtc-ice', ({ to, candidate }) => { emitToUsernames([to], 'rtc-ice', { from: socket.username, candidate }); });

  socket.on('disconnect', () => {
    delete onlineSockets[socket.id];
    io.emit('online', Object.values(onlineSockets).map(e => users[e]?.username).filter(Boolean));
  });
});

server.listen(PORT, () => {
  const proto = (fs.existsSync(certPath) && fs.existsSync(keyPath)) ? 'https' : 'http';
  console.log(`✅ PeyamApp: ${proto}://localhost:${PORT}  (or ${proto}://<your-phone-ip>:${PORT} from other devices)`);
  if (!mailTransport) {
    console.log('⚠️  Real email sending is OFF. To send real verification codes to @gmail.com addresses:');
    console.log('    1) Create a Gmail App Password: https://myaccount.google.com/apppasswords');
    console.log('    2) Run the server with:  GMAIL_USER="you@gmail.com" GMAIL_APP_PASSWORD="xxxx xxxx xxxx xxxx" node server.js');
    console.log('    Until then, codes are printed here in the console.');
  }
  if (!webpush) console.log('⚠️  web-push module not installed — run "npm install" to enable real closed-app notifications.');
});

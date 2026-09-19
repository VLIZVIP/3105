'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const express = require('express');
const multer = require('multer');

const app = express();
app.set('trust proxy', 1);
app.disable('x-powered-by');

const PORT = Number(process.env.PORT || 3000);
const STORAGE_DIR = path.resolve(
  process.env.STORAGE_DIR || process.env.RAILWAY_VOLUME_MOUNT_PATH || path.join(process.cwd(), 'data')
);
const FILES_DIR = path.join(STORAGE_DIR, 'patches');
const UPLOAD_DIR = path.join(STORAGE_DIR, 'uploads');
const MANIFEST_PATH = path.join(STORAGE_DIR, 'manifest.json');
const MAX_FILE_SIZE = 250 * 1024 * 1024;
const PATCH_MAGIC = Buffer.from('3105PATCH\0', 'utf8');
const COOKIE_NAME = 'vliz_admin';
const SESSION_HOURS = 12;

for (const directory of [STORAGE_DIR, FILES_DIR, UPLOAD_DIR]) {
  fs.mkdirSync(directory, { recursive: true });
}
if (!fs.existsSync(MANIFEST_PATH)) {
  fs.writeFileSync(MANIFEST_PATH, '[]\n', { encoding: 'utf8', flag: 'wx' });
}

app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  res.setHeader('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
  res.setHeader(
    'Content-Security-Policy',
    "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
  );
  next();
});

app.use(express.json({ limit: '64kb' }));
app.use(express.urlencoded({ extended: false, limit: '16kb' }));

const upload = multer({
  dest: UPLOAD_DIR,
  limits: { fileSize: MAX_FILE_SIZE, files: 1, fields: 8 },
  fileFilter: (_req, file, callback) => {
    callback(null, path.extname(file.originalname).toLowerCase() === '.3105');
  }
});

let mutationQueue = Promise.resolve();
const loginAttempts = new Map();

function enqueueMutation(operation) {
  const result = mutationQueue.then(operation, operation);
  mutationQueue = result.catch(() => {});
  return result;
}

async function readManifest() {
  const raw = await fs.promises.readFile(MANIFEST_PATH, 'utf8');
  const parsed = JSON.parse(raw);
  return Array.isArray(parsed) ? parsed : [];
}

async function writeManifest(items) {
  const temporary = MANIFEST_PATH + '.tmp';
  await fs.promises.writeFile(temporary, JSON.stringify(items, null, 2) + '\n', 'utf8');
  await fs.promises.copyFile(temporary, MANIFEST_PATH);
  await fs.promises.unlink(temporary).catch(() => {});
}

function cleanText(value, maximum, fallback = '') {
  const result = String(value || '').replace(/[\u0000-\u001f\u007f]/g, '').trim();
  return (result || fallback).slice(0, maximum);
}

function safeEqual(left, right) {
  const a = crypto.createHash('sha256').update(String(left)).digest();
  const b = crypto.createHash('sha256').update(String(right)).digest();
  return crypto.timingSafeEqual(a, b);
}

function sessionSecret() {
  return process.env.SESSION_SECRET || '';
}

function configured() {
  return Boolean(process.env.ADMIN_PASSWORD && sessionSecret().length >= 32);
}

function createSessionToken() {
  const payload = Buffer.from(JSON.stringify({
    exp: Date.now() + SESSION_HOURS * 60 * 60 * 1000,
    nonce: crypto.randomBytes(16).toString('hex')
  })).toString('base64url');
  const signature = crypto.createHmac('sha256', sessionSecret()).update(payload).digest('base64url');
  return payload + '.' + signature;
}

function parseCookies(req) {
  return Object.fromEntries(
    String(req.headers.cookie || '')
      .split(';')
      .map((part) => part.trim())
      .filter(Boolean)
      .map((part) => {
        const index = part.indexOf('=');
        return index < 0 ? [part, ''] : [part.slice(0, index), decodeURIComponent(part.slice(index + 1))];
      })
  );
}

function validSession(req) {
  if (!configured()) return false;
  const token = parseCookies(req)[COOKIE_NAME];
  if (!token) return false;
  const [payload, suppliedSignature] = token.split('.');
  if (!payload || !suppliedSignature) return false;
  const expected = crypto.createHmac('sha256', sessionSecret()).update(payload).digest('base64url');
  if (!safeEqual(suppliedSignature, expected)) return false;
  try {
    const parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    return Number(parsed.exp) > Date.now();
  } catch {
    return false;
  }
}

function requireAdmin(req, res, next) {
  if (!validSession(req)) return res.status(401).json({ error: 'Sesión no válida.' });
  next();
}

function sameOrigin(req) {
  const origin = req.get('origin');
  if (!origin) return true;
  try {
    const originURL = new URL(origin);
    const forwardedHost = String(req.get('x-forwarded-host') || '')
      .split(',')[0]
      .trim()
      .toLowerCase();
    const requestHost = String(req.get('host') || '').toLowerCase();
    const configuredOrigin = String(process.env.PUBLIC_ORIGIN || '').trim();
    const allowedHosts = new Set([forwardedHost, requestHost].filter(Boolean));
    const railwayPublicDomain = String(process.env.RAILWAY_PUBLIC_DOMAIN || '')
      .trim()
      .toLowerCase();
    if (railwayPublicDomain) allowedHosts.add(railwayPublicDomain);
    allowedHosts.add('3105-zentry-ios-production.up.railway.app');
    if (configuredOrigin) {
      const configuredURL = new URL(configuredOrigin);
      if (configuredURL.protocol !== 'https:') return false;
      allowedHosts.add(configuredURL.host.toLowerCase());
    }
    return originURL.protocol === 'https:'
      && allowedHosts.has(originURL.host.toLowerCase());
  } catch {
    return false;
  }
}

function requireSameOrigin(req, res, next) {
  if (!sameOrigin(req)) return res.status(403).json({ error: 'Origen no permitido.' });
  next();
}

async function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

async function validatePatchFile(filePath) {
  const handle = await fs.promises.open(filePath, 'r');
  try {
    const header = Buffer.alloc(PATCH_MAGIC.length);
    const { bytesRead } = await handle.read(header, 0, header.length, 0);
    if (bytesRead !== PATCH_MAGIC.length || !header.equals(PATCH_MAGIC)) {
      throw new Error('El archivo no es un paquete .3105 válido.');
    }
  } finally {
    await handle.close();
  }
}

function publicPatch(item) {
  return {
    id: item.id,
    name: item.name,
    description: item.description,
    version: item.version,
    size: item.size,
    updatedAt: item.updatedAt,
    sha256: item.sha256,
    downloadUrl: '/api/patches/' + encodeURIComponent(item.id) + '/download'
  };
}

function layout(content, title = 'INJECT IOS Patches') {
  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title><style>
:root{color-scheme:dark;--bg:#070405;--panel:#171113;--panel2:#211619;--red:#f01426;--red2:#9e0b18;--text:#fff;--muted:#a9999e;--line:#3c282e;--ok:#22c987;--danger:#ff4052}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 70% -10%,#3d0710 0,transparent 38%),var(--bg);color:var(--text);font-family:Inter,ui-sans-serif,system-ui,-apple-system,sans-serif;min-height:100vh}
.shell{width:min(1120px,calc(100% - 32px));margin:auto;padding:34px 0 70px}.top{display:flex;align-items:center;justify-content:space-between;gap:20px;margin-bottom:28px}.brand{display:flex;align-items:center;gap:13px}.mark{width:48px;height:48px;border-radius:15px;background:linear-gradient(145deg,var(--red),#560811);display:grid;place-items:center;box-shadow:0 12px 36px #f0142640;font-weight:900}.eyebrow{color:#ff6c79;text-transform:uppercase;letter-spacing:.16em;font-size:12px;font-weight:800}h1,h2,p{margin:0}h1{font-size:clamp(24px,4vw,38px)}h2{font-size:20px}.muted{color:var(--muted)}
.card{background:linear-gradient(145deg,#1d1517,#120d0f);border:1px solid var(--line);border-radius:24px;padding:24px;box-shadow:0 22px 65px #0008}.grid{display:grid;grid-template-columns:360px 1fr;gap:22px}.stack{display:grid;gap:14px}.field{display:grid;gap:7px}.field span{font-size:13px;color:#c9b9be;font-weight:650}input,textarea,button{font:inherit}input,textarea{width:100%;background:#0d090a;border:1px solid #463037;border-radius:13px;color:white;padding:12px 14px;outline:none}input:focus,textarea:focus{border-color:var(--red);box-shadow:0 0 0 3px #f0142620}textarea{min-height:86px;resize:vertical}.btn{border:0;border-radius:13px;padding:11px 15px;color:white;background:#302226;font-weight:750;cursor:pointer}.btn:hover{filter:brightness(1.16)}.btn.primary{background:linear-gradient(135deg,var(--red),var(--red2))}.btn.danger{background:#54121a;color:#ffadb5}.btn.ghost{background:#24191c}.btn:disabled{opacity:.45;cursor:not-allowed}.file{border:1px dashed #66414a;padding:14px;border-radius:14px;background:#0d090a}.toolbar{display:flex;justify-content:space-between;align-items:center;gap:12px;margin-bottom:16px}.pill{font-size:12px;border:1px solid #57333b;border-radius:999px;padding:7px 11px;color:#ff9da6;background:#2b1116}.items{display:grid;gap:12px}.item{border:1px solid var(--line);border-radius:17px;padding:16px;background:#100b0d;display:grid;gap:12px}.item-head{display:flex;justify-content:space-between;gap:14px}.item h3{margin:0 0 5px;font-size:17px}.meta{display:flex;gap:10px;flex-wrap:wrap;color:var(--muted);font-size:12px}.actions{display:flex;gap:8px;flex-wrap:wrap}.empty{padding:56px 20px;text-align:center;color:var(--muted);border:1px dashed #493138;border-radius:18px}.notice{padding:12px 14px;border-radius:13px;background:#152d24;color:#8ff2ca;border:1px solid #245b46;display:none}.notice.error{background:#351318;color:#ffabb3;border-color:#69222c}.login{width:min(440px,calc(100% - 32px));margin:10vh auto}.login .card{display:grid;gap:18px}.status{font-size:13px;color:var(--muted)}
dialog{width:min(520px,calc(100% - 28px));border:1px solid var(--line);border-radius:22px;background:#171113;color:white;padding:0;box-shadow:0 30px 100px #000c}dialog::backdrop{background:#000b;backdrop-filter:blur(5px)}.modal-body{padding:24px;display:grid;gap:18px}.modal-head{display:flex;justify-content:space-between;align-items:flex-start;gap:15px}.modal-actions{display:flex;justify-content:flex-end;gap:10px;padding-top:4px}
@media(max-width:820px){.grid{grid-template-columns:1fr}.top{align-items:flex-start}.shell{padding-top:22px}.card{padding:18px}}
</style></head><body>${content}</body></html>`;
}

function loginPage(message = '') {
  return layout(`<main class="login"><section class="card"><div class="brand"><div class="mark">V</div><div><div class="eyebrow">Panel privado</div><h1>INJECT IOS</h1></div></div><p class="muted">Gestiona los parches que aparecen en la aplicación.</p>${message ? `<div class="notice error" style="display:block">${message}</div>` : ''}<form method="post" action="/admin/login" class="stack"><label class="field"><span>Contraseña de administrador</span><input name="password" type="password" autocomplete="current-password" required autofocus></label><button class="btn primary" type="submit">Entrar</button></form></section></main>`, 'Acceso · INJECT IOS');
}

function dashboardPage() {
  return layout(`<main class="shell"><header class="top"><div class="brand"><div class="mark">V</div><div><div class="eyebrow">Catálogo remoto</div><h1>INJECT IOS Patches</h1></div></div><button class="btn ghost" id="logout">Cerrar sesión</button></header><div id="notice" class="notice"></div><div class="grid"><section class="card"><h2>Publicar parche</h2><p class="muted" style="margin:7px 0 20px">Solo se admiten paquetes .3105 sin contraseña.</p><form id="uploadForm" class="stack"><label class="field"><span>Nombre visible</span><input name="name" maxlength="120" required></label><label class="field"><span>Versión</span><input name="version" maxlength="40" placeholder="1.0.0" required></label><label class="field"><span>Descripción</span><textarea name="description" maxlength="500"></textarea></label><label class="field file"><span>Archivo .3105</span><input name="file" type="file" accept=".3105" required></label><button class="btn primary" type="submit">Subir y publicar</button></form></section><section class="card"><div class="toolbar"><div><h2>Parches publicados</h2><p class="muted" id="count">Cargando…</p></div><button class="btn ghost" id="refresh">Actualizar</button></div><div id="items" class="items"></div></section></div></main><script>
const editorMarkup='<form id="editForm" class="modal-body"><div class="modal-head"><div><div class="eyebrow">Editar publicación</div><h2>Datos del parche</h2></div><button class="btn ghost" type="button" id="editClose" aria-label="Cerrar">✕</button></div><input name="id" type="hidden"><label class="field"><span>Nombre visible</span><input name="name" maxlength="120" required></label><label class="field"><span>Versión</span><input name="version" maxlength="40" required></label><label class="field"><span>Descripción</span><textarea name="description" maxlength="500"></textarea></label><div class="modal-actions"><button class="btn ghost" type="button" id="editCancel">Cancelar</button><button class="btn primary" type="submit">Guardar cambios</button></div></form>';const editor=document.createElement('dialog');editor.id='editDialog';editor.innerHTML=editorMarkup;document.body.append(editor);
const itemsEl=document.getElementById('items'),notice=document.getElementById('notice'),count=document.getElementById('count');
function show(message,error){notice.textContent=message;notice.className='notice'+(error?' error':'');notice.style.display='block';setTimeout(()=>notice.style.display='none',5000)}
function bytes(value){if(value<1024)return value+' B';const units=['KB','MB','GB'];let n=value/1024,i=0;while(n>=1024&&i<2){n/=1024;i++}return n.toFixed(n>=10?1:2)+' '+units[i]}
async function api(url,options){const response=await fetch(url,options);if(response.status===401){location.href='/admin';throw new Error('Sesión terminada.')}const body=await response.json().catch(()=>({}));if(!response.ok)throw new Error(body.error||'Operación fallida.');return body}
function button(text,kind,handler){const b=document.createElement('button');b.className='btn '+kind;b.textContent=text;b.onclick=handler;return b}
async function load(){itemsEl.innerHTML='';count.textContent='Cargando…';try{const data=await api('/api/admin/patches');count.textContent=data.patches.length+' publicado(s)';if(!data.patches.length){itemsEl.innerHTML='<div class="empty">Todavía no hay parches publicados.</div>';return}data.patches.forEach(render)}catch(error){show(error.message,true)}}
function render(item){const box=document.createElement('article');box.className='item';const head=document.createElement('div');head.className='item-head';const copy=document.createElement('div');const title=document.createElement('h3');title.textContent=item.name;const desc=document.createElement('p');desc.className='muted';desc.textContent=item.description||'Sin descripción';copy.append(title,desc);const badge=document.createElement('span');badge.className='pill';badge.textContent='v'+item.version;head.append(copy,badge);const meta=document.createElement('div');meta.className='meta';meta.textContent=bytes(item.size)+' · SHA-256 '+item.sha256.slice(0,12)+'… · '+new Date(item.updatedAt).toLocaleString();const actions=document.createElement('div');actions.className='actions';actions.append(button('Editar','ghost',()=>editItem(item)),button('Reemplazar archivo','ghost',()=>replaceFile(item)),button('Borrar','danger',()=>removeItem(item)));box.append(head,meta,actions);itemsEl.append(box)}
const editDialog=document.getElementById('editDialog'),editForm=document.getElementById('editForm');
function editItem(item){editForm.elements.id.value=item.id;editForm.elements.name.value=item.name;editForm.elements.version.value=item.version;editForm.elements.description.value=item.description||'';editDialog.showModal();editForm.elements.name.focus()}
function closeEditor(){editDialog.close();editForm.reset()}
editForm.onsubmit=async(event)=>{event.preventDefault();const save=editForm.querySelector('button[type="submit"]');save.disabled=true;const values=Object.fromEntries(new FormData(editForm));try{await api('/api/admin/patches/'+encodeURIComponent(values.id),{method:'PATCH',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:values.name,version:values.version,description:values.description})});closeEditor();show('Nombre, versión y descripción actualizados.');load()}catch(error){show(error.message,true)}finally{save.disabled=false}};
document.getElementById('editCancel').onclick=closeEditor;document.getElementById('editClose').onclick=closeEditor;editDialog.addEventListener('click',(event)=>{if(event.target===editDialog)closeEditor()});
async function replaceFile(item){const input=document.createElement('input');input.type='file';input.accept='.3105';input.onchange=async()=>{if(!input.files[0])return;const data=new FormData();data.append('file',input.files[0]);try{await api('/api/admin/patches/'+encodeURIComponent(item.id)+'/file',{method:'PUT',body:data});show('Archivo actualizado.');load()}catch(error){show(error.message,true)}};input.click()}
async function removeItem(item){if(!confirm('¿Borrar '+item.name+'? Esta acción lo quitará de la app.'))return;try{await api('/api/admin/patches/'+encodeURIComponent(item.id),{method:'DELETE'});show('Parche eliminado.');load()}catch(error){show(error.message,true)}}
document.getElementById('uploadForm').onsubmit=async(event)=>{event.preventDefault();const button=event.target.querySelector('button');button.disabled=true;try{await api('/api/admin/patches',{method:'POST',body:new FormData(event.target)});event.target.reset();show('Parche publicado.');load()}catch(error){show(error.message,true)}finally{button.disabled=false}};
document.getElementById('refresh').onclick=load;document.getElementById('logout').onclick=async()=>{await fetch('/admin/logout',{method:'POST'});location.href='/admin'};load();
</script>`);
}

app.get('/health', (_req, res) => res.json({ ok: true, service: 'vliz-vip-patches' }));
app.get('/', (_req, res) => res.redirect('/admin'));

app.get('/admin', (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (!configured()) {
    return res.status(503).send(loginPage('Configura ADMIN_PASSWORD y SESSION_SECRET en Railway.'));
  }
  res.send(validSession(req) ? dashboardPage() : loginPage());
});

// Login CSRF does not grant access without the administrator password. Railway
// may rewrite Origin/Host headers through multiple proxies, so origin checks
// remain required for every data mutation but are intentionally omitted here.
app.post('/admin/login', (req, res) => {
  if (!configured()) return res.status(503).send(loginPage('El panel todavía no está configurado.'));
  const key = req.ip || 'unknown';
  const current = loginAttempts.get(key) || { count: 0, blockedUntil: 0 };
  if (current.blockedUntil > Date.now()) {
    return res.status(429).send(loginPage('Demasiados intentos. Espera unos minutos.'));
  }
  if (!safeEqual(req.body.password || '', process.env.ADMIN_PASSWORD)) {
    current.count += 1;
    if (current.count >= 5) {
      current.count = 0;
      current.blockedUntil = Date.now() + 10 * 60 * 1000;
    }
    loginAttempts.set(key, current);
    return res.status(401).send(loginPage('Contraseña incorrecta.'));
  }
  loginAttempts.delete(key);
  const secure = req.secure || process.env.NODE_ENV === 'production';
  res.cookie(COOKIE_NAME, createSessionToken(), {
    httpOnly: true,
    secure,
    sameSite: 'strict',
    maxAge: SESSION_HOURS * 60 * 60 * 1000,
    path: '/'
  });
  res.redirect('/admin');
});

app.post('/admin/logout', requireSameOrigin, (req, res) => {
  res.clearCookie(COOKIE_NAME, { path: '/' });
  res.status(204).end();
});

app.get('/api/patches', async (_req, res, next) => {
  try {
    const items = await readManifest();
    res.setHeader('Cache-Control', 'public, max-age=30');
    res.json({ version: 1, patches: items.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt)).map(publicPatch) });
  } catch (error) { next(error); }
});

app.get('/api/patches/:id/download', async (req, res, next) => {
  try {
    const items = await readManifest();
    const item = items.find((entry) => entry.id === req.params.id);
    if (!item) return res.status(404).json({ error: 'Parche no encontrado.' });
    const filePath = path.join(FILES_DIR, item.storageName);
    res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
    res.setHeader('Content-Type', 'application/octet-stream');
    res.setHeader('Content-Disposition', `attachment; filename="${item.id}.3105"`);
    res.sendFile(filePath);
  } catch (error) { next(error); }
});

app.get('/api/admin/patches', requireAdmin, async (_req, res, next) => {
  try { res.json({ patches: await readManifest() }); }
  catch (error) { next(error); }
});

app.post('/api/admin/patches', requireSameOrigin, requireAdmin, upload.single('file'), async (req, res, next) => {
  const temporary = req.file?.path;
  try {
    if (!temporary) return res.status(400).json({ error: 'Selecciona un archivo .3105.' });
    await validatePatchFile(temporary);
    const stats = await fs.promises.stat(temporary);
    const id = crypto.randomUUID();
    const storageName = id + '.3105';
    const item = {
      id,
      name: cleanText(req.body.name, 120, path.basename(req.file.originalname, '.3105')),
      description: cleanText(req.body.description, 500),
      version: cleanText(req.body.version, 40, '1.0.0'),
      originalName: cleanText(req.file.originalname, 180, storageName),
      storageName,
      size: stats.size,
      sha256: await sha256File(temporary),
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString()
    };
    await enqueueMutation(async () => {
      const items = await readManifest();
      await fs.promises.copyFile(temporary, path.join(FILES_DIR, storageName));
      items.push(item);
      await writeManifest(items);
    });
    res.status(201).json({ patch: item });
  } catch (error) { next(error); }
  finally { if (temporary) await fs.promises.unlink(temporary).catch(() => {}); }
});

app.patch('/api/admin/patches/:id', requireSameOrigin, requireAdmin, async (req, res, next) => {
  try {
    const updated = await enqueueMutation(async () => {
      const items = await readManifest();
      const item = items.find((entry) => entry.id === req.params.id);
      if (!item) return null;
      item.name = cleanText(req.body.name, 120, item.name);
      item.description = cleanText(req.body.description, 500);
      item.version = cleanText(req.body.version, 40, item.version);
      item.updatedAt = new Date().toISOString();
      await writeManifest(items);
      return item;
    });
    if (!updated) return res.status(404).json({ error: 'Parche no encontrado.' });
    res.json({ patch: updated });
  } catch (error) { next(error); }
});

app.put('/api/admin/patches/:id/file', requireSameOrigin, requireAdmin, upload.single('file'), async (req, res, next) => {
  const temporary = req.file?.path;
  try {
    if (!temporary) return res.status(400).json({ error: 'Selecciona un archivo .3105.' });
    await validatePatchFile(temporary);
    const stats = await fs.promises.stat(temporary);
    const digest = await sha256File(temporary);
    const updated = await enqueueMutation(async () => {
      const items = await readManifest();
      const item = items.find((entry) => entry.id === req.params.id);
      if (!item) return null;
      await fs.promises.copyFile(temporary, path.join(FILES_DIR, item.storageName));
      item.originalName = cleanText(req.file.originalname, 180, item.originalName);
      item.size = stats.size;
      item.sha256 = digest;
      item.updatedAt = new Date().toISOString();
      await writeManifest(items);
      return item;
    });
    if (!updated) return res.status(404).json({ error: 'Parche no encontrado.' });
    res.json({ patch: updated });
  } catch (error) { next(error); }
  finally { if (temporary) await fs.promises.unlink(temporary).catch(() => {}); }
});

app.delete('/api/admin/patches/:id', requireSameOrigin, requireAdmin, async (req, res, next) => {
  try {
    const removed = await enqueueMutation(async () => {
      const items = await readManifest();
      const index = items.findIndex((entry) => entry.id === req.params.id);
      if (index < 0) return null;
      const [item] = items.splice(index, 1);
      await writeManifest(items);
      await fs.promises.unlink(path.join(FILES_DIR, item.storageName)).catch(() => {});
      return item;
    });
    if (!removed) return res.status(404).json({ error: 'Parche no encontrado.' });
    res.json({ deleted: true });
  } catch (error) { next(error); }
});

app.use((error, _req, res, _next) => {
  console.error(error);
  if (error instanceof multer.MulterError && error.code === 'LIMIT_FILE_SIZE') {
    return res.status(413).json({ error: 'El archivo supera el límite de 250 MB.' });
  }
  res.status(400).json({ error: cleanText(error.message, 180, 'Operación fallida.') });
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`INJECT IOS patch catalog listening on port ${PORT}`);
});

// Compa para Windows: proceso principal de Electron. Ventana transparente sin bordes
// por encima del escritorio, icono en la bandeja del sistema y su menú. Toda la vida
// de la mascota (sesiones, cerebro, dibujo) está en el renderer.
'use strict';

// ---- modo hook: `Compa.exe --hook <Evento>`, para quien no tenga Node instalado ----
const hookAt = process.argv.indexOf('--hook');
if (hookAt >= 0) {
  require('./hook.js').main(process.argv[hookAt + 1] || '');
  return;   // eslint-disable-line no-unreachable
}

const { app, BrowserWindow, Tray, Menu, ipcMain, screen, powerMonitor, nativeImage, shell } = require('electron');
const path = require('path');
const fs = require('fs');
const { execFileSync, spawn } = require('child_process');
const desktopWatch = require('./lib/desktop');
const hooks = require('./lib/hooks-setup');
const { home, userPets } = require('./lib/pets');

if (!app.requestSingleInstanceLock()) { app.quit(); return; }   // eslint-disable-line no-unreachable
app.setAppUserModelId('com.juli.compa');

let win = null, tray = null, menuState = null;
const kids = new Map();   // ventanitas de la bandada, por nombre

// ---- Claude Desktop: un PowerShell que mide su CPU una vez por segundo ----
let desktop = { running: false, cpu: 0, front: false, input: 99, rect: null, seq: 0 };
let watcher = null;
function startWatcher() {
  if (process.env.COMPA_FAKEDESKTOP) {
    // para probar sin Windows: Claude Desktop "responde" 14 s de cada 30
    let cpu = 0, t = 0;
    setInterval(() => { t++; const busy = t % 30 > 4 && t % 30 < 18; cpu += busy ? 0.8 : 0.02;
      desktop = { running: true, cpu, front: false, input: 99, rect: null, seq: desktop.seq + 1 }; }, 1000);
    return;
  }
  if (process.platform !== 'win32' || watcher) return;
  watcher = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                     '-EncodedCommand', desktopWatch.encoded()], { windowsHide: true });
  let buf = '';
  watcher.stdout.on('data', (chunk) => {
    buf += chunk.toString('utf8');
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      try { const d = JSON.parse(line); desktop = { ...d, seq: desktop.seq + 1 }; } catch { /* línea a medias */ }
    }
  });
  watcher.on('exit', () => { watcher = null; desktop = { ...desktop, running: false }; setTimeout(startWatcher, 10000); });
  watcher.on('error', () => { watcher = null; });
}
app.on('before-quit', () => { if (watcher) { watcher.removeAllListeners('exit'); watcher.kill(); } });

const resources = () => (app.isPackaged ? process.resourcesPath : __dirname);
const bundledPets = () => (app.isPackaged ? path.join(process.resourcesPath, 'pets') : path.join(__dirname, '..', 'pets'));
const bundledScenes = () => (app.isPackaged ? path.join(process.resourcesPath, 'scenes') : path.join(__dirname, '..', 'scenes'));

/** Copia el hook a ~/.compa y lo registra en settings.json. Con Node instalado lo
 *  llama Node (rápido); si no, la propia app con --hook. */
function installHooks() {
  try {
    fs.mkdirSync(home(), { recursive: true });
    const script = path.join(home(), 'hook.js');
    fs.copyFileSync(path.join(resources(), 'hook.js'), script);
    let hasNode = false;
    try { execFileSync(process.platform === 'win32' ? 'where' : 'which', ['node'], { stdio: 'ignore', windowsHide: true }); hasNode = true; }
    catch { /* sin Node */ }
    const mode = hasNode || !app.isPackaged ? { node: true, script } : { exe: process.execPath };
    const r = hooks.register(mode);
    return { ...r, mode: mode.node ? 'node' : 'exe' };
  } catch (e) { return { ok: false, error: String(e.message || e) }; }
}

function createWindow() {
  win = new BrowserWindow({
    width: 340, height: 360, x: 0, y: 0,
    frame: false, transparent: true, resizable: false, movable: false, hasShadow: false,
    skipTaskbar: true, focusable: false, alwaysOnTop: true, show: false,
    webPreferences: { nodeIntegration: true, contextIsolation: false, backgroundThrottling: false },
  });
  win.setAlwaysOnTop(true, 'screen-saver');
  win.setVisibleOnAllWorkspaces(true);
  win.setIgnoreMouseEvents(true, { forward: true });
  win.loadFile(path.join(__dirname, 'index.html'));
  // Modo "una mascota por sesión": el renderer abre sus ventanitas con window.open.
  // Comparten su proceso (dibuja en ellas directamente); aquí solo se les da forma.
  win.webContents.setWindowOpenHandler(() => ({ action: 'allow', overrideBrowserWindowOptions: {
    frame: false, transparent: true, resizable: false, movable: false, hasShadow: false, skipTaskbar: true,
    focusable: false, alwaysOnTop: true, show: true, backgroundColor: '#00000000',
    webPreferences: { backgroundThrottling: false },
  } }));
  win.webContents.on('did-create-window', (child, { frameName }) => {
    kids.set(frameName, child);
    child.setAlwaysOnTop(true, 'screen-saver');
    child.setVisibleOnAllWorkspaces(true);
    child.setIgnoreMouseEvents(true, { forward: true });
    child.on('closed', () => { if (kids.get(frameName) === child) kids.delete(frameName); });
  });
  win.once('ready-to-show', () => win.showInactive());
  // COMPA_DEBUG: el log del renderer a la consola. COMPA_QA=<carpeta>: guarda capturas
  // de la ventana cada 0,7 s y sale (para revisar animaciones sin mirar la pantalla).
  if (process.env.COMPA_DEBUG || process.env.COMPA_QA) {
    win.webContents.on('console-message', (_e, level, message) => console.log(`[renderer ${level}] ${message}`));
  }
  if (process.env.COMPA_QA_CMD) {
    // pruebas: "orden:argumento@segundos", como si se eligiera en el menú
    const [, cmd, arg, at] = process.env.COMPA_QA_CMD.match(/^(\w+):([^@]*)@([\d.]+)$/) || [];
    if (cmd) setTimeout(() => send(cmd, isNaN(+arg) ? arg : +arg), +at * 1000);
  }
  if (process.env.COMPA_QA) {
    let n = 0;
    const every = setInterval(async () => {
      const img = await win.webContents.capturePage();
      fs.writeFileSync(path.join(process.env.COMPA_QA, `q${String(n).padStart(3, '0')}.png`), img.toPNG());
      for (const [name, k] of kids) {
        try { fs.writeFileSync(path.join(process.env.COMPA_QA, `q${String(n).padStart(3, '0')}-${name}.png`), (await k.webContents.capturePage()).toPNG()); }
        catch { /* se cerró */ }
      }
      if (++n >= (Number(process.env.COMPA_QA_FRAMES) || 12)) { clearInterval(every); app.quit(); }
    }, 700);
  }
}

function send(cmd, arg) { if (win) win.webContents.send('cmd', cmd, arg); }

function buildMenu() {
  const s = menuState || { title: 'Compa', sessions: [], notices: 0, pets: [], flags: {}, size: 150 };
  const f = s.flags || {};
  const toggle = (label, key) => ({ label, type: 'checkbox', checked: !!f[key], click: () => send('toggle', key) });
  const items = [{ label: s.title, enabled: false }];
  // quitar a mano: ni lista ni mascota hasta que esa sesión vuelva a trabajar
  const hide = (x) => ({ label: 'Quitar esta sesión', toolTip: 'Vuelve sola cuando le escribas otra vez',
                         click: () => send('hide', x.key) });
  for (const x of s.sessions || []) {
    const seen = x.pending ? [{ label: 'Marcar como visto', click: () => send('seenSession', x.key) }] : [];
    if (!s.multi) { items.push({ label: x.label, submenu: [...seen, hide(x)] }); continue; }
    // con una mascota por sesión, cada sesión fija su mascota y su color
    const pin = (s.pins || {})[x.project] || {};
    items.push({ label: x.label, submenu: [
      ...seen, hide(x), { type: 'separator' },
      { label: `Mascota de «${x.project}»`, enabled: false },
      { label: 'Automática', type: 'radio', checked: !pin.pet, click: () => send('pin', { project: x.project, pet: null }) },
      ...(s.pets || []).map((p) => ({ label: p.name, type: 'radio', checked: pin.pet === p.id,
                                       click: () => send('pin', { project: x.project, pet: p.id }) })),
      { type: 'separator' }, { label: 'Color', enabled: false },
      { label: 'Automático', type: 'radio', checked: pin.color === undefined, click: () => send('pin', { project: x.project, color: null }) },
      ...(s.palette || []).map((c, i) => ({ label: c.name, type: 'radio', checked: pin.color === i,
                                             click: () => send('pin', { project: x.project, color: i }) })),
    ] });
  }
  if (s.hiddenCount) {
    items.push({ label: s.hiddenCount > 1 ? `Volver a mostrar las ${s.hiddenCount} sesiones quitadas` : 'Volver a mostrar la sesión quitada',
                 click: () => send('unhideAll') });
  }
  items.push({ type: 'separator' });
  if (s.notices) {
    items.push({ label: s.notices > 1 ? `Marcar los ${s.notices} avisos como vistos` : 'Marcar aviso como visto',
                 click: () => send('seen') });
  }
  items.push({ label: 'Saludar', click: () => send('wave') }, { label: 'Traer al centro', click: () => send('recenter') },
             { type: 'separator' });
  items.push({ label: 'Mascota', submenu: [
    ...(s.pets || []).map((p) => ({ label: p.name, type: 'radio', checked: p.id === s.petId,
                                     toolTip: p.origin, click: () => send('pet', p.id) })),
    { type: 'separator' },
    { label: 'Abrir carpeta de mascotas', click: () => { fs.mkdirSync(userPets(), { recursive: true }); shell.openPath(userPets()); } },
    { label: 'Buscar más mascotas (petdex)…', click: () => shell.openExternal('https://petdex.crafter.run') },
    { label: 'Volver a buscar mascotas', click: () => send('rescan') },
  ] });
  items.push(toggle('Una mascota por sesión', 'multi'));
  if (s.multi) {
    const radio = (label, key, value, cur) => ({ label, type: 'radio', checked: cur === value, click: () => send('set', { key, value }) });
    items.push({ label: 'Varias mascotas', submenu: [
      { label: 'Distinguir por', submenu: [radio('Mascota distinta', 'by', 'pet', s.by), radio('Color distinto', 'by', 'color', s.by),
                                          radio('Mezcla de ambas', 'by', 'mix', s.by)] },
      { label: 'Disposición', submenu: [radio('Escenario', 'layout', 'stage', s.layout), radio('Paseos cortos', 'layout', 'walks', s.layout),
                                       radio('Libres', 'layout', 'free', s.layout)] },
      { label: 'Escenario', submenu: (s.scenes || []).map((sc) => radio(sc.name, 'scene', sc.id, s.scene)) },
      { type: 'separator' },
      { label: 'Ocultar el escenario si no hay sesiones', type: 'checkbox', checked: !!s.hideEmptyStage,
        click: () => send('toggle', 'hideEmptyStage') },
      { label: 'Mascotas en rotación', submenu: (s.pets || []).map((p) => ({ label: p.name, type: 'checkbox',
          checked: !(s.rotation || []).length || s.rotation.includes(p.id), click: () => send('rotation', p.id) })) },
    ] });
  }
  items.push(toggle('Que camine sola', 'wanders'), toggle('Que siga el cursor', 'followsCursor'),
             toggle('Que reaccione a Claude', 'reactsToClaude'), toggle('Que avise con un globito', 'announces'));
  items.push({ label: 'Avisos', submenu: [toggle('Sonido', 'sound'), toggle('Notificaciones de Windows', 'banners')] });
  items.push({ type: 'separator' });
  items.push({ label: 'Tamaño', submenu: [['Pequeña', 100], ['Mediana', 150], ['Grande', 220]].map(([label, h]) => ({
    label, type: 'radio', checked: s.size === h, click: () => send('size', h) })) });
  items.push({ label: 'Abrir al iniciar sesión', type: 'checkbox', checked: app.getLoginItemSettings().openAtLogin,
               click: (it) => app.setLoginItemSettings({ openAtLogin: it.checked }) });
  items.push({ label: 'Reinstalar hooks de Claude Code', click: () => {
    const r = installHooks();
    send('hooks', r);
  } });
  items.push({ type: 'separator' }, { label: 'Salir', click: () => app.quit() });
  return Menu.buildFromTemplate(items);
}

app.whenReady().then(() => {
  const hookResult = installHooks();
  createWindow();
  startWatcher();
  tray = new Tray(nativeImage.createEmpty());
  tray.setToolTip('Compa');
  tray.setContextMenu(buildMenu());
  tray.on('click', () => tray.popUpContextMenu());

  ipcMain.on('env', (e, px, py) => {
    const p = { x: Math.round(px || 0), y: Math.round(py || 0) };
    const d = screen.getDisplayNearestPoint(p);
    e.returnValue = { cursor: screen.getCursorScreenPoint(), idle: powerMonitor.getSystemIdleTime(),
                      work: d.workArea, scale: d.scaleFactor, desktop };
  });
  ipcMain.on('paths', (e) => { e.returnValue = { bundledPets: bundledPets(), bundledScenes: bundledScenes(), hooks: hookResult }; });
  ipcMain.on('move', (_e, x, y) => { if (win) win.setPosition(Math.round(x), Math.round(y)); });
  ipcMain.on('size', (_e, w, h) => { if (win) win.setBounds({ width: Math.round(w), height: Math.round(h) }); });
  ipcMain.on('solid', (_e, solid) => { if (win) win.setIgnoreMouseEvents(!solid, { forward: true }); });
  ipcMain.on('wmove', (_e, name, x, y) => { const k = kids.get(name); if (k) k.setPosition(Math.round(x), Math.round(y)); });
  ipcMain.on('wsize', (_e, name, w, h) => { const k = kids.get(name); if (k) k.setBounds({ width: Math.round(w), height: Math.round(h) }); });
  ipcMain.on('wsolid', (_e, name, s) => { const k = kids.get(name); if (k) k.setIgnoreMouseEvents(!s, { forward: true }); });
  ipcMain.on('wvis', (_e, name, v) => { const k = kids.get(name); if (k) { if (v) k.showInactive(); else k.hide(); } });
  ipcMain.on('tray', (_e, dataUrl, tip) => {
    if (!tray) return;
    if (dataUrl) tray.setImage(nativeImage.createFromDataURL(dataUrl));
    if (tip) tray.setToolTip(tip);
  });
  ipcMain.on('menu-state', (_e, state) => { menuState = state; if (tray) tray.setContextMenu(buildMenu()); });
  ipcMain.on('popup', () => buildMenu().popup());
});

app.on('second-instance', () => send('wave'));
app.on('window-all-closed', () => app.quit());

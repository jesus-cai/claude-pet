// Decide qué hace la mascota y qué dice el globito, 60 veces por segundo.
// Port de Brain.swift para mascotas de tipo atlas (no hay rig por capas en Windows).
//
// Dos vías: el NIVEL (qué hace Claude ahora) mueve la animación y la frase de
// trabajo; los EVENTOS (terminó, te necesita) crean avisos que se quedan hasta que
// los ves. Coordenadas de pantalla con y hacia abajo, como en Windows.
'use strict';
const { isWorking } = require('./probe');

const START = ['thinking…', 'here we go…', 'on it…', 'let me see…'];
const DONE = ['done!', 'all yours ✨', "it's ready!", 'go read it!', 'finished!', "that's it!"];
const GUESSED = 12;
const FAILED_TIME = 2.2;
const NOTICE_LIFE = 45;
const GRACE = 2;

const pickOne = (a) => a[Math.floor(Math.random() * a.length)];
const rnd = (a, b) => a + (b - a) * Math.random();

function waitingLine(d) {
  switch (d) {
    case 'question': return 'has a question!';
    case 'plan': return 'plan needs your ok!';
    case 'plan first': return 'wants to plan first, ok?';
    case 'permission': return 'needs your ok!';
    case 'input': return 'needs your input!';
  }
  for (const v of ['run ', 'use ', 'edit ', 'read ', 'fetch ', 'search ', 'send a helper']) {
    if (d.startsWith(v)) return `ok to ${d}?`;
  }
  const low = d.toLowerCase();
  if (/permission|permiso|approv/.test(low)) return 'needs your ok!';
  if (/waiting|input/.test(low)) return 'your turn!';
  return d || 'needs you!';
}

function lineFor(s, detail, opener) {
  const d = detail.trim();
  switch (s) {
    case 'thinking': return d || opener;
    case 'reading': return d ? `reading ${d}` : 'reading…';
    case 'writing': return d ? `writing ${d}` : 'writing…';
    case 'running': return d ? `running ${d}` : 'running…';
    case 'searching': return d ? `searching ${d}` : 'searching…';
    case 'delegating': return d ? `helper: ${d}` : 'sending a helper…';
    case 'waiting': return waitingLine(d);
    default: return '';
  }
}

const CLIP_NAMES = { idle: 'idle', 'running-right': 'runRight', 'running-left': 'runLeft', waving: 'waving',
                     jumping: 'jumping', failed: 'failed', waiting: 'waiting', running: 'working',
                     review: 'review', talking: 'talking' };
const MOMENTS = { done: 'celebrating', drag: 'dragged', wave: 'waving', error: 'failed', work: 'working' };

class Brain {
  constructor(probe, startX) {
    this.claude = probe;
    this.wanders = true; this.followsCursor = true; this.reactsToClaude = true; this.announces = true;
    this.speak = null;   // (text, tone, tag) => void
    this.hush = null;
    this.alert = null;   // (event) => void
    this.hasLook = false; this.hasTalk = false; this.walkSpeed = 80;
    this.bounds = [0, 1200];
    this.x = startX; this.facing = 1;
    this.activity = 'idle';
    this.t = 0; this.stateStarted = 0; this.nextDecision = 4; this.walkTarget = startX;
    this.clip = 'idle'; this.clipStarted = 0; this.look = null;
    this.notices = new Map(); this.noticeCount = 0;
    this.flash = null; this.flashUntil = 0;
    this.lastState = null; this.watching = false; this.stretchSignalled = false;
    this.busyStarted = 0; this.workLine = ''; this.lastLine = ''; this.lastTone = ''; this.lastTag = '';
    this.opener = START[0]; this.sawTool = false; this.stateChangedAt = 0;
    this.nextNag = 0; this.waitingSince = 0; this.wasAway = false; this.talkUntil = 0;
    this.polled = -10;
    this.reactionClips = {}; this.lines = {};
    // Modo "una mascota por sesión": puestos (x) a los que va según lo que hace -
    // { work, wait, rest, window } en el escenario - y paseos dirigidos (entrar,
    // salir). Sin puestos, como siempre.
    this.spots = null; this.commuting = false; this.forced = false; this.arrive = null;
  }

  /** Va andando hasta x y luego llama a `then`. Puede salirse de sus límites (entrar
   *  desde fuera, irse por la puerta). */
  walkTo(x, then = null) {
    this.forced = false; this.enter('walking');
    this.walkTarget = x; this.forced = true; this.arrive = then;
    this.facing = x > this.x ? 1 : -1;
  }

  setPersonality(reactions = {}, lines = {}) {
    this.reactionClips = {};
    for (const [k, v] of Object.entries(reactions || {})) {
      if (MOMENTS[k] && CLIP_NAMES[v]) this.reactionClips[MOMENTS[k]] = CLIP_NAMES[v];
    }
    this.lines = {};
    for (const [k, v] of Object.entries(lines || {})) if (Array.isArray(v) && v.length) this.lines[k] = v;
  }
  say(key, fallback) { return pickOne(this.lines[key] || fallback); }

  get notice() {
    let best = null;
    for (const n of this.notices.values()) if (!best || n.order > best.order) best = n;
    return best;
  }
  post(n) { n.order = ++this.noticeCount; n.seenFor = 0; this.notices.set(n.session, n); }
  get busyElsewhere() { return isWorking(this.claude.state) || this.claude.state === 'waiting'; }

  enter(a) {
    // un paseo dirigido (entrar, irse) no lo interrumpe nada salvo el ratón
    if (this.forced && this.activity === 'walking' && a !== 'dragged') return;
    if (a === 'dragged') { this.forced = false; this.arrive = null; }
    if (this.activity !== a) { this.activity = a; this.stateStarted = this.t; }
  }
  wave() { this.enter('waving'); }
  acknowledge() { this.notices.clear(); if (this.claude.state === 'waiting') this.nextNag = this.t + 90; }
  acknowledgeSession(key) { this.notices.delete(key); }
  beginDrag() { this.enter('dragged'); }
  endDrag(x) { this.x = x; this.enter('idle'); this.nextDecision = this.t + 2.5; }

  /** Un paso. cursor y head en coordenadas de pantalla (y hacia abajo). */
  step(dt, cursor, head, userIdle) {
    this.t += dt;
    const t = this.t;
    if (t - this.polled > 0.2) { this.claude.poll(); this.polled = t; }
    this.react(userIdle);
    for (const e of this.claude.takeEvents()) this.handle(e);
    this.tendNotices(dt, userIdle);

    switch (this.activity) {
      case 'turning': if (t - this.stateStarted > 0.5) { this.enter('idle'); this.nextDecision = t + rnd(3, 8); } break;
      case 'waving': if (t - this.stateStarted > 1.7) { this.enter('idle'); this.nextDecision = t + rnd(3, 7); } break;
      case 'working': if (!this.claude.isBusy && t - this.stateStarted > 1.5) { this.enter('idle'); this.nextDecision = t + rnd(2, 5); } break;
      case 'celebrating':
        if (t - this.stateStarted > 2.2) { this.enter(this.watching && this.claude.isBusy ? 'working' : 'idle'); this.nextDecision = t + rnd(2, 5); }
        break;
      case 'failed':
        if (t - this.stateStarted > FAILED_TIME) { this.enter(this.watching && this.claude.isBusy ? 'working' : 'idle'); this.nextDecision = t + rnd(2, 5); }
        break;
      case 'idle': case 'sleeping':
        if (userIdle > 240 && !this.claude.isBusy && this.claude.state !== 'waiting') this.enter('sleeping');
        else if (this.activity === 'sleeping') { this.enter('idle'); this.nextDecision = t + rnd(2, 6); }
        break;
    }

    if (userIdle > 30) this.wasAway = true;
    else if (this.wasAway && userIdle < 1) {
      this.wasAway = false;
      if (this.reactsToClaude && (this.notices.size || this.claude.state === 'waiting')
          && (this.activity === 'idle' || this.activity === 'sleeping')) this.enter('waving');
    }

    if (this.activity === 'idle' && t > this.nextDecision) {
      if (this.wanders && Math.random() < 0.5) {
        this.walkTarget = this.spots && this.spots.window !== undefined && Math.random() < 0.3
          ? this.spots.window + rnd(-12, 12)          // a asomarse a la ventana
          : rnd(this.bounds[0], this.bounds[1]);
        if (Math.abs(this.walkTarget - this.x) > 60) this.enter('walking'); else this.nextDecision = t + rnd(4, 9);
      } else if (Math.random() < 0.5) { this.enter('turning'); }
      else this.nextDecision = t + rnd(4, 9);
    }
    if (this.activity === 'walking') {
      const dir = this.walkTarget > this.x ? 1 : -1;
      this.facing = dir;
      this.x += dir * this.walkSpeed * dt;
      const arrived = Math.abs(this.walkTarget - this.x) < (this.forced ? 2 : 8);
      const out = !this.forced && (this.x < this.bounds[0] || this.x > this.bounds[1]);
      if (arrived || out) {
        const forced = this.forced;
        this.forced = false;
        if (forced) this.x = this.walkTarget;
        else this.x = Math.min(Math.max(this.x, this.bounds[0]), this.bounds[1]);
        this.enter('idle'); this.nextDecision = t + rnd(4, 10);
        if (this.arrive) { const f = this.arrive; this.arrive = null; f(); }
      }
    }
    // a su puesto: la mesa si trabaja, un paso al frente si te espera, el sofá si duerme
    this.commuting = false;
    if (this.spots && this.activity !== 'walking' && this.activity !== 'dragged') {
      const st = this.claude.state;
      let spot;
      if (this.activity === 'working') spot = this.spots.work;
      else if (this.activity === 'sleeping') spot = this.spots.rest;
      else if (this.reactsToClaude && st === 'waiting' && (this.activity === 'idle' || this.activity === 'waving')) spot = this.spots.wait;
      if (spot !== undefined && spot !== null && Math.abs(spot - this.x) > 0.5) {
        const dir = spot > this.x ? 1 : -1;
        this.facing = dir;
        this.x += dir * Math.min(Math.abs(spot - this.x), this.walkSpeed * dt);
        this.commuting = true;
      }
    }
    if (this.activity !== 'dragged' && !this.forced && !this.commuting) {
      this.x = Math.min(Math.max(this.x, this.bounds[0]), this.bounds[1]);
    }

    // 16 direcciones, en sentido horario desde arriba, con zona muerta e histéresis
    let look = null;
    if (this.hasLook && this.followsCursor && this.activity === 'idle' && this.currentClip() === 'idle') {
      const vx = cursor.x - head.x, vy = head.y - cursor.y;
      if (Math.hypot(vx, vy) > (this.look === null ? 120 : 90)) {
        let deg = Math.atan2(vx, vy) * 180 / Math.PI;
        if (deg < 0) deg += 360;
        look = Math.round(deg / 22.5) % 16;
      }
    }
    this.look = look;

    const c = this.currentClip();
    if (c !== this.clip) { this.clip = c; this.clipStarted = t; }
    this.updateBalloon();
    return { clip: this.clip, clipAge: t - this.clipStarted, look: this.look, sleeping: this.activity === 'sleeping' };
  }

  currentClip() {
    const a = this.activity, st = this.claude.state;
    if (this.commuting) return this.facing > 0 ? 'runRight' : 'runLeft';
    if (this.hasTalk && this.t < this.talkUntil && (a === 'idle' || a === 'turning')) return 'talking';
    if (a !== 'walking' && this.reactionClips[a]) return this.reactionClips[a];
    switch (a) {
      case 'walking': return this.facing > 0 ? 'runRight' : 'runLeft';
      case 'waving': return 'waving';
      case 'celebrating': case 'dragged': return 'jumping';
      case 'failed': return 'failed';
      case 'working': return st === 'reading' || st === 'searching' ? 'review' : 'working';
      default: return this.reactsToClaude && st === 'waiting' ? 'waiting' : 'idle';
    }
  }

  react(userIdle) {
    const t = this.t, c = this.claude, st = c.state;
    if (this.watching && c.isSignalled) this.stretchSignalled = true;
    const previous = this.lastState;
    this.lastState = st;
    if (previous === null) return;
    if (st !== previous) this.stateChangedAt = t;
    if (isWorking(st) && st !== 'thinking') this.sawTool = true;
    const allowed = this.reactsToClaude && this.activity !== 'dragged';
    if (this.watching && !this.reactsToClaude) this.land(false);

    if (isWorking(st)) {
      if (!this.watching && allowed) {
        this.busyStarted = t; this.watching = true; this.stretchSignalled = c.isSignalled;
        this.sawTool = st !== 'thinking'; this.opener = this.say('start', START);
        this.enter('working');
      } else if (st !== previous && this.watching && allowed && this.activity !== 'celebrating' && this.activity !== 'failed') {
        this.enter('working');
      }
      // de vuelta al trabajo tras cualquier interrupción (arrastre, clic) con la misma tarea
      if (this.watching && allowed && this.activity === 'idle') this.enter('working');
    } else if (st === 'waiting') {
      if (allowed && (!this.watching || st !== previous)) {
        this.watching = true; this.enter('waving'); this.nextNag = t + 5; this.waitingSince = t;
      }
    } else if (st !== previous) {
      if (st === 'done' || st === 'stopped' || st === 'error') this.land(false);
      else this.land(this.watching && allowed && !c.isSignalled && !this.stretchSignalled
                     && previous !== 'waiting' && t - this.busyStarted > GUESSED, true);
    }

    if (st === 'waiting' && this.watching && allowed && t > this.nextNag
        && (this.activity === 'idle' || this.activity === 'waving')) {
      const early = t - this.waitingSince < 20;
      if (early || userIdle < 10) { this.nextNag = t + (early ? 5 : 40); this.enter('waving'); }
    }

    if (!this.watching) { this.workLine = ''; return; }
    const bare = st === 'thinking' && !c.detail.trim();
    if (bare && this.sawTool && this.workLine && t - this.stateChangedAt < GRACE) return;
    const starter = c.isSignalled && !this.sawTool ? this.opener : 'thinking…';
    this.workLine = lineFor(st, c.detail, starter);
  }

  handle(e) {
    if (e.kind === 'engaged' || e.kind === 'gone') { this.notices.delete(e.session); return; }
    if (!this.reactsToClaude) return;
    if (e.kind === 'needsYou') { if (!e.quiet && this.alert) this.alert(e); return; }
    const error = e.kind === 'failed';
    const d = (e.detail || '').trim();
    const n = { kind: error ? 'error' : 'done', session: e.session, project: e.project,
                text: error ? (d && d !== 'api' ? d : this.say('error', ['something went wrong']))
                            : this.say('done', DONE) };
    this.post(n);
    if (this.busyElsewhere) {
      // otra sesión sigue: se dice encima del trabajo, sin pararlo
      if (!e.quiet) { this.flash = { text: n.text, tone: n.kind, tag: n.project }; this.flashUntil = this.t + (error ? 4 : 3.5); }
    } else {
      // la última: el resumen con todas manda sobre un aviso suelto de hace un momento
      this.flash = null;
      if (this.activity !== 'dragged' && !e.quiet) this.enter(error ? 'failed' : 'celebrating');
    }
    if (!e.quiet && this.alert) this.alert(e);
  }

  tendNotices(dt, userIdle) {
    if (!this.notices.size) return;
    if (!this.reactsToClaude) { this.notices.clear(); return; }
    if (userIdle >= 5) return;
    for (const [k, n] of this.notices) { n.seenFor += dt; if (n.seenFor > NOTICE_LIFE) this.notices.delete(k); }
  }

  land(celebrating, guessed = false) {
    if (celebrating) {
      this.enter('celebrating');
      if (guessed) {
        // Claude Desktop no tiene hooks: lo adivinado tiene el mismo aviso fijo
        const e = { kind: 'finished', session: 'desktop', project: 'Claude Desktop', detail: '', quiet: false };
        this.post({ kind: 'done', session: e.session, project: e.project, text: this.say('done', DONE) });
        if (this.alert) this.alert(e);
      }
    }
    this.watching = false;
    this.workLine = '';
  }

  static projectList(notices) {
    const seen = new Set();
    const names = [...notices.values()].sort((a, b) => b.order - a.order).map((n) => n.project)
      .filter((p) => p && !seen.has(p) && seen.add(p));
    return names.length <= 3 ? names.join(', ') : `${names.slice(0, 2).join(', ')} +${names.length - 2}`;
  }

  updateBalloon() {
    const c = this.claude;
    // una mascota de UNA sesión lleva el proyecto en su etiqueta: el globito no lo repite
    const single = !!c.key;
    const tagged = (t) => (single ? '' : t);
    let want = null;
    if (this.announces && this.reactsToClaude) {
      const live = c.sessions.filter((s) => isWorking(s.state) || s.state === 'waiting');
      if (c.state === 'waiting' && this.watching && this.workLine) {
        const others = c.sessions.filter((s) => s.state === 'waiting').length - 1;
        want = { text: this.workLine, tone: 'waiting', tag: tagged(c.project + (others > 0 ? ` +${others}` : '')) };
      } else if (this.flash && this.t < this.flashUntil) {
        want = { ...this.flash, tag: tagged(this.flash.tag) };
      } else if (this.watching && this.workLine && c.state !== 'waiting') {
        want = { text: this.workLine, tone: 'working', tag: live.length > 1 ? c.project : '' };
      } else if (this.notices.size) {
        const tone = [...this.notices.values()].some((n) => n.kind === 'error') ? 'error' : 'done';
        want = { text: this.notice.text, tone, tag: tagged(Brain.projectList(this.notices)) };
      }
    }
    if (!want) { if (this.lastLine) { this.lastLine = ''; this.hush && this.hush(); } return; }
    if (want.text !== this.lastLine || want.tone !== this.lastTone || want.tag !== this.lastTag) {
      this.lastLine = want.text; this.lastTone = want.tone; this.lastTag = want.tag;
      this.speak && this.speak(want.text, want.tone, want.tag);
      this.talkUntil = this.t + Math.min(2.6, Math.max(0.8, want.text.length * 0.07));
    }
  }
}

module.exports = { Brain, lineFor, waitingLine };

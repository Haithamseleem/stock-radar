// Radar3D: Stock Radar's 3D radar table, drawn on a 2D canvas (no library, about 8 KB).
// Each item is a pillar standing on a tilted radar disc, as tall as its value. A sweep circles the disc, and each
// pillar pulses as the sweep passes. Labels are real links over the canvas, so they stay sharp, focusable and
// clickable; the canvas itself is decoration.
//   const radar = Radar3D(hostElement, { caption: 'text under the table' });
//   radar.setItems([{ id, label, logo, value, valueText, href, external, highlight }]);
// The animation pauses off-screen and in background tabs, and stops once the host leaves the page. For people
// who prefer reduced motion it is a still picture. Drag sideways to turn the table.
(function () {
  'use strict';
  const CSS = `
.r3d { position:relative; width:100%; min-height:260px; overflow:hidden; touch-action:pan-y; user-select:none; }
.r3d canvas { position:absolute; inset:0; width:100%; height:100%; display:block; cursor:grab; }
.r3d.drag canvas { cursor:grabbing; }
.r3d-tag { position:absolute; left:0; top:0; display:inline-flex; align-items:center; gap:6px; max-width:200px; padding:3px 10px 3px 3px;
  border-radius:999px; background:#fff; border:1px solid var(--line, #dfe5eb); box-shadow:0 2px 8px rgba(22,45,61,.12);
  color:var(--text, #162d3d); font-family:inherit; font-size:12px; font-weight:600; line-height:1.2; white-space:nowrap; text-decoration:none;
  transition:border-color .15s, box-shadow .15s; will-change:transform; }
.r3d-tag img, .r3d-tag .ph { width:22px; height:22px; border-radius:50%; object-fit:contain; background:#fff; flex:none; }
.r3d-tag .ph { display:grid; place-items:center; font-size:10px; font-weight:700; background:var(--gray, #eef1f4); color:var(--muted, #5f6b78); }
.r3d-tag .nm { overflow:hidden; text-overflow:ellipsis; }
.r3d-tag .v { color:var(--muted, #5f6b78); }
.r3d-tag.hi { border-color:#25a55a; } .r3d-tag.hi .v { color:var(--ok, #157a3e); }
.r3d-tag:hover, .r3d-tag:focus-visible, .r3d-tag.on { border-color:var(--primary, #0f62e6); box-shadow:0 4px 14px rgba(15,98,230,.28); outline:none; z-index:3; }
.r3d-cap { position:absolute; left:16px; right:16px; bottom:10px; font-size:12px; color:var(--muted, #5f6b78); pointer-events:none; }
.r3d-tag.quiet { opacity:0; pointer-events:none; } .r3d-tag.quiet:focus-visible { opacity:1; pointer-events:auto; }
@media (max-width:640px) { .r3d-tag { font-size:11px; max-width:150px; } .r3d-tag .v { display:none; } .r3d-tag.on .v, .r3d-tag:focus-visible .v { display:inline; } }
`;
  const TAU = Math.PI * 2;
  const reduce = () => window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;

  window.Radar3D = function (host, opts) {
    opts = opts || {};
    if (!document.getElementById('radar3d-css')) { const s = document.createElement('style'); s.id = 'radar3d-css'; s.textContent = CSS; document.head.append(s); }
    host.classList.add('r3d');
    const cv = document.createElement('canvas'); cv.setAttribute('aria-hidden', 'true');
    const tagsBox = document.createElement('div');
    host.replaceChildren(cv, tagsBox);
    if (opts.caption) { const c = document.createElement('div'); c.className = 'r3d-cap'; c.textContent = opts.caption; host.append(c); }
    const ctx = cv.getContext('2d');

    // Camera: looking down at the disc from 31 degrees; the disc has radius 1 in its own x/z plane, y is up.
    const EL = 0.54, DIST = 3.4, HMAX = 0.72;
    let w = 0, h = 0, dpr = 1, f = 1, cx = 0, cy = 0;
    let az = 0.35, sweep = 0, last = 0, visible = true, running = false, active = -1, drag = null, idle = 0;
    let items = [];

    const sinE = Math.sin(EL), cosE = Math.cos(EL);
    function project(x, y, z) {
      const ca = Math.cos(az), sa = Math.sin(az);
      const xr = x * ca - z * sa, zr = x * sa + z * ca;
      const depth = DIST - y * sinE - zr * cosE, yc = y * cosE - zr * sinE;
      return { x: cx + f * xr / depth, y: cy - f * yc / depth, d: depth };
    }

    function resize() {
      const r = host.getBoundingClientRect();
      w = Math.max(1, r.width); h = Math.max(1, r.height); dpr = Math.min(2, window.devicePixelRatio || 1);
      cv.width = Math.round(w * dpr); cv.height = Math.round(h * dpr);
      // The disc fills most of the width, with room above it for the pillars and their labels.
      f = Math.min(w * 0.42, h * 0.62) * DIST * 1.02; cx = w / 2; cy = h * (opts.caption ? 0.6 : 0.62);
      frame(0);
    }

    function ringPath(r, a0, a1, steps) {
      const pts = [];
      for (let i = 0; i <= steps; i++) { const a = a0 + (a1 - a0) * i / steps; pts.push(project(r * Math.cos(a), 0, r * Math.sin(a))); }
      return pts;
    }
    function poly(pts, close) { ctx.beginPath(); pts.forEach((p, i) => i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)); if (close) ctx.closePath(); }

    function drawDisc() {
      const o = project(0, 0, 0), edge = ringPath(1, 0, TAU, 72);
      const g = ctx.createRadialGradient(o.x, o.y, 0, o.x, o.y, f / DIST);
      g.addColorStop(0, 'rgba(15,98,230,0.13)'); g.addColorStop(0.75, 'rgba(15,98,230,0.05)'); g.addColorStop(1, 'rgba(15,98,230,0.02)');
      poly(edge, true); ctx.fillStyle = g; ctx.fill();
      ctx.lineWidth = 1.5; ctx.strokeStyle = 'rgba(15,98,230,0.38)'; ctx.stroke();
      ctx.lineWidth = 1; ctx.strokeStyle = 'rgba(15,98,230,0.16)';
      [0.25, 0.5, 0.75].forEach(r => { poly(ringPath(r, 0, TAU, 56), true); ctx.stroke(); });
      for (let k = 0; k < 4; k++) { const a = k * Math.PI / 4, p = project(Math.cos(a), 0, Math.sin(a)), q = project(-Math.cos(a), 0, -Math.sin(a)); ctx.beginPath(); ctx.moveTo(p.x, p.y); ctx.lineTo(q.x, q.y); ctx.stroke(); }
    }

    function drawSweep() {
      const o = project(0, 0, 0), trail = 1.15, n = 26;
      for (let k = 0; k < n; k++) {
        const a0 = sweep - trail * (1 - k / n), a1 = sweep - trail * (1 - (k + 1) / n);
        const pts = [o].concat(ringPath(1, a0, a1, 3));
        poly(pts, true); ctx.fillStyle = `rgba(37,165,90,${(0.32 * Math.pow((k + 1) / n, 1.8)).toFixed(3)})`; ctx.fill();
      }
      const e = project(Math.cos(sweep), 0, Math.sin(sweep));
      ctx.beginPath(); ctx.moveTo(o.x, o.y); ctx.lineTo(e.x, e.y); ctx.lineWidth = 2; ctx.strokeStyle = 'rgba(37,165,90,0.75)'; ctx.stroke();
    }

    function shade(hex, k) {
      const n = parseInt(hex.slice(1), 16), r = n >> 16, g = (n >> 8) & 255, b = n & 255;
      const m = (c) => Math.round(k >= 0 ? c + (255 - c) * k : c * (1 + k));
      return `rgb(${m(r)},${m(g)},${m(b)})`;
    }

    function drawPillar(it, i) {
      const R = 0.058, base = project(it.x, 0, it.z), top = project(it.x, it.h, it.z);
      const rx = f * R / base.d, ry = rx * sinE, rxt = f * R / top.d, ryt = rxt * sinE;
      const col = it.highlight ? '#25a55a' : '#0f62e6', on = i === active;
      // Soft shadow and the pulse ring where the pillar stands.
      ctx.beginPath(); ctx.ellipse(base.x, base.y, rx * 2.2, ry * 2.2, 0, 0, TAU); ctx.fillStyle = 'rgba(22,45,61,0.10)'; ctx.fill();
      if (it.pulse > 0.02) {
        const s = 1 + (1 - it.pulse) * 3.2;
        ctx.beginPath(); ctx.ellipse(base.x, base.y, rx * 2 * s, ry * 2 * s, 0, 0, TAU);
        ctx.lineWidth = 2; ctx.strokeStyle = it.highlight ? `rgba(37,165,90,${(it.pulse * 0.8).toFixed(3)})` : `rgba(15,98,230,${(it.pulse * 0.7).toFixed(3)})`; ctx.stroke();
      }
      // The column: a shaded side, then the lit top.
      const g = ctx.createLinearGradient(base.x - rx, 0, base.x + rx, 0);
      const lift = on ? 0.18 : it.pulse * 0.25;
      g.addColorStop(0, shade(col, -0.25 + lift)); g.addColorStop(0.45, shade(col, 0.18 + lift)); g.addColorStop(1, shade(col, -0.35 + lift));
      ctx.beginPath();
      ctx.moveTo(base.x - rx, base.y); ctx.lineTo(top.x - rxt, top.y);
      ctx.ellipse(top.x, top.y, rxt, ryt, 0, Math.PI, 0, true);
      ctx.lineTo(base.x + rx, base.y);
      ctx.ellipse(base.x, base.y, rx, ry, 0, 0, Math.PI, false);
      ctx.closePath(); ctx.fillStyle = g; ctx.fill();
      ctx.beginPath(); ctx.ellipse(top.x, top.y, rxt, ryt, 0, 0, TAU); ctx.fillStyle = shade(col, 0.45 + lift * 0.5); ctx.fill();
      if (on) { ctx.lineWidth = 2; ctx.strokeStyle = shade(col, -0.4); ctx.stroke(); }
      return top;
    }

    // Labels go above their pillar; a label that would overlap one nearer the viewer moves up until it is clear.
    function placeTags(tops) {
      const order = tops.map((t, i) => i).sort((a, b) => tops[a].d - tops[b].d), boxes = [];
      // On narrow screens only the 5 biggest values (and the one in focus) keep a visible label.
      const keep = new Set(w < 560 ? items.map((it, i) => i).sort((a, b) => (+items[b].value || 0) - (+items[a].value || 0)).slice(0, 5) : items.map((it, i) => i));
      order.forEach(i => {
        const el = items[i].el; if (!el) return;
        const quiet = !keep.has(i) && i !== active; el.classList.toggle('quiet', quiet);
        if (quiet) { el.style.transform = `translate(${tops[i].x.toFixed(1)}px, ${(tops[i].y - 30).toFixed(1)}px)`; return; }
        const bw = el.offsetWidth || 90, bh = el.offsetHeight || 26;
        let x = Math.max(bw / 2 + 4, Math.min(w - bw / 2 - 4, tops[i].x)), y = tops[i].y - 10;
        for (let k = 0; k < 6; k++) {
          const hit = boxes.find(b => Math.abs(b.x - x) < (b.w + bw) / 2 + 4 && Math.abs(b.y - y) < (b.h + bh) / 2 + 2);
          if (!hit) break; y = hit.y - (hit.h + bh) / 2 - 3;
        }
        y = Math.max(bh + 2, y);
        boxes.push({ x, y, w: bw, h: bh });
        // A label pushed away from its pillar gets a thin line back to it.
        if (y < tops[i].y - 18 || Math.abs(x - tops[i].x) > 8) { ctx.beginPath(); ctx.moveTo(tops[i].x, tops[i].y - 2); ctx.lineTo(x, y); ctx.lineWidth = 1; ctx.strokeStyle = 'rgba(22,45,61,0.28)'; ctx.stroke(); }
        el.style.transform = `translate(${(x - bw / 2).toFixed(1)}px, ${(y - bh).toFixed(1)}px)`;
      });
    }

    function frame(now) {
      const dt = last ? Math.min(0.05, (now - last) / 1000) : 0; last = now;
      const still = reduce();
      if (!still && !drag) { sweep = (sweep + dt * 1.25) % TAU; idle += dt; if (active < 0 && idle > 1.5) az += dt * 0.06; }
      items.forEach(it => {
        const da = Math.abs(((sweep - it.a) % TAU + TAU + Math.PI) % TAU - Math.PI);
        if (!still && da < 0.07 && it.pulse < 0.3) it.pulse = 1;
        it.pulse = still ? 0 : it.pulse * Math.exp(-dt * 1.8);
      });
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.clearRect(0, 0, w, h);
      drawDisc(); drawSweep();
      // Far pillars first, so near ones cover them.
      const tops = new Array(items.length);
      items.map((it, i) => ({ i, d: project(it.x, 0, it.z).d })).sort((a, b) => b.d - a.d).forEach(o => { tops[o.i] = drawPillar(items[o.i], o.i); });
      placeTags(tops);
    }

    function loop(now) {
      if (!host.isConnected) { running = false; io && io.disconnect(); ro && ro.disconnect(); return; }
      if (visible && !document.hidden) frame(now); else last = 0;
      if (reduce()) { running = false; return; }
      requestAnimationFrame(loop);
    }
    function start() { if (!running) { running = true; last = 0; requestAnimationFrame(loop); } }

    // Turning the table by dragging sideways (vertical drags still scroll the page on phones).
    cv.addEventListener('pointerdown', (e) => { drag = { x: e.clientX, y: e.clientY, az, moved: false }; host.classList.add('drag'); cv.setPointerCapture(e.pointerId); });
    cv.addEventListener('pointermove', (e) => { if (!drag) return; if (Math.abs(e.clientX - drag.x) > 5) drag.moved = true; az = drag.az + (e.clientX - drag.x) / Math.max(200, w) * Math.PI; idle = 0; if (reduce()) frame(performance.now()); });
    const end = () => { drag = null; host.classList.remove('drag'); };
    // A tap (not a drag) on a pillar opens it, like its label.
    cv.addEventListener('pointerup', (e) => {
      const tap = drag && !drag.moved; end(); if (!tap) return;
      const r = cv.getBoundingClientRect(), px = e.clientX - r.left, py = e.clientY - r.top;
      let best = null, bd = 22;
      items.forEach(it => {
        const b = project(it.x, 0, it.z), t = project(it.x, it.h, it.z), dx = t.x - b.x, dy = t.y - b.y, l = dx * dx + dy * dy || 1;
        const k = Math.max(0, Math.min(1, ((px - b.x) * dx + (py - b.y) * dy) / l)), d = Math.hypot(px - b.x - k * dx, py - b.y - k * dy);
        if (d < bd) { bd = d; best = it; }
      });
      if (best && best.el && best.href) best.el.click();
    });
    cv.addEventListener('pointercancel', end);

    const io = 'IntersectionObserver' in window ? new IntersectionObserver(es => { visible = es[0].isIntersecting; if (visible) start(); }) : null;
    if (io) io.observe(host);
    const ro = 'ResizeObserver' in window ? new ResizeObserver(resize) : null;
    if (ro) ro.observe(host); else window.addEventListener('resize', resize);
    document.addEventListener('visibilitychange', () => { if (!document.hidden) start(); });

    function setItems(list) {
      const n = list.length, max = Math.max(0, ...list.map(x => +x.value || 0));
      const old = {}; items.forEach(it => { old[it.id] = it; });
      tagsBox.replaceChildren();
      items = list.map((x, i) => {
        // Evenly around the disc; with many items, alternate two rings so neighbours don't touch.
        const a = -Math.PI / 2 + i * TAU / Math.max(1, n), r = n > 6 ? (i % 2 ? 0.5 : 0.82) : 0.66;
        const it = Object.assign({}, x, { a, x: r * Math.cos(a), z: r * Math.sin(a), h: 0.03 + (HMAX - 0.03) * (max > 0 ? (+x.value || 0) / max : 0), pulse: 0 });
        if (old[x.id]) it.pulse = old[x.id].pulse;
        const el = document.createElement(x.href ? 'a' : 'span'); el.className = 'r3d-tag' + (x.highlight ? ' hi' : '');
        if (x.href) { el.href = x.href; if (x.external) { el.target = '_blank'; el.rel = 'noopener noreferrer'; } }
        el.setAttribute('aria-label', `${x.label}: ${x.valueText || x.value}`);
        if (x.logo) { const img = document.createElement('img'); img.src = x.logo; img.alt = ''; img.loading = 'lazy'; el.append(img); }
        else { const ph = document.createElement('span'); ph.className = 'ph'; ph.textContent = String(x.label || '?').slice(0, 2); el.append(ph); }
        const nm = document.createElement('span'); nm.className = 'nm'; nm.textContent = x.label;
        const v = document.createElement('span'); v.className = 'v'; v.textContent = x.valueText || String(x.value);
        el.append(nm, v);
        const on = () => { active = i; idle = 0; el.classList.add('on'); if (reduce()) frame(performance.now()); };
        const off = () => { if (active === i) active = -1; el.classList.remove('on'); if (reduce()) frame(performance.now()); };
        el.addEventListener('mouseenter', on); el.addEventListener('focus', on); el.addEventListener('mouseleave', off); el.addEventListener('blur', off);
        tagsBox.append(el); it.el = el;
        return it;
      });
      resize(); start();
    }
    resize();
    return { setItems };
  };
})();

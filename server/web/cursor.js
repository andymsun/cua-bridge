// The agent's cursor for the live view: a rounded arrowhead that travels on springs.
// Long moves follow a gentle curve and the cursor turns along its heading; short
// moves "scoot" with a little squash and tilt; on arrival it settles with a small
// wiggle. `onArrived(seq)` fires when a move lands, so the agent's click can wait for it.
(() => {
  const SIZE = 24, TIP = 3.6;                // the arrow tip is the hotspot and the pivot
  const REST = -44;                         // resting heading: tip pointing up-left
  const FAR = 196;                          // px: longer moves take the curved path

  // A damped spring parameterised like SwiftUI: response (s) and damping fraction.
  class Spring {
    constructor(value, { response, damping }) { this.value = this.target = value; this.v = 0; this.response = response; this.damping = damping; }
    snap(x) { this.value = this.target = x; this.v = 0; }
    step(dt) {
      const k = (2 * Math.PI / Math.max(0.001, this.response)) ** 2, c = 4 * Math.PI * this.damping / Math.max(0.001, this.response);
      for (let t = 0; t < dt; t += 1 / 240) {          // fixed sub-steps keep stiff springs stable
        const a = k * (this.target - this.value) - c * this.v;
        this.v += a / 240; this.value += this.v / 240;
      }
      if (Math.abs(this.target - this.value) < 0.01 && Math.abs(this.v) < 0.05) { this.value = this.target; this.v = 0; }
    }
    get settled() { return this.value === this.target && this.v === 0; }
  }
  const angleTo = (from, to) => { let d = to - from; while (d > 180) d -= 360; while (d < -180) d += 360; return from + d; };
  const deg = (dx, dy) => Math.atan2(dy, dx) * 180 / Math.PI;

  const GLYPH = `<svg width="${SIZE}" height="${SIZE}" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
    <path d="M4.2 3.4c-.5-.2-1 .3-.8.8l6.3 16.3c.2.5.9.5 1.1 0l2.5-6.2c.1-.2.2-.3.4-.4l6.2-2.5c.5-.2.5-.9 0-1.1Z"
      fill="#0d0d0d" stroke="#fff" stroke-width="2.2" stroke-linejoin="round"/></svg>`;

  window.AgentCursor = function AgentCursor(layer, { color = "#339cff", onArrived } = {}) {
    const el = document.createElement("div");
    el.setAttribute("aria-hidden", "true");
    el.style.cssText = `position:absolute;left:0;top:0;width:${SIZE}px;height:${SIZE}px;pointer-events:none;will-change:transform,opacity;z-index:5`;
    const glyph = document.createElement("div");
    glyph.innerHTML = GLYPH;
    // the SVG's tip sits near its top-left corner; (x, y) is the tip and it turns about it
    glyph.style.cssText = `width:${SIZE}px;height:${SIZE}px;transform-origin:${TIP}px ${TIP}px;
      filter:drop-shadow(0 1px 1.5px rgba(0,0,0,.35)) drop-shadow(0 0 6px color-mix(in srgb, ${color} 90%, transparent)) drop-shadow(0 0 15px color-mix(in srgb, ${color} 45%, transparent))`;
    el.append(glyph);
    layer.append(el);

    const s = {
      x: new Spring(0, { response: 0.19, damping: 0.9 }), y: new Spring(0, { response: 0.19, damping: 0.9 }),
      rot: new Spring(REST, { response: 0.12, damping: 0.9 }),
      stretch: new Spring(1, { response: 0.2, damping: 0.85 }),
      squash: new Spring(1, { response: 0.05, damping: 0.82 }), tilt: new Spring(0, { response: 0.05, damping: 0.82 }),
      vis: new Spring(0, { response: 0.42, damping: 0.86 }),
      press: new Spring(1, { response: 0.16, damping: 0.6 }),
    };
    let motion = null, settleAt = null, raf = 0, last = 0, placed = false, axis = 0;

    const render = (now) => {
      const vis = Math.min(1, Math.max(0, s.vis.value));
      let rot = s.rot.value;
      if (settleAt !== null) {                          // small wiggle once it lands
        const t = (now - settleAt) / 1000, env = Math.sin(Math.min(1, t / 1.4) * Math.PI);
        rot += Math.sin(t / 0.66 * Math.PI * 2) * env * 10;
        if (t >= 1.4) settleAt = null;
      }
      const scale = (0.4 + 0.6 * vis) * s.press.value;
      el.style.opacity = vis.toFixed(3);
      el.style.transform = `translate3d(${(s.x.value - TIP).toFixed(2)}px, ${(s.y.value - TIP).toFixed(2)}px, 0)`;
      glyph.style.transform =
        `rotate(${axis.toFixed(2)}deg) scale(1, ${s.squash.value.toFixed(3)}) rotate(${(-axis).toFixed(2)}deg) ` +
        `rotate(${(rot - REST + s.tilt.value).toFixed(2)}deg) scale(${(scale * s.stretch.value).toFixed(3)}, ${scale.toFixed(3)})`;
      el.style.filter = vis < 1 ? `blur(${((1 - vis) * 5).toFixed(2)}px)` : "";
    };

    const tick = (now) => {
      raf = 0;
      const dt = Math.min(1 / 20, last ? (now - last) / 1000 : 1 / 60); last = now;
      const px = s.x.value, py = s.y.value;
      if (motion?.mode === "curve") {
        motion.p.step(dt);
        const t = Math.min(1, Math.max(0, motion.p.value)), u = 1 - t, { a, c, b } = motion;
        s.x.target = u * u * a.x + 2 * u * t * c.x + t * t * b.x;
        s.y.target = u * u * a.y + 2 * u * t * c.y + t * t * b.y;
        const tx = 2 * u * (c.x - a.x) + 2 * t * (b.x - c.x), ty = 2 * u * (c.y - a.y) + 2 * t * (b.y - c.y);
        // the glyph points at -135° at rest; turn it to point along the path
        s.rot.target = angleTo(s.rot.value, REST + deg(tx, ty) + 135);
      }
      for (const k of Object.keys(s)) s[k].step(dt);
      const speed = Math.hypot(s.x.value - px, s.y.value - py) / Math.max(dt, 1 / 240);
      s.stretch.target = Math.min(1, Math.max(0.65, 1 - speed / 5500));
      if (motion?.mode === "scoot") {
        const d = Math.hypot(motion.b.x - motion.a.x, motion.b.y - motion.a.y) || 1;
        const t = Math.min(1, Math.max(0, ((s.x.value - motion.a.x) * (motion.b.x - motion.a.x) + (s.y.value - motion.a.y) * (motion.b.y - motion.a.y)) / (d * d)));
        const bump = Math.sin(t * Math.PI);
        s.squash.target = 1 - 0.15 * bump;
        s.tilt.target = motion.tilt * bump;
      }
      if (motion && Math.hypot(s.x.value - motion.b.x, s.y.value - motion.b.y) < 0.85 && Math.abs(s.x.v) < 12 && Math.abs(s.y.v) < 12
          && (motion.mode !== "curve" || motion.p.value > 0.999)) {
        s.x.snap(motion.b.x); s.y.snap(motion.b.y);
        s.rot.target = angleTo(s.rot.value, REST); s.squash.target = 1; s.tilt.target = 0; s.stretch.target = 1;
        const seq = motion.seq, click = motion.click;
        motion = null; settleAt = now;
        if (click) { s.press.value = 0.82; s.press.v = 0; s.press.target = 1; }
        if (seq != null) onArrived?.(seq);
      }
      render(now);
      if (motion || settleAt !== null || !Object.values(s).every((sp) => sp.settled)) raf = requestAnimationFrame(tick);
      else last = 0;
    };
    const kick = () => { if (!raf) raf = requestAnimationFrame(tick); };

    return {
      /** Move to (x, y) in layer pixels. `animate: false` jumps. */
      moveTo(x, y, { seq = null, click = false, animate = true } = {}) {
        s.vis.target = 1;
        if (!placed || !animate) {
          placed = true;
          s.x.snap(x); s.y.snap(y); motion = null;
          if (!animate || s.vis.value < 0.05) {        // first appearance: fade in where it is
            render(performance.now());
            if (seq != null) setTimeout(() => onArrived?.(seq), 180);
            if (click) { s.press.value = 0.82; s.press.target = 1; }
            kick(); return;
          }
        }
        const a = { x: s.x.value, y: s.y.value }, b = { x, y };
        const dx = b.x - a.x, dy = b.y - a.y, dist = Math.hypot(dx, dy);
        if (dist < 0.5) { if (seq != null) onArrived?.(seq); if (click) { s.press.value = 0.82; s.press.target = 1; kick(); } return; }
        settleAt = null;
        if (dist <= FAR) {
          axis = deg(dx, dy);
          const nx = dx / dist, ny = dy / dist;
          motion = { mode: "scoot", a, b, seq, click, tilt: Math.max(-1, Math.min(1, nx * 0.75 - ny * 0.62)) * 70 * 0.15 };
          s.x.target = b.x; s.y.target = b.y;
          s.x.response = s.y.response = 0.19; s.x.damping = s.y.damping = 0.9;
        } else {
          axis = 0;
          // bow the path a little to one side, more for longer moves
          const bow = Math.min(0.22, 40 / dist) * dist, nx = -dy / dist, ny = dx / dist;
          const c = { x: (a.x + b.x) / 2 + nx * bow, y: (a.y + b.y) / 2 + ny * bow };
          const response = Math.min(0.7, Math.max(0.32, dist / 1400));
          motion = { mode: "curve", a, b, c, seq, click, p: new Spring(0, { response, damping: 0.94 }) };
          motion.p.target = 1;
          s.x.response = s.y.response = Math.min(0.12, Math.max(0.035, response * 0.18)); s.x.damping = s.y.damping = 0.9;
        }
        kick();
      },
      hide() { s.vis.target = 0; kick(); },
      get visible() { return s.vis.target > 0; },
      destroy() { cancelAnimationFrame(raf); el.remove(); },
    };
  };
})();

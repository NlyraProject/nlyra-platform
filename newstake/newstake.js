/* NLYRA · Real Yield Staking v2 · preview page */
(function () {
  "use strict";

  var TOKEN = "0xb9d3824149ad8ac984153ceec91d5a2405d1fb95";
  var FALLBACK_PRICE = 0.000216;
  var WEEK = 604800;
  var POT_DEFAULT = 490;
  var RM = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  var $ = function (s, r) { return (r || document).querySelector(s); };
  var $$ = function (s, r) { return Array.prototype.slice.call((r || document).querySelectorAll(s)); };

  /* ---------------- formatting ---------------- */
  function fmtInt(n) { return Math.round(n).toLocaleString("en-US"); }
  function fmtUsd(n) {
    if (!isFinite(n)) return "—";
    var a = Math.abs(n);
    if (a === 0) return "$0";
    if (a < 1) return "$" + n.toFixed(2);
    if (a < 1000) return "$" + n.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    return "$" + fmtInt(n);
  }
  function fmtCompactUsd(n) {
    if (!isFinite(n) || n <= 0) return "—";
    if (n >= 1e9) return "$" + (n / 1e9).toFixed(2) + "B";
    if (n >= 1e6) return "$" + (n / 1e6).toFixed(2) + "M";
    if (n >= 1e3) return "$" + (n / 1e3).toFixed(1) + "k";
    return "$" + n.toFixed(0);
  }
  function fmtPrice(p) {
    if (!isFinite(p) || p <= 0) return "—";
    if (p >= 1) return "$" + p.toFixed(4);
    var s = p.toPrecision(4);
    return "$" + Number(s).toFixed(Math.max(4, -Math.floor(Math.log10(p)) + 3));
  }
  function fmtCompactNum(n) {
    if (n >= 1e9) return (n / 1e9).toFixed(2).replace(/\.?0+$/, "") + "B";
    if (n >= 1e6) return (n / 1e6).toFixed(2).replace(/\.?0+$/, "") + "M";
    if (n >= 1e3) return (n / 1e3).toFixed(1).replace(/\.?0+$/, "") + "k";
    return fmtInt(n);
  }
  function parseNum(v) {
    if (v == null) return NaN;
    var s = String(v).trim().toLowerCase().replace(/[, _$]/g, "");
    var mult = 1;
    var last = s.slice(-1);
    if (last === "k") { mult = 1e3; s = s.slice(0, -1); }
    else if (last === "m") { mult = 1e6; s = s.slice(0, -1); }
    else if (last === "b") { mult = 1e9; s = s.slice(0, -1); }
    var n = parseFloat(s);
    return isFinite(n) ? n * mult : NaN;
  }

  /* ---------------- nav + jumps ---------------- */
  var nav = $(".nav");
  function onScroll() { nav.classList.toggle("scrolled", window.scrollY > 8); }
  window.addEventListener("scroll", onScroll, { passive: true });
  onScroll();

  $$("a[data-jump]").forEach(function (a) {
    a.addEventListener("click", function (e) {
      var id = a.getAttribute("href").split("#")[1];
      var el = id && document.getElementById(id);
      if (!el) return;
      e.preventDefault();
      el.scrollIntoView({ behavior: RM ? "auto" : "smooth", block: "start" });
      try { history.replaceState(null, "", "#" + id); } catch (_) {}
    });
  });

  /* ---------------- reveal + count-up ---------------- */
  function countUp(el) {
    var target = parseFloat(el.getAttribute("data-count"));
    if (RM || !isFinite(target)) { el.textContent = fmtInt(target); return; }
    var t0 = performance.now(), dur = 1400;
    el.textContent = "0";
    (function step(now) {
      var k = Math.min(1, (now - t0) / dur);
      var e = 1 - Math.pow(1 - k, 3);
      el.textContent = fmtInt(target * e);
      if (k < 1) requestAnimationFrame(step);
    })(t0);
  }

  var reveals = $$(".reveal");
  if ("IntersectionObserver" in window) {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (!en.isIntersecting) return;
        var el = en.target;
        var sibs = el.parentElement ? $$(":scope > .reveal", el.parentElement) : [];
        var idx = Math.max(0, sibs.indexOf(el));
        el.style.transitionDelay = RM ? "0s" : Math.min(idx, 5) * 70 + "ms";
        el.classList.add("in");
        $$("[data-count]", el).forEach(countUp);
        io.unobserve(el);
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 });
    reveals.forEach(function (el) { io.observe(el); });
  } else {
    reveals.forEach(function (el) { el.classList.add("in"); });
  }

  /* visibility helper for loops */
  function whenVisible(el, cb) {
    if (!("IntersectionObserver" in window)) { cb(true); return; }
    new IntersectionObserver(function (en) { cb(en[0].isIntersecting); }, { threshold: 0.05 }).observe(el);
  }

  /* ---------------- pointer glow on cards ---------------- */
  if (!RM && window.matchMedia("(hover: hover)").matches) {
    $$(".tier, .safe, .fnode").forEach(function (c) {
      c.addEventListener("pointermove", function (e) {
        var r = c.getBoundingClientRect();
        c.style.setProperty("--mx", (e.clientX - r.left) + "px");
        c.style.setProperty("--my", (e.clientY - r.top) + "px");
      });
    });
  }

  /* ---------------- live market data ---------------- */
  var livePrice = null;
  function fetchJSON(url, ms) {
    var ctrl = "AbortController" in window ? new AbortController() : null;
    var to = setTimeout(function () { if (ctrl) ctrl.abort(); }, ms);
    return fetch(url, { signal: ctrl ? ctrl.signal : undefined, headers: { accept: "application/json" } })
      .then(function (r) { clearTimeout(to); if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); });
  }
  function loadMarket() {
    var path = "/api/desk/token?t=" + TOKEN;
    var onSite = /(^|\.)nlyra\.xyz$/.test(location.hostname);
    var p = fetchJSON((onSite ? "" : "https://nlyra.xyz") + path, 8000);
    p.then(function (d) {
      if (!d || !d.ok) throw new Error("bad payload");
      var b = d.best || {};
      var price = Number(d.priceUsd || b.priceUsd);
      if (!(price > 0)) throw new Error("no price");
      var supply = (d.token && d.token.supply) || 1e9;
      var mcap = Number(b.mcap) || price * supply;
      var vol = Number(b.vol24) || (d.onchain && Number(d.onchain.vol24Usd)) || 0;
      var liq = Number(b.liqUsd) || 0;
      $("#tk-price").textContent = fmtPrice(price);
      $("#tk-mcap").textContent = fmtCompactUsd(mcap);
      $("#tk-vol").textContent = fmtCompactUsd(vol);
      $("#tk-liq").textContent = fmtCompactUsd(liq);
      var ch = Number(b.ch24);
      var t = new Date();
      var hh = String(t.getUTCHours()).padStart(2, "0") + ":" + String(t.getUTCMinutes()).padStart(2, "0");
      $("#tk-note").textContent = "Live from Robinhood Chain · " + hh + " UTC" + (isFinite(ch) ? " · 24h " + (ch > 0 ? "+" : "") + ch.toFixed(1) + "%" : "");
      livePrice = price;
      applyLivePrice();
    }).catch(function () {
      $("#tk-note").textContent = "Live market data is unavailable right now. The calculator uses the last known price; edit it freely.";
    });
  }

  /* ---------------- hero stream counter ---------------- */
  (function streamCard() {
    var big = $("#scBig"), bar = $("#scBar"), rateEl = $("#scRate");
    if (!big) return;
    var perSec = POT_DEFAULT / WEEK;
    rateEl.textContent = "$" + perSec.toFixed(5);
    function weekStart() {
      var d = new Date();
      var day = (d.getUTCDay() + 6) % 7; // Monday = 0
      return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() - day) / 1000;
    }
    var ws = weekStart();
    var running = true, last = 0;
    function draw(now) {
      if (running && (now - last > (RM ? 1000 : 90))) {
        last = now;
        var el = Date.now() / 1000 - ws;
        if (el > WEEK) { ws = weekStart(); el = Date.now() / 1000 - ws; }
        big.textContent = "$" + (el * perSec).toFixed(4);
        bar.style.width = (el / WEEK * 100).toFixed(3) + "%";
      }
      requestAnimationFrame(draw);
    }
    requestAnimationFrame(draw);
    whenVisible(big, function (v) { running = v; });
  })();

  /* ---------------- hero canvas: the Dual Core ---------------- */
  (function core() {
    var stage = $("#coreStage"), cv = $("#coreCanvas");
    if (!cv || !cv.getContext) return;
    var ctx = cv.getContext("2d");
    var S = 0, dpr = 1, R = 0, D = 0;
    var VIO = [139, 124, 246], MAG = [232, 79, 224], GRY = [154, 167, 189];
    var parts = [], dust = [];
    var t = 0, spawnAcc = 0, flash = 0, colorFlip = 0;
    var visible = true, raf = 0, lastTs = 0;

    function resize() {
      var r = stage.getBoundingClientRect();
      S = Math.max(200, Math.round(r.width));
      dpr = Math.min(2, window.devicePixelRatio || 1);
      cv.width = S * dpr; cv.height = S * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      R = S * 0.25; D = R * 0.56;
      dust = [];
      for (var i = 0; i < 70; i++) {
        var a = Math.random() * Math.PI * 2, rr = S * (0.2 + Math.random() * 0.32);
        dust.push({ x: S / 2 + Math.cos(a) * rr, y: S / 2 + Math.sin(a) * rr, r: Math.random() * 1.2 + 0.3, a: Math.random() * 0.35 + 0.05, tw: Math.random() * 6 });
      }
      if (RM) renderStatic();
    }

    // 3D ring point → screen
    function ringPoint(ring, th, out) {
      var x, y, z;
      if (ring === 0) { x = -D + R * Math.cos(th); y = R * Math.sin(th); z = 0; }
      else { x = D - R * Math.cos(th); y = 0; z = R * Math.sin(th); }
      var ay = 0.42 + 0.22 * Math.sin(t * 0.18), ax = 0.5 + 0.08 * Math.cos(t * 0.13);
      var cy = Math.cos(ay), sy = Math.sin(ay);
      var x1 = x * cy + z * sy, z1 = -x * sy + z * cy;
      var cx = Math.cos(ax), sx = Math.sin(ax);
      var y2 = y * cx - z1 * sx, z2 = y * sx + z1 * cx;
      var f = R * 3.4, k = f / (f + z2);
      out.x = S / 2 + x1 * k; out.y = S / 2 + y2 * k; out.z = z2; out.k = k;
      return out;
    }
    var P = { x: 0, y: 0, z: 0, k: 1 };

    function bez(p0, p1, p2, u) {
      var a = 1 - u;
      return { x: a * a * p0.x + 2 * a * u * p1.x + u * u * p2.x, y: a * a * p0.y + 2 * a * u * p1.y + u * u * p2.y };
    }

    function spawn() {
      colorFlip ^= 1;
      var ring = colorFlip; // WETH (violet) -> ring 0, NLYRA (magenta) -> ring 1
      var y0 = S * (0.35 + Math.random() * 0.3);
      parts.push({
        st: "in", u: 0, sp: 0.55 + Math.random() * 0.3,
        p0: { x: -8, y: y0 }, p1: { x: S * 0.22, y: y0 + (Math.random() - 0.5) * S * 0.25 }, p2: { x: S / 2, y: S / 2 },
        ring: ring, col: ring ? MAG : VIO, x: -8, y: y0, hist: [], a: 1,
        toStakers: Math.random() < 0.5, th: 0, turns: 0, size: 1.4 + Math.random() * 1.2
      });
    }

    function step(dt) {
      t += dt;
      flash = Math.max(0, flash - dt * 2.2);
      spawnAcc += dt;
      var every = S < 420 ? 0.2 : 0.14;
      while (spawnAcc > every) { spawnAcc -= every; if (parts.length < 110) spawn(); }
      for (var i = parts.length - 1; i >= 0; i--) {
        var p = parts[i];
        p.hist.push(p.x, p.y);
        if (p.hist.length > 16) p.hist.splice(0, 2);
        if (p.st === "in") {
          p.u += dt * p.sp;
          var e = p.u * p.u * (3 - 2 * p.u);
          var q = bez(p.p0, p.p1, p.p2, Math.min(1, e)); p.x = q.x; p.y = q.y;
          if (p.u >= 1) {
            flash = Math.min(1, flash + 0.35);
            if (p.toStakers) {
              p.st = "join"; p.u = 0;
              p.th = 0; // entry point closest to the node
              p.p0 = { x: p.x, y: p.y };
            } else {
              p.st = "tr"; p.u = 0; p.p0 = { x: p.x, y: p.y };
              p.p1 = { x: S * 0.72, y: S * 0.42 }; p.p2 = { x: S + 10, y: S * 0.13 };
            }
          }
        } else if (p.st === "join") {
          p.u += dt * 2.4;
          ringPoint(p.ring, p.th, P);
          var u = Math.min(1, p.u);
          p.x = p.p0.x + (P.x - p.p0.x) * u; p.y = p.p0.y + (P.y - p.p0.y) * u;
          if (p.u >= 1) { p.st = "ring"; p.turns = 0.9 + Math.random() * 0.9; }
        } else if (p.st === "ring") {
          var w = 1.35 * dt;
          p.th += p.ring === 0 ? w : -w;
          p.turns -= w / (Math.PI * 2);
          ringPoint(p.ring, p.th, P);
          p.x = P.x; p.y = P.y; p.z = P.z;
          if (p.turns <= 0) {
            p.st = "out"; p.u = 0; p.p0 = { x: p.x, y: p.y };
            p.p1 = { x: S / 2 + (p.x - S / 2) * 0.4, y: S * 0.8 }; p.p2 = { x: S / 2 + (Math.random() - 0.5) * S * 0.08, y: S * 0.93 };
          }
        } else if (p.st === "tr") {
          p.u += dt * 0.7;
          var q2 = bez(p.p0, p.p1, p.p2, Math.min(1, p.u)); p.x = q2.x; p.y = q2.y;
          p.a = Math.max(0, 1 - p.u * 1.1);
          if (p.u >= 1) parts.splice(i, 1);
        } else if (p.st === "out") {
          p.u += dt * 0.9;
          var q3 = bez(p.p0, p.p1, p.p2, Math.min(1, p.u)); p.x = q3.x; p.y = q3.y;
          p.a = Math.max(0, 1 - Math.pow(p.u, 3));
          if (p.u >= 1) parts.splice(i, 1);
        }
      }
    }

    function rgba(c, a) { return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + a.toFixed(3) + ")"; }

    function drawRing(ring, col) {
      var N = 140, prev = null;
      ctx.lineCap = "round";
      for (var i = 0; i <= N; i++) {
        var th = (i / N) * Math.PI * 2;
        ringPoint(ring, th, P);
        var cur = { x: P.x, y: P.y, z: P.z };
        if (prev) {
          var depth = (-(prev.z + cur.z) / 2) / R; // + = closer to viewer
          var a = 0.38 + 0.42 * Math.max(-1, Math.min(1, depth));
          ctx.strokeStyle = rgba(col, a * 0.18);
          ctx.lineWidth = 9;
          ctx.beginPath(); ctx.moveTo(prev.x, prev.y); ctx.lineTo(cur.x, cur.y); ctx.stroke();
          ctx.strokeStyle = rgba(col, a);
          ctx.lineWidth = 1.2 + 1.3 * (depth + 1) / 2;
          ctx.beginPath(); ctx.moveTo(prev.x, prev.y); ctx.lineTo(cur.x, cur.y); ctx.stroke();
        }
        prev = cur;
      }
    }

    function render() {
      ctx.clearRect(0, 0, S, S);
      var c = S / 2;

      // halo
      var g = ctx.createRadialGradient(c, c, 0, c, c, S * 0.48);
      g.addColorStop(0, "rgba(139,124,246," + (0.1 + flash * 0.05).toFixed(3) + ")");
      g.addColorStop(0.55, "rgba(232,79,224,0.035)");
      g.addColorStop(1, "rgba(7,11,24,0)");
      ctx.fillStyle = g; ctx.fillRect(0, 0, S, S);

      // dust
      for (var i = 0; i < dust.length; i++) {
        var d = dust[i];
        ctx.fillStyle = "rgba(233,238,248," + (d.a * (0.6 + 0.4 * Math.sin(t * 0.8 + d.tw))).toFixed(3) + ")";
        ctx.beginPath(); ctx.arc(d.x, d.y, d.r, 0, 6.2832); ctx.fill();
      }

      // outer orbit with ticks
      ctx.save();
      ctx.translate(c, c); ctx.rotate(t * 0.05);
      ctx.strokeStyle = "rgba(154,167,189,0.10)"; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.arc(0, 0, S * 0.44, 0, 6.2832); ctx.stroke();
      for (var k = 0; k < 72; k++) {
        var ang = k / 72 * 6.2832, L = k % 6 === 0 ? 8 : 3;
        ctx.strokeStyle = k % 6 === 0 ? "rgba(139,124,246,0.35)" : "rgba(154,167,189,0.14)";
        ctx.beginPath();
        ctx.moveTo(Math.cos(ang) * S * 0.44, Math.sin(ang) * S * 0.44);
        ctx.lineTo(Math.cos(ang) * (S * 0.44 - L), Math.sin(ang) * (S * 0.44 - L));
        ctx.stroke();
      }
      ctx.restore();

      // rings
      drawRing(0, VIO);
      drawRing(1, MAG);

      // particles
      ctx.globalCompositeOperation = "lighter";
      for (var j = 0; j < parts.length; j++) {
        var p = parts[j];
        var col = p.st === "tr" ? GRY : p.col;
        var h = p.hist, n = h.length / 2;
        for (var s = 1; s < n; s++) {
          ctx.strokeStyle = rgba(col, (s / n) * 0.35 * p.a);
          ctx.lineWidth = p.size * (s / n) * 1.3;
          ctx.beginPath(); ctx.moveTo(h[(s - 1) * 2], h[(s - 1) * 2 + 1]); ctx.lineTo(h[s * 2], h[s * 2 + 1]); ctx.stroke();
        }
        var depthA = p.st === "ring" ? 0.55 + 0.45 * Math.max(-1, Math.min(1, -p.z / R)) : 1;
        ctx.fillStyle = rgba(col, 0.9 * p.a * depthA);
        ctx.beginPath(); ctx.arc(p.x, p.y, p.size, 0, 6.2832); ctx.fill();
        ctx.fillStyle = rgba(col, 0.16 * p.a * depthA);
        ctx.beginPath(); ctx.arc(p.x, p.y, p.size * 4, 0, 6.2832); ctx.fill();
      }
      ctx.globalCompositeOperation = "source-over";

      // central node glow (logo sits on top)
      var ng = ctx.createRadialGradient(c, c, 0, c, c, S * 0.16);
      ng.addColorStop(0, "rgba(233,238,248," + (0.1 + flash * 0.16).toFixed(3) + ")");
      ng.addColorStop(0.4, "rgba(139,124,246," + (0.12 + flash * 0.1).toFixed(3) + ")");
      ng.addColorStop(1, "rgba(139,124,246,0)");
      ctx.fillStyle = ng; ctx.beginPath(); ctx.arc(c, c, S * 0.16, 0, 6.2832); ctx.fill();
    }

    function renderStatic() {
      parts = []; t = 2;
      for (var i = 0; i < 360; i++) step(1 / 30);
      render();
    }

    function loop(ts) {
      raf = 0;
      if (!visible || document.hidden) return;
      var dt = lastTs ? Math.min(0.05, (ts - lastTs) / 1000) : 1 / 60;
      lastTs = ts;
      step(dt); render();
      raf = requestAnimationFrame(loop);
    }
    function start() { if (!raf && !RM) { lastTs = 0; raf = requestAnimationFrame(loop); } }

    resize();
    if ("ResizeObserver" in window) new ResizeObserver(function () { resize(); if (!RM) render(); }).observe(stage);
    else window.addEventListener("resize", resize);
    if (RM) { renderStatic(); return; }
    // pre-warm so the first frame already has flow
    for (var w = 0; w < 150; w++) step(1 / 30);
    whenVisible(stage, function (v) { visible = v; if (v) start(); });
    document.addEventListener("visibilitychange", function () { if (!document.hidden) start(); });
    start();
  })();

  /* ---------------- flow lighting ---------------- */
  (function flow() {
    var nodes = $$("#flow .fnode");
    if (!nodes.length || RM) return;
    var i = 0, timer = null;
    function tick() {
      nodes.forEach(function (n, k) { n.classList.toggle("lit", k === i); });
      i = (i + 1) % nodes.length;
    }
    whenVisible($("#flow"), function (v) {
      if (v && !timer) { tick(); timer = setInterval(tick, 1100); }
      else if (!v && timer) { clearInterval(timer); timer = null; nodes.forEach(function (n) { n.classList.remove("lit"); }); }
    });
  })();

  /* ---------------- calculator ---------------- */
  var inAmt = $("#inAmt"), inAmtR = $("#inAmtR"), inPool = $("#inPool"), inPot = $("#inPot"),
      inPrice = $("#inPrice"), inAvg = $("#inAvg"), priceChip = $("#priceChip");
  var priceEdited = false;
  var MIN_A = 1e5, MAX_A = 1e9;

  function amtToSlider(a) {
    a = Math.min(MAX_A, Math.max(MIN_A, a || MIN_A));
    return Math.round((Math.log10(a) - 5) / 4 * 1000);
  }
  function sliderToAmt(s) {
    var raw = Math.pow(10, 5 + 4 * s / 1000);
    var mag = Math.pow(10, Math.floor(Math.log10(raw)) - 1);
    return Math.round(raw / mag) * mag;
  }
  function paintSlider() { inAmtR.style.setProperty("--p", (inAmtR.value / 10) + "%"); }

  function tier() { var r = $("input[name=tier]:checked"); return r ? parseFloat(r.value) : 1; }
  function tierIndex() { return $$("input[name=tier]").findIndex(function (r) { return r.checked; }); }

  var shown = {};
  function tweenTo(id, value, fmt) {
    var el = document.getElementById(id);
    if (!el) return;
    var from = shown[id];
    shown[id] = value;
    if (RM || from == null || !isFinite(from) || !isFinite(value)) { el.textContent = fmt(value); return; }
    var t0 = performance.now(), dur = 420;
    var token = {}; el._tw = token;
    (function f(now) {
      if (el._tw !== token) return;
      var k = Math.min(1, (now - t0) / dur), e = 1 - Math.pow(1 - k, 3);
      el.textContent = fmt(from + (value - from) * e);
      if (k < 1) requestAnimationFrame(f);
    })(t0);
  }
  function pct(n) {
    if (!isFinite(n)) return "—";
    if (n >= 100) return fmtInt(n) + "%";
    return n.toFixed(n < 10 ? 2 : 1) + "%";
  }

  function compute() {
    var amt = Math.max(0, parseNum(inAmt.value) || 0);
    var pool = Math.max(0, parseNum(inPool.value) || 0);
    var pot = Math.max(0, parseNum(inPot.value) || 0);
    var price = Math.max(0, parseNum(inPrice.value) || 0);
    var avg = parseFloat(inAvg.value) || 1;
    var mult = tier();

    var w = amt * mult;
    var total = w + pool * avg;
    var share = total > 0 ? w / total : 0;
    var weekly = pot * share;
    var monthly = weekly * (365.25 / 12 / 7);
    var yearly = weekly * (365 / 7);
    var stakeUsd = amt * price;
    var apr = stakeUsd > 0 ? yearly / stakeUsd * 100 : NaN;

    tweenTo("outShare", share * 100, function (v) { return v >= 10 ? v.toFixed(1) + "%" : v.toFixed(2) + "%"; });
    tweenTo("outApr", apr, pct);
    tweenTo("outWk", weekly, fmtUsd);
    tweenTo("outMo", monthly, fmtUsd);
    tweenTo("outYr", yearly, fmtUsd);
    tweenTo("sHalf", weekly * 0.5, fmtUsd);
    tweenTo("sSame", weekly, fmtUsd);
    tweenTo("sDbl", weekly * 2, fmtUsd);
    $("#outW").textContent = fmtCompactNum(w);
    $("#amtUsd").textContent = fmtUsd(stakeUsd);
    var dash = share > 0 ? Math.max(1.2, share * 100) : 0;
    $("#donutFg").setAttribute("stroke-dasharray", dash.toFixed(2) + " " + (100 - dash).toFixed(2));

    $$(".quick button").forEach(function (b) { b.classList.toggle("on", parseFloat(b.getAttribute("data-amt")) === amt); });
    var ind = $(".seg-ind");
    if (ind) ind.style.transform = "translateX(" + (tierIndex() * 100) + "%)";
  }

  function pop(id) {
    var el = document.getElementById(id);
    if (!el || RM) return;
    el.classList.remove("pop"); void el.offsetWidth; el.classList.add("pop");
  }

  function applyLivePrice() {
    if (livePrice && !priceEdited) {
      inPrice.value = Number(livePrice.toPrecision(4)).toString();
      priceChip.textContent = "live";
      priceChip.classList.add("is-live");
      compute(); pop("outApr");
    }
  }

  function formatField(el) {
    var n = parseNum(el.value);
    if (isFinite(n)) el.value = n >= 1000 ? fmtInt(n) : String(n);
  }

  if (inAmt) {
    inAmtR.value = amtToSlider(parseNum(inAmt.value));
    paintSlider();
    inAmt.addEventListener("input", function () {
      inAmtR.value = amtToSlider(parseNum(inAmt.value)); paintSlider(); compute();
    });
    inAmtR.addEventListener("input", function () {
      inAmt.value = fmtInt(sliderToAmt(+inAmtR.value)); paintSlider(); compute();
    });
    $$(".quick button").forEach(function (b) {
      b.addEventListener("click", function () {
        var a = parseFloat(b.getAttribute("data-amt"));
        inAmt.value = fmtInt(a); inAmtR.value = amtToSlider(a); paintSlider(); compute(); pop("outYr");
      });
    });
    [inPool, inPot].forEach(function (el) { el.addEventListener("input", compute); });
    [inAmt, inPool, inPot].forEach(function (el) { el.addEventListener("blur", function () { formatField(el); compute(); }); });
    inPrice.addEventListener("input", function () {
      priceEdited = true; priceChip.textContent = "manual"; priceChip.classList.remove("is-live"); compute();
    });
    inAvg.addEventListener("change", compute);
    $$("input[name=tier]").forEach(function (r) { r.addEventListener("change", function () { compute(); pop("outApr"); }); });
    compute();
  }

  /* ---------------- claim options ---------------- */
  (function claim() {
    var desc = {
      eth: "The WETH half is unwrapped and the NLYRA half is swapped to ETH, in the same transaction.",
      nlyra: "The WETH half is swapped into NLYRA in the same transaction. Stack more of the token.",
      usdg: "Both halves are swapped to USDG on-chain in the same transaction, with a guaranteed minimum out. If the minimum can't be met, the claim doesn't go through."
    };
    var tabs = $$(".cm-opts button"), out = $("#cmDesc");
    function sel(b) {
      tabs.forEach(function (x) { x.setAttribute("aria-selected", x === b ? "true" : "false"); x.tabIndex = x === b ? 0 : -1; });
      out.textContent = desc[b.getAttribute("data-opt")];
    }
    tabs.forEach(function (b, i) {
      b.tabIndex = i === 0 ? 0 : -1;
      b.addEventListener("click", function () { sel(b); });
      b.addEventListener("keydown", function (e) {
        var d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0;
        if (!d) return;
        e.preventDefault();
        var n = tabs[(i + d + tabs.length) % tabs.length]; sel(n); n.focus();
      });
    });
  })();

  /* ---------------- A -> B transfer animation ---------------- */
  (function ab() {
    var pos = $("#abPos"), a = $(".ab-a"), b = $(".ab-b"), steps = $$("#abSteps li");
    if (!pos) return;
    function setPhase(ph) {
      pos.classList.toggle("pending", ph === 1);
      pos.classList.toggle("at-b", ph >= 2);
      a.classList.toggle("act", ph <= 1);
      b.classList.toggle("act", ph >= 1);
      steps.forEach(function (li, k) { li.classList.toggle("on", k + 1 === ph || (ph === 3 && k === 2)); });
    }
    if (RM) { setPhase(2); steps.forEach(function (li) { li.classList.add("on"); }); return; }
    var ph = 0, timer = null;
    setPhase(0);
    whenVisible($("#abStage"), function (v) {
      if (v && !timer) { timer = setInterval(function () { ph = (ph + 1) % 4; setPhase(ph); }, 2300); }
      else if (!v && timer) { clearInterval(timer); timer = null; }
    });
  })();

  /* ---------------- copy buttons ---------------- */
  $$(".copy").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var v = btn.getAttribute("data-copy");
      var done = function () {
        btn.textContent = "Copied"; btn.classList.add("ok");
        setTimeout(function () { btn.textContent = "Copy"; btn.classList.remove("ok"); }, 1600);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(v).then(done, function () {});
      else {
        var ta = document.createElement("textarea"); ta.value = v; document.body.appendChild(ta); ta.select();
        try { document.execCommand("copy"); done(); } catch (_) {}
        ta.remove();
      }
    });
  });

  loadMarket();
})();

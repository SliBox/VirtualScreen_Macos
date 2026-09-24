//
//  BrowserStreamPage.swift
//  VirtualDisplayKit
//
//  The viewer page served at `/`. Embedded as a string so the kit needs no
//  resource bundle and works identically from SwiftPM and Xcode targets.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum BrowserStreamPage {

    /// Web app manifest, so the viewer can be installed to a home screen and
    /// opened without browser chrome.
    static let manifest = """
    {
      "name": "Virtual Display",
      "short_name": "Display",
      "start_url": "/",
      "display": "fullscreen",
      "display_override": ["fullscreen", "standalone"],
      "orientation": "any",
      "background_color": "#000000",
      "theme_color": "#000000",
      "icons": [
        { "src": "/icon.png", "sizes": "512x512", "type": "image/png", "purpose": "any" }
      ]
    }
    """

    /// Home-screen icon, drawn rather than embedded so there is no binary blob
    /// to keep in the source.
    static func icon(side: Int = 512) -> Data {
        let size = CGFloat(side)
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }

        context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        // A screen: rounded body, then a lighter panel inside.
        let body = CGRect(x: size * 0.14, y: size * 0.22, width: size * 0.72, height: size * 0.5)
        context.setFillColor(CGColor(red: 0.19, green: 0.51, blue: 0.96, alpha: 1))
        context.addPath(CGPath(roundedRect: body, cornerWidth: size * 0.06, cornerHeight: size * 0.06, transform: nil))
        context.fillPath()

        let panel = body.insetBy(dx: size * 0.05, dy: size * 0.05)
        context.setFillColor(CGColor(red: 0.85, green: 0.92, blue: 1, alpha: 1))
        context.addPath(CGPath(roundedRect: panel, cornerWidth: size * 0.03, cornerHeight: size * 0.03, transform: nil))
        context.fillPath()

        // Stand.
        context.setFillColor(CGColor(red: 0.19, green: 0.51, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: size * 0.42, y: size * 0.16, width: size * 0.16, height: size * 0.07))
        context.fill(CGRect(x: size * 0.3, y: size * 0.13, width: size * 0.4, height: size * 0.05))

        guard let image = context.makeImage() else { return Data() }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return Data() }
        return output as Data
    }

    /// Identifies this build of the viewer. A page left open across an app
    /// update reconnects on its own — still running the old script — so the
    /// server announces the current version and a stale page reloads itself.
    static let version: String = {
        // FNV-1a: stable across launches, unlike Swift's seeded hashValue.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in html.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }()

    /// The page as served, stamped with its version.
    static let servedHTML = html.replacingOccurrences(of: "__PAGE_VERSION__", with: version)

    /// Self-contained viewer: no external assets, no frameworks.
    ///
    /// Each message is one captured frame: a table of tiles (rectangle plus
    /// JPEG length) followed by the JPEGs of just those regions. They are
    /// painted onto a persistent canvas, so a blinking cursor costs a few
    /// hundred bytes instead of a whole screenshot. Decoding happens off the
    /// main thread via `createImageBitmap`.
    static let html = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="Virtual Display">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="theme-color" content="#000000">
    <link rel="manifest" href="/manifest.webmanifest">
    <link rel="apple-touch-icon" href="/icon.png">
    <title>Virtual Display</title>
    <style>
      * { margin: 0; padding: 0; box-sizing: border-box; }

      html {
        height: 100%;
        background: #000;
      }

      body {
        /* A fixed, inset body is the only reliable way to stay inside the
           visible area on mobile browsers, where the layout viewport extends
           behind the collapsible toolbars. */
        position: fixed;
        inset: 0;
        width: 100%;
        height: 100%;
        overflow: hidden;
        overscroll-behavior: none;
        touch-action: none;
        background: #000;
        color: #f5f5f7;
        font: 13px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        -webkit-user-select: none;
        user-select: none;
        -webkit-tap-highlight-color: transparent;
      }

      /* Sized in JS from visualViewport, which is the part of the page the
         user can actually see — window.innerHeight is not. */
      #app {
        position: fixed;
        top: 0;
        left: 0;
        width: 100%;
        height: 100%;
        height: 100dvh; /* correct box before JS runs; ignored where unsupported */
        overflow: hidden;
      }

      #stage {
        position: absolute;
        inset: 0;
        overflow: hidden;
        background: #000;
        cursor: default;
        touch-action: none;
      }

      #stage.idle { cursor: none; }
      #stage.pannable { cursor: grab; }
      #stage.panning { cursor: grabbing; }

      /* Placed and scaled by transform, so zoom and pan cost nothing but a
         compositor matrix — no relayout, no repaint. The video element only
         appears when H.264 plays through Media Source Extensions. */
      canvas, video {
        position: absolute;
        top: 0;
        left: 0;
        transform-origin: 0 0;
        will-change: transform;
        display: block;
      }
      video { object-fit: fill; pointer-events: none; }

      /* The Mac's pointer, drawn here rather than in the frames so it moves
         as soon as its coordinates arrive. */
      #cursor {
        position: absolute;
        top: 0;
        left: 0;
        z-index: 5;
        display: none;
        transform-origin: 0 0;
        will-change: transform;
        pointer-events: none;
        background: no-repeat 0 0 / 100% 100%;
      }

      /* Overlays ------------------------------------------------------- */

      .chrome {
        position: absolute;
        z-index: 10;
        transition: opacity .28s ease;
      }

      #stage.idle ~ .chrome:not(.pinned) { opacity: 0; pointer-events: none; }
      .hidden { display: none !important; }

      #hud {
        top: max(12px, env(safe-area-inset-top));
        left: max(12px, env(safe-area-inset-left));
        display: flex;
        align-items: center;
        gap: 14px;
        padding: 9px 14px;
        border-radius: 999px;
        background: rgba(22, 22, 24, .72);
        border: 1px solid rgba(255, 255, 255, .09);
        backdrop-filter: blur(20px) saturate(180%);
        -webkit-backdrop-filter: blur(20px) saturate(180%);
        font-variant-numeric: tabular-nums;
        box-shadow: 0 8px 28px rgba(0, 0, 0, .45);
      }

      .dot {
        width: 8px;
        height: 8px;
        border-radius: 50%;
        background: #ff9f0a;
        box-shadow: 0 0 10px currentColor;
        color: #ff9f0a;
        flex: none;
      }
      .dot.live { background: #30d158; color: #30d158; }
      .dot.down { background: #ff453a; color: #ff453a; animation: none; }

      .metric { display: flex; align-items: baseline; gap: 5px; white-space: nowrap; }
      .metric b { font-weight: 600; font-size: 13px; }
      .metric span { font-size: 10px; letter-spacing: .06em; text-transform: uppercase; color: rgba(245,245,247,.45); }
      .sep { width: 1px; height: 16px; background: rgba(255,255,255,.12); }

      #actions {
        top: max(12px, env(safe-area-inset-top));
        right: max(12px, env(safe-area-inset-right));
        display: flex;
        gap: 8px;
      }

      button {
        width: 38px;
        height: 38px;
        display: grid;
        place-items: center;
        border: 1px solid rgba(255,255,255,.09);
        border-radius: 12px;
        background: rgba(22,22,24,.72);
        backdrop-filter: blur(20px) saturate(180%);
        -webkit-backdrop-filter: blur(20px) saturate(180%);
        color: #f5f5f7;
        cursor: pointer;
        transition: background .15s ease, transform .1s ease;
      }
      button:hover { background: rgba(48,48,52,.85); }
      button:active { transform: scale(.94); }
      button svg { width: 17px; height: 17px; fill: none; stroke: currentColor; stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }

      /* Connection state ----------------------------------------------- */

      #splash {
        position: absolute;
        inset: 0;
        z-index: 20;
        display: grid;
        place-items: center;
        background: #000;
        transition: opacity .4s ease;
      }
      #splash.gone { opacity: 0; pointer-events: none; }

      .panel { text-align: center; max-width: 340px; padding: 24px; }

      .spinner {
        width: 34px;
        height: 34px;
        margin: 0 auto 20px;
        border: 2.5px solid rgba(255,255,255,.14);
        border-top-color: #f5f5f7;
        border-radius: 50%;
        animation: spin .8s linear infinite;
      }
      @keyframes spin { to { transform: rotate(360deg); } }

      .panel h1 { font-size: 16px; font-weight: 600; letter-spacing: -.01em; }
      .panel p { margin-top: 7px; font-size: 12.5px; color: rgba(245,245,247,.5); }

      .offline .spinner { border-top-color: #ff453a; animation-duration: 1.6s; }

      #tip {
        position: absolute;
        z-index: 30;
        left: max(12px, env(safe-area-inset-left));
        right: max(12px, env(safe-area-inset-right));
        top: max(12px, env(safe-area-inset-top));
        display: flex;
        align-items: flex-start;
        gap: 10px;
        padding: 11px 13px;
        border-radius: 14px;
        background: rgba(22, 22, 24, .82);
        border: 1px solid rgba(255, 255, 255, .09);
        backdrop-filter: blur(20px) saturate(180%);
        -webkit-backdrop-filter: blur(20px) saturate(180%);
        font-size: 12.5px;
        line-height: 1.4;
        box-shadow: 0 8px 28px rgba(0, 0, 0, .5);
      }
      #tip b { font-weight: 600; }
      #tip button {
        width: 24px;
        height: 24px;
        flex: none;
        border: 0;
        border-radius: 8px;
        background: rgba(255, 255, 255, .08);
        color: #f5f5f7;
        font-size: 11px;
      }

      /* Remote control -------------------------------------------------- */

      button.on { background: rgba(10, 132, 255, .85); border-color: rgba(10, 132, 255, .9); }
      button.on:hover { background: rgba(10, 132, 255, 1); }
      #stage.controlling { cursor: default; }
      #stage.controlling.idle { cursor: none; }

      #pinPanel {
        position: absolute;
        inset: 0;
        z-index: 40;
        display: grid;
        place-items: center;
        background: rgba(0, 0, 0, .45);
      }
      #pinForm {
        width: min(300px, calc(100% - 32px));
        padding: 18px;
        border-radius: 16px;
        background: rgba(28, 28, 30, .96);
        border: 1px solid rgba(255, 255, 255, .1);
        box-shadow: 0 16px 40px rgba(0, 0, 0, .6);
        text-align: center;
      }
      #pinForm h2 { font-size: 15px; font-weight: 600; }
      #pinForm p { margin-top: 4px; font-size: 12px; color: rgba(245, 245, 247, .55); }
      #pinInput {
        width: 100%;
        margin-top: 14px;
        padding: 10px;
        border-radius: 10px;
        border: 1px solid rgba(255, 255, 255, .15);
        background: rgba(255, 255, 255, .06);
        color: #f5f5f7;
        font: 600 22px/1 ui-monospace, SFMono-Regular, Menlo, monospace;
        letter-spacing: .3em;
        text-align: center;
        -webkit-user-select: text;
        user-select: text;
      }
      #pinError { min-height: 16px; margin-top: 6px; font-size: 12px; color: #ff453a; }
      .pinButtons { display: flex; gap: 8px; margin-top: 8px; }
      .pinButtons button { flex: 1; width: auto; height: 36px; font: inherit; font-weight: 600; }
      .pinButtons button[type=submit] { background: rgba(10, 132, 255, .9); }

      #toast {
        position: absolute;
        z-index: 35;
        left: 50%;
        top: max(60px, calc(env(safe-area-inset-top) + 56px));
        transform: translateX(-50%);
        max-width: calc(100% - 32px);
        padding: 9px 14px;
        border-radius: 12px;
        background: rgba(22, 22, 24, .9);
        border: 1px solid rgba(255, 255, 255, .09);
        font-size: 12.5px;
        text-align: center;
        pointer-events: none;
      }

      /* Receives phone-keyboard input; kept on screen (iOS won't focus a
         field that isn't) but invisible. 16px stops iOS zooming into it. */
      #typer {
        position: absolute;
        left: 0;
        bottom: 0;
        width: 1px;
        height: 1px;
        opacity: 0;
        font-size: 16px;
        border: 0;
        padding: 0;
        resize: none;
      }

      /* Phones ---------------------------------------------------------- */

      /* Side by side, the readout and the buttons do not fit a phone. Move
         the readout to the bottom, where it has the full width to itself. */
      @media (max-width: 640px) {
        #hud {
          top: auto;
          left: 50%;
          bottom: max(12px, env(safe-area-inset-bottom));
          transform: translateX(-50%);
          max-width: calc(100% - 24px);
          gap: 9px;
          padding: 7px 12px;
        }
        .metric b { font-size: 12px; }
        .metric span { font-size: 9px; }
        .sep { height: 14px; }
      }

      @media (max-width: 430px) {
        .sizeMetric { display: none; }
      }
    </style>
    </head>
    <body>

    <div id="app">
    <div id="stage"><canvas id="screen"></canvas><div id="cursor"></div></div>

    <div id="hud" class="chrome">
      <i class="dot" id="dot"></i>
      <div class="metric sizeMetric"><b id="mRes">—</b><span>size</span></div>
      <div class="sep sizeMetric"></div>
      <div class="metric"><b id="mCodec">—</b><span>codec</span></div>
      <div class="sep"></div>
      <div class="metric"><b id="mFps">0</b><span>fps</span></div>
      <div class="sep"></div>
      <div class="metric"><b id="mRate">0</b><span>mbps</span></div>
      <div class="sep"></div>
      <div class="metric"><b id="mLat">—</b><span>ms</span></div>
      <div class="sep zoomOnly hidden"></div>
      <div class="metric zoomOnly hidden"><b id="mZoom">100</b><span>zoom</span></div>
    </div>

    <div id="actions" class="chrome">
      <button id="btnFit" class="hidden" title="Fit to screen (0)">
        <svg viewBox="0 0 24 24"><path d="M9 4H4v5M15 4h5v5M9 20H4v-5M15 20h5v-5"/></svg>
      </button>
      <button id="btnKeyboard" class="hidden" title="Keyboard">
        <svg viewBox="0 0 24 24"><rect x="2.5" y="6" width="19" height="12" rx="2"/><path d="M6 10h.01M10 10h.01M14 10h.01M18 10h.01M7 14h10"/></svg>
      </button>
      <button id="btnControl" class="hidden" title="Control the Mac">
        <svg viewBox="0 0 24 24"><path d="M5 3.5 18.5 10l-5.8 1.9L10 18z"/><path d="m12.7 11.9 4.8 4.8"/></svg>
      </button>
      <button id="btnHud" title="Toggle overlay (H)">
        <svg viewBox="0 0 24 24"><path d="M3 12s3.5-6.5 9-6.5S21 12 21 12s-3.5 6.5-9 6.5S3 12 3 12Z"/><circle cx="12" cy="12" r="2.6"/></svg>
      </button>
      <button id="btnReload" title="Reload page">
        <svg viewBox="0 0 24 24"><path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/></svg>
      </button>
      <button id="btnFull" title="Fullscreen (F)">
        <svg viewBox="0 0 24 24"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5"/></svg>
      </button>
    </div>

    <div id="tip" class="hidden">
      <span>Safari keeps its toolbars over the picture. For the whole screen: <b>Share</b> &rarr; <b>Add to Home Screen</b>, then open it from the icon.</span>
      <button id="tipClose" aria-label="Dismiss">&#10005;</button>
    </div>

    <div id="pinPanel" class="hidden">
      <form id="pinForm" autocomplete="off">
        <h2>Control the Mac</h2>
        <p>Enter the PIN shown in the app on the Mac.</p>
        <input id="pinInput" inputmode="numeric" autocomplete="one-time-code" maxlength="12" aria-label="PIN">
        <div id="pinError"></div>
        <div class="pinButtons">
          <button type="button" id="pinCancel">Cancel</button>
          <button type="submit">Control</button>
        </div>
      </form>
    </div>

    <div id="toast" class="hidden"></div>
    <textarea id="typer" autocapitalize="off" autocomplete="off" autocorrect="off" spellcheck="false" aria-hidden="true"></textarea>

    <div id="splash">
      <div class="panel">
        <div class="spinner"></div>
        <h1 id="splashTitle">Connecting</h1>
        <p id="splashText">Waiting for the virtual display</p>
      </div>
    </div>

    </div>

    <script>
    (() => {
      'use strict';

      const $ = (id) => document.getElementById(id);
      const app = $('app'), stage = $('stage'), canvas = $('screen'), splash = $('splash');

      // Whatever currently shows the picture: the canvas, or a <video> while
      // H.264 plays through Media Source Extensions.
      let surface = canvas;
      const dot = $('dot'), hud = $('hud'), actions = $('actions');

      // The canvas holds the last known state of the screen and tiles are
      // painted over it, so it must persist between frames. 'desynchronized'
      // lets the browser skip a compositor round trip, which is worth a frame
      // of latency on its own.
      const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });

      const params = new URLSearchParams(location.search);
      const pageVersion = '__PAGE_VERSION__';
      let chromeVisible = params.get('hud') !== '0';

      // ---- Viewport --------------------------------------------------

      // window.innerHeight includes the area behind mobile browser toolbars,
      // so the picture ends up centred against a box taller than the screen
      // and slides out of view. visualViewport is what is actually visible.
      function viewport() {
        const vv = window.visualViewport;
        return vv
          ? { w: Math.round(vv.width), h: Math.round(vv.height) }
          : { w: window.innerWidth, h: window.innerHeight };
      }

      function sizeToViewport() {
        const vv = window.visualViewport;
        const { w, h } = viewport();
        app.style.width = w + 'px';
        app.style.height = h + 'px';
        // A fixed element sits against the layout viewport, which drifts from
        // the visible one while pinching or with a keyboard open.
        app.style.transform = vv && (vv.offsetLeft || vv.offsetTop)
          ? 'translate(' + vv.offsetLeft + 'px,' + vv.offsetTop + 'px)'
          : 'none';
      }

      // ---- Zoom & pan ------------------------------------------------

      // The canvas is laid out at its natural pixel size and moved with a
      // transform, so panning and zooming never touch the decode path.
      const view = { scale: 1, x: 0, y: 0 };
      let fitScale = 1;

      const maxScale = () => Math.max(fitScale * 8, 4);
      const isZoomed = () => view.scale > fitScale * 1.02;

      function sizeCanvas() {
        // Resizing a canvas clears it, so only when the stream size changes.
        if (canvas.width !== screenSize.w || canvas.height !== screenSize.h) {
          canvas.width = screenSize.w;
          canvas.height = screenSize.h;
        }
        const width = screenSize.w + 'px', height = screenSize.h + 'px';
        if (surface.style.width === width && surface.style.height === height) return;
        surface.style.width = width;
        surface.style.height = height;
        fitToScreen();
      }

      function fitToScreen() {
        const { w, h } = viewport();
        fitScale = Math.min(w / screenSize.w, h / screenSize.h) || 1;
        view.scale = fitScale;
        applyView();
      }

      function applyView() {
        const { w, h } = viewport();
        const width = screenSize.w * view.scale;
        const height = screenSize.h * view.scale;

        // Centre whichever axis fits; otherwise keep the picture's edges from
        // being dragged inside the frame.
        view.x = width <= w ? (w - width) / 2 : Math.min(0, Math.max(w - width, view.x));
        view.y = height <= h ? (h - height) / 2 : Math.min(0, Math.max(h - height, view.y));

        surface.style.transform =
          'translate3d(' + view.x + 'px,' + view.y + 'px,0) scale(' + view.scale + ')';

        // Past 1:1 the pixels are real information, not something to blur over.
        surface.style.imageRendering = view.scale > 1.05 ? 'pixelated' : 'auto';

        placeCursor();

        const zoomed = isZoomed();
        stage.classList.toggle('pannable', zoomed);
        $('btnFit').classList.toggle('hidden', !zoomed);
        document.querySelectorAll('.zoomOnly').forEach((el) => el.classList.toggle('hidden', !zoomed));
        $('mZoom').textContent = Math.round(view.scale / fitScale * 100);
      }

      // ---- Cursor ----------------------------------------------------

      // Positions arrive in stream pixels, far more often than frames do.
      // Only the newest matters, applied once per display refresh.
      const pointer = { x: 0, y: 0, visible: false, shape: null, frame: 0, trail: [], offset: null };

      // Samples are stamped with the Mac's clock. Drawing each as it arrives
      // would move the pointer one sample in some refreshes and three in
      // others; instead it is drawn where it was this long ago, interpolated
      // between the samples either side — smooth at the cost of a few ms.
      const cursorDelay = 30;

      // Drawn to scale the pointer can shrink to a few pixels on a phone,
      // where the whole desktop is squeezed into the width of a hand. Never
      // let it get smaller than this, in CSS pixels.
      const minimumCursorHeight = 18;
      const cursorEl = $('cursor');

      function moveCursor(text) {
        if (text.length === 1) {
          pointer.visible = false;
          pointer.trail = [];
          placeCursor();
          return;
        }

        const [x, y, t] = text.slice(1).split(',').map(Number);
        const trail = pointer.trail;
        trail.push({ t, x, y });
        if (trail.length > 64) trail.splice(0, trail.length - 64);

        // The least delayed sample shows the clock difference best; creep
        // upwards slowly so drift between the two clocks is followed too.
        const offset = performance.now() - t;
        pointer.offset = pointer.offset === null || offset < pointer.offset
          ? offset
          : pointer.offset + (offset - pointer.offset) * 0.002;

        pointer.visible = true;
        if (!pointer.frame) pointer.frame = requestAnimationFrame(animateCursor);
      }

      function animateCursor(now) {
        pointer.frame = 0;
        const trail = pointer.trail;
        if (!trail.length) return;

        const target = now - pointer.offset - cursorDelay;
        const last = trail[trail.length - 1];
        let settled = false;

        if (!(target < last.t)) {
          // Caught up (or no timestamps): rest on the newest sample.
          pointer.x = last.x;
          pointer.y = last.y;
          settled = true;
        } else {
          let i = trail.length - 1;
          while (i > 0 && trail[i - 1].t > target) i--;
          if (i === 0) {
            pointer.x = trail[0].x;
            pointer.y = trail[0].y;
          } else {
            const a = trail[i - 1], b = trail[i];
            const f = (target - a.t) / ((b.t - a.t) || 1);
            pointer.x = a.x + (b.x - a.x) * f;
            pointer.y = a.y + (b.y - a.y) * f;
          }
        }

        placeCursor();
        if (!settled) pointer.frame = requestAnimationFrame(animateCursor);
      }

      function setCursorShape(message) {
        pointer.shape = { w: message.width, h: message.height, hotX: message.hotX, hotY: message.hotY };
        cursorEl.style.backgroundImage = 'url("' + message.image + '")';
        cursorEl.style.width = message.width + 'px';
        cursorEl.style.height = message.height + 'px';
        placeCursor();
      }

      function placeCursor() {
        if (!pointer.visible || !pointer.shape) {
          cursorEl.style.display = 'none';
          return;
        }
        // The tip follows the picture's mapping (stream pixel -> view.scale +
        // offset); the image itself may be drawn larger, about its hot spot.
        const size = Math.max(view.scale, minimumCursorHeight / pointer.shape.h);
        const x = view.x + pointer.x * view.scale - pointer.shape.hotX * size;
        const y = view.y + pointer.y * view.scale - pointer.shape.hotY * size;
        cursorEl.style.transform = 'translate3d(' + x + 'px,' + y + 'px,0) scale(' + size + ')';
        cursorEl.style.display = 'block';
      }

      /// Zooms about a point in client coordinates, so whatever is under the
      /// pointer or the pinch stays under it.
      function zoomAt(clientX, clientY, factor) {
        const rect = stage.getBoundingClientRect();
        const px = clientX - rect.left, py = clientY - rect.top;

        const next = Math.min(Math.max(view.scale * factor, fitScale), maxScale());
        const applied = next / view.scale;

        view.x = px - (px - view.x) * applied;
        view.y = py - (py - view.y) * applied;
        view.scale = next;
        applyView();
      }

      const pointers = new Map();
      let pinch = null;

      stage.addEventListener('pointerdown', (event) => {
        if (controlPointer(event)) return;
        // Some browsers only start a video after a gesture, muted or not.
        if (mse.video && mse.video.paused) mse.video.play().catch(() => {});
        // Capture keeps a drag alive past the edge of the element, but throws
        // for a pointer the browser no longer considers active.
        try { stage.setPointerCapture(event.pointerId); } catch (_) {}
        pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
        pinch = null;
        if (isZoomed()) stage.classList.add('panning');
      });

      stage.addEventListener('pointermove', (event) => {
        if (controlPointer(event)) return;
        const previous = pointers.get(event.pointerId);
        if (!previous) return;
        pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });

        const points = [...pointers.values()];

        if (points.length === 1) {
          view.x += event.clientX - previous.x;
          view.y += event.clientY - previous.y;
          applyView();
          return;
        }

        const [a, b] = points;
        const spread = Math.hypot(a.x - b.x, a.y - b.y);
        const midX = (a.x + b.x) / 2, midY = (a.y + b.y) / 2;

        if (pinch) {
          if (pinch.spread > 0) zoomAt(midX, midY, spread / pinch.spread);
          view.x += midX - pinch.midX;
          view.y += midY - pinch.midY;
          applyView();
        }
        pinch = { spread, midX, midY };
      });

      function releasePointer(event) {
        pointers.delete(event.pointerId);
        if (controlPointer(event)) return;
        if (pointers.size < 2) pinch = null;
        if (pointers.size === 0) stage.classList.remove('panning');
      }
      stage.addEventListener('pointerup', releasePointer);
      stage.addEventListener('pointercancel', releasePointer);

      stage.addEventListener('wheel', (event) => {
        if (controlWheel(event)) return;
        event.preventDefault();
        // Trackpad pinch arrives as ctrl+wheel with much smaller deltas.
        const rate = event.ctrlKey ? 0.01 : 0.0025;
        zoomAt(event.clientX, event.clientY, Math.exp(-event.deltaY * rate));
      }, { passive: false });

      stage.addEventListener('dblclick', (event) => {
        if (isActive()) return;
        const target = isZoomed() ? fitScale : fitScale * 2.5;
        zoomAt(event.clientX, event.clientY, target / view.scale);
      });

      // The Mac shows its own menu on right click.
      stage.addEventListener('contextmenu', (event) => { if (isActive()) event.preventDefault(); });

      // Safari fires these for pinches and would zoom the page itself.
      ['gesturestart', 'gesturechange', 'gestureend'].forEach((name) =>
        stage.addEventListener(name, (event) => event.preventDefault()));

      function onViewportChange() {
        sizeToViewport();
        const { w, h } = viewport();
        const wasFitted = !isZoomed();
        fitScale = Math.min(w / screenSize.w, h / screenSize.h) || 1;
        if (wasFitted || view.scale < fitScale) view.scale = fitScale;
        applyView();
      }

      window.addEventListener('resize', onViewportChange);
      window.addEventListener('load', onViewportChange);
      window.addEventListener('pageshow', onViewportChange);
      window.addEventListener('orientationchange', () => {
        // Safari still reports the old size at this point.
        onViewportChange();
        setTimeout(onViewportChange, 120);
        setTimeout(onViewportChange, 400);
      });
      if (window.visualViewport) {
        visualViewport.addEventListener('resize', onViewportChange);
        visualViewport.addEventListener('scroll', onViewportChange);
      }

      // ---- Stats -----------------------------------------------------

      let frames = 0, bytes = 0, latency = null, lastFrameAt = 0;

      setInterval(() => {
        $('mFps').textContent = frames;
        $('mRate').textContent = (bytes * 8 / 1e6).toFixed(1);
        $('mLat').textContent = latency === null ? '—' : Math.round(latency);
        frames = 0;
        bytes = 0;
      }, 1000);

      // ---- Rendering -------------------------------------------------

      let screenSize = { w: 1280, h: 720 }, streamFps = 30;
      let renderer = null, session = 0, paintLoop = 0;

      // Frames arrive evenly but finish decoding unevenly, and the screen
      // refreshes on its own beat. Painting each frame at the first refresh
      // after it decodes lets a millisecond of jitter choose between two
      // refreshes — one frame held for three, the next for one — which reads
      // as stutter even at a full frame rate. Instead every frame gets a due
      // time on a smoothed copy of the arrival timeline, a little later than
      // decoding usually takes, and is painted at the first refresh after it.
      const pacing = {
        clock: null, interval: 1000 / 30, lastArrival: null, budget: 10, lastDue: 0,

        reset(fps) {
          this.clock = null;
          this.lastArrival = null;
          this.interval = 1000 / fps;
          this.lastDue = 0;
        },

        due(arrival) {
          const interval = this.interval;
          if (this.lastArrival !== null) {
            const gap = arrival - this.lastArrival;
            // Only a steady stream teaches the rate; pauses and bursts don't.
            if (gap > interval * 0.5 && gap < interval * 1.5) this.interval += (gap - interval) * 0.05;
          }
          this.lastArrival = arrival;

          // Follow arrivals loosely, but start over when one is a whole frame
          // off the beat — after a still spell (nothing is sent) or a stall.
          const expected = this.clock === null ? arrival : this.clock + interval;
          this.clock = Math.abs(arrival - expected) > interval ? arrival : expected + (arrival - expected) * 0.1;

          const due = Math.max(this.clock + this.budget, this.lastDue);
          this.lastDue = due;
          return due;
        },

        /// How long a frame took to decode. The budget rises quickly and
        /// falls slowly, so one fast frame doesn't make the next one late.
        decoded(took) {
          const target = Math.min(took * 1.25 + 3, 80);
          this.budget += (target - this.budget) * (target > this.budget ? 0.3 : 0.02);
        }
      };

      /// A frame is painted once it is due — or at once if its due time is
      /// implausibly far off, so a bad estimate can never freeze the picture.
      const isDue = (due, now) => due <= now || due - now > 250;

      // Runs on the display's own refresh while frames are waiting, and puts
      // every tile of a frame on screen at once — never half a frame.
      function schedulePaint() {
        if (!paintLoop) paintLoop = requestAnimationFrame(paint);
        // Hidden tabs get no animation frames; don't let bitmaps pile up.
        setTimeout(() => { if (document.hidden) paint(performance.now(), true); }, 100);
      }

      function paint(now, force) {
        if (!force) paintLoop = 0;
        if (!renderer) return;
        if (renderer.paint(now, !!force)) markLive();
        if (renderer.pending() && !paintLoop) paintLoop = requestAnimationFrame(paint);
      }

      function markLive() {
        lastFrameAt = performance.now();
        if (!splash.classList.contains('gone')) {
          splash.classList.add('gone');
          dot.className = 'dot live';
        }
      }

      /// Swaps the element that shows the picture. Zoom and pan follow
      /// whichever it is, so the rest of the page never needs to know.
      function showSurface(element) {
        if (surface === element) return;
        surface.style.display = 'none';
        element.style.display = 'block';
        surface = element;
        sizeCanvas();
        applyView();
      }

      // JPEG tiles ------------------------------------------------------

      // Every tile starts decoding the moment it arrives, so a frame never
      // waits behind the previous one's decode. Frames still land in order —
      // tiles build on each other — because each joins the end of `chain`.
      const tiles = {
        chain: Promise.resolve(),
        ready: [],

        present(buffer, arrival) {
          // Table: tile count, then per tile x, y, width, height (uint16) and
          // JPEG length (uint32), big-endian. The JPEGs follow in table order.
          const header = new DataView(buffer);
          const count = header.getUint8(0);
          let offset = 1 + count * 12;
          const parts = [];

          for (let i = 0; i < count; i++) {
            const entry = 1 + i * 12;
            const length = header.getUint32(entry + 8);
            parts.push({
              x: header.getUint16(entry),
              y: header.getUint16(entry + 2),
              bitmap: createImageBitmap(new Blob([new Uint8Array(buffer, offset, length)])).catch(() => null)
            });
            offset += length;
          }

          const owner = session;
          const due = pacing.due(arrival);
          const decoded = Promise.all(parts.map((part) => part.bitmap));

          this.chain = this.chain.then(() => decoded).then((bitmaps) => {
            if (owner !== session) { bitmaps.forEach((b) => b && b.close()); return; }
            pacing.decoded(performance.now() - arrival);
            this.ready.push({ parts, bitmaps, due });
            frames++;
            // Decoded is ready enough: the server may send the next frame
            // while this one waits for the display's refresh.
            ack();
            schedulePaint();
          });
        },

        paint(now, force) {
          let painted = false;
          // In order: each frame's tiles build on the one before.
          while (this.ready.length && (force || isDue(this.ready[0].due, now))) {
            const frame = this.ready.shift();
            if (!painted) sizeCanvas();
            frame.parts.forEach((part, i) => {
              const bitmap = frame.bitmaps[i];
              if (!bitmap) return;
              ctx.drawImage(bitmap, part.x, part.y);
              bitmap.close();
            });
            painted = true;
          }
          return painted;
        },

        pending() { return this.ready.length > 0; },

        reset() {
          this.chain = Promise.resolve();
          this.ready.forEach((frame) => frame.bitmaps.forEach((b) => b && b.close()));
          this.ready = [];
        }
      };

      // H.264 -----------------------------------------------------------

      // Header: flags (1 = keyframe, 2 = config follows), timestamp in ms
      // (uint32), then on keyframes the avcC record behind a uint16 length.
      function parseVideo(buffer) {
        const view = new DataView(buffer);
        const flags = view.getUint8(0);
        let offset = 5, config = null;
        if (flags & 2) {
          const length = view.getUint16(5);
          config = new Uint8Array(buffer.slice(7, 7 + length));
          offset = 7 + length;
        }
        return { key: !!(flags & 1), time: view.getUint32(1), config, data: new Uint8Array(buffer, offset) };
      }

      /// 'avc1.PPCCLL' — profile, constraints and level straight from avcC.
      function avcCodec(config) {
        return 'avc1.' + [1, 2, 3].map((i) => config[i].toString(16).padStart(2, '0')).join('');
      }

      function sameBytes(a, b) {
        if (!a || !b || a.length !== b.length) return false;
        for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
        return true;
      }

      // WebCodecs: hardware decode straight to a VideoFrame, drawn on the
      // canvas. Lowest latency, but browsers only offer it on HTTPS or
      // localhost.
      const webcodecs = {
        decoder: null, config: null, queue: [], timing: new Map(), waitingForKey: true, outstanding: 0,

        present(buffer, arrival) {
          const frame = parseVideo(buffer);
          if (frame.config && !sameBytes(frame.config, this.config)) this.configure(frame.config);
          if (!this.decoder || (this.waitingForKey && !frame.key)) { ack(); return; }
          this.waitingForKey = false;
          // The decoder hands pictures back by timestamp; that's how each
          // finds its arrival and due time again.
          if (this.timing.size > 120) this.timing.clear();
          this.timing.set(frame.time * 1000, { arrival, due: pacing.due(arrival) });
          try {
            this.decoder.decode(new EncodedVideoChunk({
              type: frame.key ? 'key' : 'delta', timestamp: frame.time * 1000, data: frame.data
            }));
            this.outstanding++;
          } catch (_) {
            ack();
            this.fail();
          }
        },

        configure(config) {
          this.reset();
          const owner = session;
          try {
            this.decoder = new VideoDecoder({
              output: (picture) => {
                this.outstanding = Math.max(0, this.outstanding - 1);
                if (owner !== session) { picture.close(); return; }
                const timing = this.timing.get(picture.timestamp);
                this.timing.delete(picture.timestamp);
                if (timing) pacing.decoded(performance.now() - timing.arrival);
                this.queue.push({ picture, due: timing ? timing.due : 0 });
                frames++;
                ack();
                schedulePaint();
              },
              error: () => this.fail()
            });
            this.decoder.configure({ codec: avcCodec(config), description: config, optimizeForLatency: true });
            this.config = config;
          } catch (_) {
            fallBack();
          }
        },

        paint(now, force) {
          // Every picture is complete on its own: of those due, only the
          // newest needs drawing.
          let chosen = null;
          while (this.queue.length && (force || isDue(this.queue[0].due, now))) {
            if (chosen) chosen.picture.close();
            chosen = this.queue.shift();
          }
          if (!chosen) return false;
          sizeCanvas();
          ctx.drawImage(chosen.picture, 0, 0, screenSize.w, screenSize.h);
          chosen.picture.close();
          return true;
        },

        pending() { return this.queue.length > 0; },

        fail() {
          this.reset();
          requestKeyframe();
        },

        reset() {
          if (this.decoder && this.decoder.state !== 'closed') {
            try { this.decoder.close(); } catch (_) {}
          }
          // Frames the decoder swallowed will never be rendered; release
          // them so the server's in-flight window doesn't stall.
          for (; this.outstanding > 0; this.outstanding--) ack();
          this.decoder = null;
          this.config = null;
          this.waitingForKey = true;
          this.queue.forEach((entry) => entry.picture.close());
          this.queue = [];
          this.timing.clear();
        }
      };

      // Media Source Extensions: works over plain HTTP, which is how a
      // phone on the same Wi-Fi opens this page. Each frame is wrapped as a
      // one-sample fragmented MP4 and played by a <video> element.
      const MP4 = (() => {
        const ascii = (text) => Uint8Array.from(text, (c) => c.charCodeAt(0));
        const bytes = (...values) => new Uint8Array(values);
        const u16 = (v) => bytes(v >>> 8 & 255, v & 255);
        const u32 = (v) => bytes(v >>> 24 & 255, v >>> 16 & 255, v >>> 8 & 255, v & 255);
        const zeros = (n) => new Uint8Array(n);
        const matrix = bytes(0,1,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 0,1,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0, 64,0,0,0);
        const timescale = 1000;

        function concat(parts) {
          const out = new Uint8Array(parts.reduce((sum, part) => sum + part.byteLength, 0));
          let offset = 0;
          for (const part of parts) { out.set(part, offset); offset += part.byteLength; }
          return out;
        }

        function box(type, ...parts) {
          const body = concat(parts);
          return concat([u32(body.byteLength + 8), ascii(type), body]);
        }

        const fullBox = (type, version, flags, ...parts) =>
          box(type, bytes(version, flags >>> 16 & 255, flags >>> 8 & 255, flags & 255), ...parts);

        function init(avcc, width, height) {
          const avc1 = box('avc1', zeros(6), u16(1), zeros(16), u16(width), u16(height),
            u32(0x480000), u32(0x480000), u32(0), u16(1), zeros(32), u16(0x18), u16(0xffff),
            box('avcC', avcc));
          const stbl = box('stbl',
            fullBox('stsd', 0, 0, u32(1), avc1),
            fullBox('stts', 0, 0, u32(0)),
            fullBox('stsc', 0, 0, u32(0)),
            fullBox('stsz', 0, 0, u32(0), u32(0)),
            fullBox('stco', 0, 0, u32(0)));
          const minf = box('minf',
            fullBox('vmhd', 0, 1, zeros(8)),
            box('dinf', fullBox('dref', 0, 0, u32(1), fullBox('url ', 0, 1))),
            stbl);
          const mdia = box('mdia',
            fullBox('mdhd', 0, 0, u32(0), u32(0), u32(timescale), u32(0), u16(0x55c4), u16(0)),
            fullBox('hdlr', 0, 0, u32(0), ascii('vide'), zeros(12), ascii('VideoHandler'), zeros(1)),
            minf);
          const trak = box('trak',
            fullBox('tkhd', 0, 3, u32(0), u32(0), u32(1), u32(0), u32(0), zeros(8),
              u16(0), u16(0), u16(0), u16(0), matrix, u32(width * 65536), u32(height * 65536)),
            mdia);
          const moov = box('moov',
            fullBox('mvhd', 0, 0, u32(0), u32(0), u32(timescale), u32(0),
              u32(0x10000), u16(0x100), zeros(10), matrix, zeros(24), u32(2)),
            trak,
            box('mvex', fullBox('trex', 0, 0, u32(1), u32(1), u32(0), u32(0), u32(0))));
          return concat([box('ftyp', ascii('isom'), u32(512), ascii('isomiso6avc1mp41')), moov]);
        }

        function fragment(sequence, decodeTime, duration, data, key) {
          // Keyframe: depends on nothing. Otherwise: depends on others, non-sync.
          const flags = key ? 0x02000000 : 0x01010000;
          const moof = (dataOffset) => box('moof',
            fullBox('mfhd', 0, 0, u32(sequence)),
            box('traf',
              fullBox('tfhd', 0, 0x020000, u32(1)),
              fullBox('tfdt', 1, 0, u32(Math.floor(decodeTime / 4294967296)), u32(decodeTime % 4294967296)),
              fullBox('trun', 0, 0x000701, u32(1), u32(dataOffset), u32(duration), u32(data.byteLength), u32(flags))));
          return concat([moof(moof(0).byteLength + 8), box('mdat', data)]);
        }

        return { init, fragment };
      })();

      const mse = {
        video: null, source: null, buffer: null, queue: [], config: null,
        sequence: 0, decodeTime: 0, waitingForKey: true, appending: null, lastTrim: 0,

        present(buffer) {
          const frame = parseVideo(buffer);
          if (frame.config && !sameBytes(frame.config, this.config)) this.configure(frame.config);
          if (!this.source || (this.waitingForKey && !frame.key)) { ack(); return; }
          this.waitingForKey = false;

          // 'sequence' mode lays frames end to end, so each gets a nominal
          // duration; how late playback runs is steered in chase().
          const duration = Math.max(1, Math.round(1000 / streamFps));
          this.queue.push({ bytes: MP4.fragment(++this.sequence, this.decodeTime, duration, frame.data, frame.key), frame: true });
          this.decodeTime += duration;
          this.pump();
        },

        configure(config) {
          this.reset();
          const MediaSourceType = window.ManagedMediaSource || window.MediaSource;
          const video = document.createElement('video');
          video.muted = true;
          video.autoplay = true;
          video.playsInline = true;
          video.disableRemotePlayback = true;
          video.setAttribute('muted', '');
          video.setAttribute('playsinline', '');
          video.addEventListener('error', () => { if (this.video === video) fallBack(); });
          stage.appendChild(video);

          const source = new MediaSourceType();
          this.video = video;
          this.source = source;
          this.config = config;
          this.queue = [{ bytes: MP4.init(config, screenSize.w, screenSize.h), frame: false }];

          source.addEventListener('sourceopen', () => {
            if (this.source !== source) return;
            try {
              this.buffer = source.addSourceBuffer('video/mp4; codecs="' + avcCodec(config) + '"');
              this.buffer.mode = 'sequence';
            } catch (_) {
              fallBack();
              return;
            }
            this.buffer.addEventListener('updateend', () => this.updated());
            this.pump();
          }, { once: true });

          video.src = URL.createObjectURL(source);
          showSurface(video);
        },

        pump() {
          if (!this.buffer || this.buffer.updating || this.appending || !this.queue.length) return;
          this.appending = this.queue.shift();
          try {
            this.buffer.appendBuffer(this.appending.bytes);
          } catch (_) {
            // Usually a full buffer: make room and retry on the next frame.
            this.queue.unshift(this.appending);
            this.appending = null;
            this.trim(true);
          }
        },

        updated() {
          const appended = this.appending;
          this.appending = null;
          if (appended && appended.frame) {
            frames++;
            ack();
            markLive();
          }
          this.chase();
          this.trim(false);
          this.pump();
        },

        /// Keeps playback pinned to the newest frame. A video element would
        /// happily play a backlog at normal speed and fall further behind.
        chase() {
          const video = this.video, ranges = this.buffer && this.buffer.buffered;
          if (!video || !ranges || !ranges.length) return;
          const end = ranges.end(ranges.length - 1);
          const lag = end - video.currentTime;
          if (lag > 1.5 || video.currentTime < ranges.start(0)) {
            video.currentTime = Math.max(ranges.start(0), end - 0.05);
          } else {
            video.playbackRate = lag > 0.3 ? 1.5 : lag > 0.12 ? 1.15 : 1;
          }
          if (video.paused) video.play().catch(() => {});
        },

        trim(force) {
          const now = performance.now();
          if (!this.buffer || this.buffer.updating || (!force && now - this.lastTrim < 10000)) return;
          this.lastTrim = now;
          const keepFrom = this.video.currentTime - 5;
          if (keepFrom > 1) {
            try { this.buffer.remove(0, keepFrom); } catch (_) {}
          }
        },

        // The <video> element paces its own frames.
        paint() { return false; },
        pending() { return false; },

        reset() {
          for (const entry of this.queue) if (entry.frame) ack();
          if (this.appending && this.appending.frame) ack();
          if (this.video) {
            const video = this.video;
            this.video = null;
            showSurface(canvas);
            video.removeAttribute('src');
            video.load();
            video.remove();
          }
          this.source = null;
          this.buffer = null;
          this.queue = [];
          this.appending = null;
          this.config = null;
          this.sequence = 0;
          this.decodeTime = 0;
          this.waitingForKey = true;
        }
      };

      // ---- Codec -----------------------------------------------------

      const probeCodec = 'avc1.640028';

      /// H.264 decoders this browser can use, best first, then JPEG — which
      /// always works. The Mac decides the codec; this only tells it whether
      /// H.264 is an option here.
      async function supportedModes() {
        const modes = [];
        if (window.isSecureContext && 'VideoDecoder' in window) {
          try {
            const support = await VideoDecoder.isConfigSupported({ codec: probeCodec, optimizeForLatency: true });
            if (support.supported) modes.push('webcodecs');
          } catch (_) {}
        }
        const MediaSourceType = window.ManagedMediaSource || window.MediaSource;
        try {
          if (MediaSourceType && MediaSourceType.isTypeSupported('video/mp4; codecs="' + probeCodec + '"')) modes.push('mse');
        } catch (_) {}
        modes.push('jpeg');
        return modes;
      }

      let modes = ['jpeg'];
      const modeLabels = { webcodecs: 'H.264', mse: 'H.264', jpeg: 'JPEG' };

      /// This decoder doesn't work here after all: reconnect with the next.
      function fallBack() {
        if (modes.length > 1) modes.shift();
        if (socket) socket.close();
      }

      function requestKeyframe() {
        if (socket && socket.readyState === 1) socket.send('k');
      }

      // ---- Transport -------------------------------------------------

      let socket = null, retryDelay = 250, probeTimer = null;

      function ack() {
        if (socket && socket.readyState === 1) socket.send('a');
      }

      function connect() {
        const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
        const canDecodeVideo = modes[0] !== 'jpeg';
        socket = new WebSocket(scheme + '://' + location.host + '/ws' + (canDecodeVideo ? '?h264=1' : ''));
        // ArrayBuffers let the frame header be read without slicing a Blob.
        socket.binaryType = 'arraybuffer';

        socket.onopen = () => {
          retryDelay = 250;
          dot.className = 'dot';
          setSplash('Connected', 'Waiting for the first frame', false);
          clearInterval(probeTimer);
          probeTimer = setInterval(() => {
            if (socket && socket.readyState === 1) socket.send('p' + performance.now());
          }, 1000);
        };

        socket.onmessage = (event) => {
          if (typeof event.data === 'string') { handleText(event.data); return; }
          bytes += event.data.byteLength;
          if (renderer) renderer.present(event.data, performance.now());
        };

        // Nothing carries over: the server starts every viewer with a full
        // frame or a keyframe, so drop whatever the last session left.
        session++;
        renderer = null;
        pointer.visible = false;
        pointer.trail = [];
        pointer.offset = null;
        placeCursor();
        [tiles, webcodecs, mse].forEach((r) => r.reset());

        const closing = socket;
        socket.onclose = () => {
          if (socket !== closing) return;
          clearInterval(probeTimer);
          dot.className = 'dot down';
          splash.classList.remove('gone');
          splash.classList.add('offline');
          setSplash('Reconnecting', 'Lost the connection to the Mac', true);
          setTimeout(connect, retryDelay);
          retryDelay = Math.min(retryDelay * 1.6, 2000);
        };

        socket.onerror = () => socket.close();
      }

      function handleText(text) {
        if (text[0] === 'm') { moveCursor(text); return; }
        if (text[0] === 'p') {
          latency = performance.now() - parseFloat(text.slice(1));
          return;
        }
        try {
          const message = JSON.parse(text);
          if (message.type === 'cursor') { setCursorShape(message); return; }
          if (message.type === 'control') { onControlMessage(message); return; }
          if (message.type === 'meta') {
            // Served by a newer build than this page: start over with it.
            if (message.page && message.page !== pageVersion) { location.reload(); return; }
            screenSize = { w: message.width, h: message.height };
            streamFps = message.fps || 30;
            pacing.reset(streamFps);
            sizeCanvas();

            // The Mac chooses the codec; JPEG needs no decoder of ours.
            const mode = message.codec === 'h264' ? modes[0] : 'jpeg';
            renderer = { webcodecs, mse, jpeg: tiles }[mode];
            $('mCodec').textContent = modeLabels[mode];
            onControlMeta(message.control);

            $('mRes').textContent = message.width + '×' + message.height;
            document.title = 'Virtual Display · ' + message.width + '×' + message.height;
          }
        } catch (_) { /* ignore malformed control frames */ }
      }

      function setSplash(title, text, offline) {
        $('splashTitle').textContent = title;
        $('splashText').textContent = text;
        splash.classList.toggle('offline', !!offline);
      }

      // ---- Chrome / input --------------------------------------------

      let idleTimer = null;

      function wake() {
        stage.classList.remove('idle');
        clearTimeout(idleTimer);
        idleTimer = setTimeout(() => stage.classList.add('idle'), 2600);
      }

      function applyChrome() {
        hud.classList.toggle('hidden', !chromeVisible);
        actions.classList.toggle('hidden', !chromeVisible);
      }

      function toggleFullscreen() {
        if (document.fullscreenElement) { document.exitFullscreen(); return; }
        document.documentElement.requestFullscreen().then(() => {
          // In fullscreen Chrome can hand over keys it otherwise keeps for
          // itself, such as ⌘W and Escape.
          if (isActive() && navigator.keyboard && navigator.keyboard.lock) navigator.keyboard.lock().catch(() => {});
        }).catch(() => {});
      }

      ['mousemove', 'touchstart', 'keydown'].forEach((name) =>
        window.addEventListener(name, wake, { passive: true }));

      $('btnFull').addEventListener('click', toggleFullscreen);
      $('btnHud').addEventListener('click', () => { chromeVisible = !chromeVisible; applyChrome(); });
      $('btnFit').addEventListener('click', fitToScreen);
      $('btnReload').addEventListener('click', () => location.reload());

      ['keydown', 'keyup'].forEach((name) => window.addEventListener(name, controlKey));

      window.addEventListener('keydown', (event) => {
        // While controlling, keys belong to the Mac — and the PIN field.
        if (isActive() || event.target === pinInput) return;
        if (event.key === 'f' || event.key === 'F') toggleFullscreen();
        if (event.key === 'h' || event.key === 'H') { chromeVisible = !chromeVisible; applyChrome(); }
        if (event.key === '0' || event.key === 'r' || event.key === 'R') fitToScreen();
      });

      // ---- Remote control --------------------------------------------

      // Off until the Mac allows it and this viewer enters the PIN. While on,
      // the picture stops being something to pan and becomes the Mac's
      // screen: mouse, touch, scrolling and keys go to it.
      const control = {
        available: false,   // the Mac allows control at all
        granted: false,     // this connection entered the right PIN
        wanted: false,      // the viewer switched control on
        pin: '',
        pendingMove: null,
        moveFrame: 0,
        lastDown: null,     // for counting double and triple clicks
        touches: new Map(),
        gesture: null,
        lastTap: null
      };
      try { control.pin = localStorage.getItem('vdk-pin') || ''; } catch (_) {}

      const typer = $('typer'), pinPanel = $('pinPanel'), pinInput = $('pinInput');
      const typerSentinel = '​';
      const isActive = () => control.granted && control.wanted;
      const coarsePointer = window.matchMedia('(pointer: coarse)').matches;

      function sendInput(event) {
        if (isActive() && socket && socket.readyState === 1) socket.send('i' + JSON.stringify(event));
      }

      const modifierBits = (event) =>
        (event.shiftKey ? 1 : 0) | (event.ctrlKey ? 2 : 0) | (event.altKey ? 4 : 0) | (event.metaKey ? 8 : 0);

      /// Client coordinates to stream pixels. Outside the picture gives null,
      /// unless `clamp` pins it to the nearest edge (for drags that overshoot).
      function streamPoint(clientX, clientY, clamp) {
        const rect = stage.getBoundingClientRect();
        let x = (clientX - rect.left - view.x) / view.scale;
        let y = (clientY - rect.top - view.y) / view.scale;
        const inside = x >= 0 && y >= 0 && x < screenSize.w && y < screenSize.h;
        if (!inside && !clamp) return null;
        x = Math.min(Math.max(x, 0), screenSize.w - 1);
        y = Math.min(Math.max(y, 0), screenSize.h - 1);
        return { x: Math.round(x * 10) / 10, y: Math.round(y * 10) / 10 };
      }

      // Moves are many and only the latest matters: one per display refresh.
      function queueMove(point, m) {
        control.pendingMove = { t: 'move', x: point.x, y: point.y, m };
        if (!control.moveFrame) control.moveFrame = requestAnimationFrame(flushMove);
      }

      function flushMove() {
        control.moveFrame = 0;
        if (control.pendingMove) sendInput(control.pendingMove);
        control.pendingMove = null;
      }

      /// A press followed by a release, with double/triple click counting.
      function clickCount(point, button) {
        const now = performance.now(), last = control.lastDown;
        const repeat = last && last.button === button && now - last.time < 400
          && Math.hypot(point.x - last.x, point.y - last.y) < 8 / view.scale;
        const count = repeat ? Math.min(last.count + 1, 3) : 1;
        control.lastDown = { time: now, x: point.x, y: point.y, button, count };
        return count;
      }

      function press(point, button, m) {
        flushMove();
        const n = clickCount(point, button);
        sendInput({ t: 'down', b: button, x: point.x, y: point.y, n, m });
        return n;
      }

      function release(point, button, n, m) {
        flushMove();
        sendInput({ t: 'up', b: button, x: point.x, y: point.y, n, m });
      }

      function click(point, button) {
        const n = press(point, button, 0);
        release(point, button, n, 0);
      }

      // Mouse and pen: straight through --------------------------------

      const heldButtons = new Map();

      function mouseDown(event) {
        const point = streamPoint(event.clientX, event.clientY, false);
        if (!point) return;
        try { stage.setPointerCapture(event.pointerId); } catch (_) {}
        heldButtons.set(event.button, press(point, event.button, modifierBits(event)));
      }

      function mouseMove(event) {
        const point = streamPoint(event.clientX, event.clientY, heldButtons.size > 0);
        if (point) queueMove(point, modifierBits(event));
      }

      function mouseUp(event) {
        if (!heldButtons.has(event.button)) return;
        const point = streamPoint(event.clientX, event.clientY, true);
        release(point, event.button, heldButtons.get(event.button), modifierBits(event));
        heldButtons.delete(event.button);
      }

      // Touch: tap clicks, drag drags, hold right-clicks, two fingers
      // scroll — or pinch to zoom the picture, whichever they start doing.

      const touchPoint = (touch) => streamPoint(touch.x, touch.y, true);

      function touchDown(event) {
        try { stage.setPointerCapture(event.pointerId); } catch (_) {}
        control.touches.set(event.pointerId, { x: event.clientX, y: event.clientY });
        const touches = [...control.touches.values()];

        if (touches.length === 1) {
          const start = streamPoint(event.clientX, event.clientY, false);
          if (!start) { control.gesture = { mode: 'ignored' }; return; }
          const gesture = { mode: 'pending', start, startX: event.clientX, startY: event.clientY };
          gesture.holdTimer = setTimeout(() => {
            if (control.gesture !== gesture || gesture.mode !== 'pending') return;
            gesture.mode = 'done';
            click(start, 2);
            if (navigator.vibrate) navigator.vibrate(10);
          }, 550);
          control.gesture = gesture;
          return;
        }

        if (touches.length === 2) {
          endSingleTouch();
          const [a, b] = touches;
          control.gesture = {
            mode: 'two', decided: null,
            spread: Math.hypot(a.x - b.x, a.y - b.y), startSpread: Math.hypot(a.x - b.x, a.y - b.y),
            midX: (a.x + b.x) / 2, midY: (a.y + b.y) / 2,
            startMidX: (a.x + b.x) / 2, startMidY: (a.y + b.y) / 2
          };
        }
      }

      function endSingleTouch() {
        const gesture = control.gesture;
        if (!gesture) return;
        clearTimeout(gesture.holdTimer);
        if (gesture.mode === 'drag') release(gesture.last, 0, 1, 0);
        gesture.mode = 'done';
      }

      function touchMove(event) {
        if (!control.touches.has(event.pointerId)) return;
        control.touches.set(event.pointerId, { x: event.clientX, y: event.clientY });
        const gesture = control.gesture;
        if (!gesture) return;

        if (gesture.mode === 'pending' || gesture.mode === 'drag') {
          const point = streamPoint(event.clientX, event.clientY, true);
          if (gesture.mode === 'pending') {
            if (Math.hypot(event.clientX - gesture.startX, event.clientY - gesture.startY) < 10) return;
            // A drag starts where the finger went down, not where it is now.
            clearTimeout(gesture.holdTimer);
            gesture.mode = 'drag';
            queueMove(gesture.start, 0);
            press(gesture.start, 0, 0);
          }
          gesture.last = point;
          queueMove(point, 0);
          return;
        }

        if (gesture.mode !== 'two' || control.touches.size !== 2) return;
        const [a, b] = [...control.touches.values()];
        const spread = Math.hypot(a.x - b.x, a.y - b.y);
        const midX = (a.x + b.x) / 2, midY = (a.y + b.y) / 2;

        if (!gesture.decided) {
          if (Math.abs(spread - gesture.startSpread) > 24) gesture.decided = 'pinch';
          else if (Math.hypot(midX - gesture.startMidX, midY - gesture.startMidY) > 10) gesture.decided = 'scroll';
        }

        if (gesture.decided === 'pinch') {
          if (gesture.spread > 0) zoomAt(midX, midY, spread / gesture.spread);
          view.x += midX - gesture.midX;
          view.y += midY - gesture.midY;
          applyView();
        } else if (gesture.decided === 'scroll') {
          // Content follows the fingers, as it does on the phone itself.
          const at = streamPoint(midX, midY, true);
          sendInput({
            t: 'scroll', x: at.x, y: at.y,
            dx: -(midX - gesture.midX) / view.scale,
            dy: -(midY - gesture.midY) / view.scale
          });
        }
        gesture.spread = spread;
        gesture.midX = midX;
        gesture.midY = midY;
      }

      function touchUp(event) {
        if (!control.touches.delete(event.pointerId)) return;
        const gesture = control.gesture;
        if (!gesture) return;

        if (gesture.mode === 'pending' && event.type === 'pointerup') {
          clearTimeout(gesture.holdTimer);
          gesture.mode = 'done';
          click(gesture.start, 0);
        } else if (gesture.mode === 'drag') {
          endSingleTouch();
        }
        if (control.touches.size === 0) control.gesture = null;
      }

      function controlPointer(event) {
        if (!isActive()) return false;
        event.preventDefault();
        if (mse.video && mse.video.paused) mse.video.play().catch(() => {});
        const touch = event.pointerType === 'touch';
        switch (event.type) {
          case 'pointerdown': touch ? touchDown(event) : mouseDown(event); break;
          case 'pointermove': touch ? touchMove(event) : mouseMove(event); break;
          default: touch ? touchUp(event) : mouseUp(event); break;
        }
        return true;
      }

      function controlWheel(event) {
        // Trackpad pinches (ctrl+wheel) still zoom the picture.
        if (!isActive() || event.ctrlKey) return false;
        event.preventDefault();
        const point = streamPoint(event.clientX, event.clientY, false);
        if (!point) return true;
        const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? screenSize.h : 1;
        sendInput({ t: 'scroll', x: point.x, y: point.y, dx: event.deltaX * unit, dy: event.deltaY * unit, m: modifierBits(event) });
        return true;
      }

      // Keyboard -------------------------------------------------------

      /// Keys go by physical position (`code`), so shortcuts match a Mac
      /// keyboard. Text typed into the hidden field — phone keyboards, and
      /// composed input such as Vietnamese — goes as text instead.
      function controlKey(event) {
        if (!isActive() || event.target === pinInput) return false;
        const code = event.code;
        if (!code || code === 'Unidentified' || event.keyCode === 229 || event.isComposing) return event.target === typer;
        // In the text field, plain characters arrive as text (beforeinput).
        if (event.target === typer && event.key.length === 1 && !event.ctrlKey && !event.metaKey) return true;
        event.preventDefault();
        sendInput({ t: 'key', code, down: event.type === 'keydown', m: modifierBits(event) });
        return true;
      }

      function resetTyper() {
        typer.value = typerSentinel;
        try { typer.setSelectionRange(1, 1); } catch (_) {}
      }

      function pressKey(code) {
        sendInput({ t: 'key', code, down: true, m: 0 });
        sendInput({ t: 'key', code, down: false, m: 0 });
      }

      typer.addEventListener('beforeinput', (event) => {
        if (!isActive()) return;
        const type = event.inputType;
        if (type === 'insertCompositionText') return;   // still composing
        if (type.startsWith('delete')) { event.preventDefault(); pressKey(type === 'deleteContentForward' ? 'Delete' : 'Backspace'); return; }
        if (type === 'insertLineBreak' || type === 'insertParagraph') { event.preventDefault(); pressKey('Enter'); return; }
        if (type === 'insertText' || type === 'insertReplacementText' || type === 'insertFromPaste') {
          const text = event.data || (event.dataTransfer && event.dataTransfer.getData('text/plain'));
          event.preventDefault();
          if (text) sendInput({ t: 'text', text });
        }
      });

      typer.addEventListener('compositionend', (event) => {
        if (event.data) sendInput({ t: 'text', text: event.data });
        setTimeout(resetTyper, 0);
      });

      typer.addEventListener('input', () => {
        // Anything not handled above; never let the field fill up.
        if (typer.value !== typerSentinel) setTimeout(resetTyper, 0);
      });

      // Switching on, PIN, messages -------------------------------------

      function showToast(text) {
        const toast = $('toast');
        toast.textContent = text;
        toast.classList.remove('hidden');
        clearTimeout(showToast.timer);
        showToast.timer = setTimeout(() => toast.classList.add('hidden'), 3500);
      }

      function applyControlState() {
        $('btnControl').classList.toggle('hidden', !control.available);
        $('btnControl').classList.toggle('on', isActive());
        $('btnKeyboard').classList.toggle('hidden', !isActive() || !coarsePointer);
        stage.classList.toggle('controlling', isActive());
        if (!isActive()) {
          typer.blur();
          control.touches.clear();
          control.gesture = null;
          heldButtons.clear();
        }
      }

      function requestControl(pin) {
        if (socket && socket.readyState === 1) socket.send('A' + pin);
      }

      function onControlMessage(message) {
        if (message.notice === 'focus') {
          showToast('Typing goes nowhere: the active window is on another screen. Click a window here first.');
          return;
        }
        if (message.granted) {
          control.granted = true;
          control.wanted = true;
          try { localStorage.setItem('vdk-pin', control.pin); } catch (_) {}
          pinPanel.classList.add('hidden');
          showToast('Controlling the Mac');
        } else {
          control.granted = false;
          if (message.reason === 'pin') {
            try { localStorage.removeItem('vdk-pin'); } catch (_) {}
            $('pinError').textContent = 'Wrong PIN';
            pinPanel.classList.remove('hidden');
            pinInput.select();
          } else if (message.reason === 'permission') {
            control.wanted = false;
            showToast('On the Mac, allow the app in System Settings › Privacy & Security › Accessibility, then try again.');
          } else {
            control.available = false;
          }
        }
        applyControlState();
      }

      /// Called with each connection's metadata.
      function onControlMeta(available) {
        control.available = !!available;
        control.granted = false;
        // Pick up where a dropped connection left off.
        if (control.available && control.wanted && control.pin) requestControl(control.pin);
        applyControlState();
      }

      $('btnControl').addEventListener('click', () => {
        if (isActive()) {
          control.wanted = false;
          showToast('Viewing only');
        } else if (control.granted) {
          control.wanted = true;
        } else if (control.pin) {
          control.wanted = true;
          requestControl(control.pin);
        } else {
          $('pinError').textContent = '';
          pinPanel.classList.remove('hidden');
          pinInput.value = '';
          pinInput.focus();
        }
        applyControlState();
      });

      $('pinForm').addEventListener('submit', (event) => {
        event.preventDefault();
        control.pin = pinInput.value.trim();
        if (!control.pin) return;
        control.wanted = true;
        requestControl(control.pin);
      });

      $('pinCancel').addEventListener('click', () => pinPanel.classList.add('hidden'));

      $('btnKeyboard').addEventListener('click', () => {
        if (document.activeElement === typer) { typer.blur(); return; }
        resetTyper();
        typer.focus();
      });

      // On iOS only a home-screen web app gets the whole screen: Safari has no
      // fullscreen API for ordinary elements, so its toolbars stay put and eat
      // about a fifth of the display.
      const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent)
        || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
      const isStandalone = window.navigator.standalone === true
        || window.matchMedia('(display-mode: standalone)').matches;

      let tipSeen = false;
      try { tipSeen = localStorage.getItem('vdk-tip') === 'seen'; } catch (_) {}

      if (isIOS && !isStandalone && !tipSeen) {
        const tip = $('tip');
        tip.classList.remove('hidden');
        const dismiss = () => {
          tip.classList.add('hidden');
          try { localStorage.setItem('vdk-tip', 'seen'); } catch (_) {}
        };
        $('tipClose').addEventListener('click', dismiss);
        setTimeout(dismiss, 12000);
      }

      // Keep phones and tablets from sleeping while they act as a display.
      async function holdWakeLock() {
        if (!('wakeLock' in navigator)) return;
        try { await navigator.wakeLock.request('screen'); } catch (_) {}
      }
      document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') holdWakeLock();
      });

      sizeToViewport();
      fitToScreen();
      applyChrome();
      wake();
      holdWakeLock();
      supportedModes().then((found) => { modes = found; connect(); });
    })();
    </script>
    </body>
    </html>
    """#
}

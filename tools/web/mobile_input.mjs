// Browser input policy kept separate from the page so its event sequences can
// be regression-tested without a GPU. Coordinates are logical CSS pixels.
export const EVENT = { KEY_DOWN: 1, KEY_UP: 2, CHAR: 3, DOWN: 4, UP: 5,
  SCROLL: 6, NAV: 7, SCROLL_PIXELS: 8, CANCEL: 9, PREEDIT_BEGIN: 10, PREEDIT_TEXT: 11, PREEDIT_END: 12 };
const modsOf = e => (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) |
  (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0);
const navOf = { ArrowLeft: 1, ArrowRight: 2, Home: 3, End: 4,
  ArrowUp: 5, ArrowDown: 6, PageUp: 7, PageDown: 8, Delete: 9 };
const controlOf = { Backspace: 8, Tab: 9, Enter: 13, Escape: 27 };
const SENTINEL = '\u200b';

export function createInput({ canvas, editor, state, pushEvent,
  flushFrame = () => {}, document: doc = globalThis.document,
  window: win = globalThis.window }) {
  let pointer = null;
  let textActive = false;
  let composing = false;
  let justComposed = null;
  let focusId = 0;
  let discardComposition = false;
  let pointerMode = 0;
  let scrollRemainder = 0;
  const emit = (kind, code = 0, e = {}) =>
    pushEvent(kind, code, state.mouseX, state.mouseY, modsOf(e));
  const preedit = (text, end = false) => {
    pushEvent(end ? EVENT.PREEDIT_END : EVENT.PREEDIT_BEGIN, 0, focusId, 0, 0);
    if (!end) for (const char of text ?? '') {
      const cp = char.codePointAt(0);
      if (cp >= 32 && !(cp >= 0xd800 && cp <= 0xdfff))
        pushEvent(EVENT.PREEDIT_TEXT, cp, focusId, 0, 0);
    }
  };
  const move = e => {
    const r = canvas.getBoundingClientRect();
    state.mouseX = Math.round(e.clientX - r.left);
    state.mouseY = Math.round(e.clientY - r.top);
  };
  const scroll = (dy, e) => {
    scrollRemainder += dy;
    const pixels = Math.trunc(scrollRemainder);
    if (pixels) { emit(EVENT.SCROLL_PIXELS, pixels, e); scrollRemainder -= pixels; }
  };
  const resetEditor = () => {
    editor.value = SENTINEL;
    editor.setSelectionRange(1, 1);
  };
  const commit = (text, e = {}) => {
    for (const char of text ?? '') {
      const cp = char.codePointAt(0);
      if (cp === 10 || cp === 13) emit(EVENT.CHAR, 13, e);
      else if (cp >= 32 && !(cp >= 0xd800 && cp <= 0xdfff)) emit(EVENT.CHAR, cp, e);
    }
  };
  const focus = () => {
    if (textActive) {
      if (doc.activeElement !== editor) {
        resetEditor();
        editor.focus({ preventScroll: true });
      }
    } else if (doc.activeElement !== canvas) canvas.focus({ preventScroll: true });
  };
  const cancel = () => {
    if (pointer || state.mouseButtons) {
      state.mouseButtons = 0;
      emit(EVENT.CANCEL);
      pointer = null;
    }
  };
  canvas.addEventListener('pointerdown', e => {
    // One primary contact owns the mouse-compatible stream. Other fingers
    // must never release or move that contact.
    if (pointer || e.isPrimary === false) return;
    move(e);
    pointer = { id: e.pointerId, type: e.pointerType, x: e.clientX,
      y: e.clientY, lastY: e.clientY, panning: false, button: e.button };
    state.mouseButtons |= 1 << e.button;
    canvas.setPointerCapture(e.pointerId);
    emit(EVENT.DOWN, e.button + 1, e);
    // iOS requires focus within the trusted event stack. Process the W
    // click now so only a field that actually acquired focus opens the IME.
    // Touch waits until release: a swipe over a field must not open it.
    flushFrame();
    if (e.pointerType !== 'touch') focus();
    e.preventDefault();
  });
  canvas.addEventListener('pointermove', e => {
    if (!pointer) { if (e.pointerType === 'mouse') move(e); return; }
    if (pointer.id !== e.pointerId) return;
    move(e);
    if (pointer.type === 'touch' && !pointerMode) {
      if (!pointer.panning && Math.hypot(e.clientX - pointer.x, e.clientY - pointer.y) >= 8) {
        pointer.panning = true;
        state.mouseButtons = 0;
        emit(EVENT.CANCEL, 0, e);
      }
      if (pointer.panning) scroll(pointer.lastY - e.clientY, e);
      pointer.lastY = e.clientY;
    }
    e.preventDefault();
  });
  canvas.addEventListener('pointerup', e => {
    if (!pointer || pointer.id !== e.pointerId || e.button !== pointer.button) return;
    move(e);
    state.mouseButtons &= ~(1 << pointer.button);
    const panning = pointer.panning;
    if (!panning) emit(EVENT.UP, pointer.button + 1, e);
    pointer = null;
    canvas.releasePointerCapture(e.pointerId);
    flushFrame();
    if (!panning) focus();
    e.preventDefault();
  });
  canvas.addEventListener('pointercancel', e => {
    if (pointer?.id === e.pointerId) cancel();
  });
  canvas.addEventListener('lostpointercapture', e => {
    if (pointer?.id === e.pointerId) cancel();
  });
  win.addEventListener('blur', cancel);
  doc.addEventListener('visibilitychange', () => { if (doc.hidden) cancel(); });
  canvas.addEventListener('wheel', e => {
    move(e);
    const unit = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? canvas.clientHeight : 1;
    scroll(e.deltaY * unit, e);
    e.preventDefault();
  }, { passive: false });
  const keydown = e => {
    state.lastKeycode = e.keyCode;
    emit(EVENT.KEY_DOWN, e.keyCode, e);
    if (e.isComposing || composing || e.keyCode === 229) return;
    justComposed = null;
    const modified = e.ctrlKey || e.metaKey || e.altKey;
    const altGraph = e.getModifierState?.('AltGraph') || (e.ctrlKey && e.altKey && !e.metaKey);
    const nav = navOf[e.key];
    const control = controlOf[e.key];
    if (nav) emit(EVENT.NAV, nav, e);
    else if (control) emit(EVENT.CHAR, control, e);
    else if ([...e.key].length === 1 && !altGraph &&
      (e.target !== editor || e.ctrlKey || e.metaKey)) commit(e.key, e);
    // W still receives accelerator events; browser shortcuts remain available.
    // DOM input owns printable Alt/AltGr text to avoid a duplicate CHAR.
    if (!modified && (nav || control)) e.preventDefault();
  };
  for (const target of [canvas, editor]) {
    target.addEventListener('keydown', keydown);
    target.addEventListener('keyup', e => emit(EVENT.KEY_UP, e.keyCode, e));
  }
  editor.addEventListener('compositionstart', () => { composing = true; justComposed = null; discardComposition = false; preedit(''); });
  editor.addEventListener('compositionupdate', e => { if (!discardComposition) preedit(e.data); });
  editor.addEventListener('compositionend', e => {
    composing = false;
    if (!discardComposition) { preedit('', true); commit(e.data); }
    justComposed = e.data;
    resetEditor();
  });
  editor.addEventListener('beforeinput', e => {
    if (composing || e.isComposing) return;
    if (justComposed !== null && e.data === justComposed &&
      (e.inputType === 'insertFromComposition' || e.inputType === 'insertCompositionText')) {
      e.preventDefault(); resetEditor(); return;
    }
    if (e.inputType !== 'insertFromComposition' && e.inputType !== 'insertCompositionText') justComposed = null;
    if (e.inputType === 'deleteContentBackward') {
      emit(EVENT.CHAR, 8); e.preventDefault(); resetEditor();
    } else if (e.inputType === 'deleteContentForward') {
      emit(EVENT.NAV, 9); e.preventDefault(); resetEditor();
    } else if (e.inputType === 'insertLineBreak' || e.inputType === 'insertParagraph') {
      emit(EVENT.CHAR, 13); e.preventDefault(); resetEditor();
    }
  });
  editor.addEventListener('input', e => {
    if (composing || e.isComposing) return;
    const text = editor.value.startsWith(SENTINEL) ? editor.value.slice(1) : editor.value;
    // compositionend resets the sink, so its following input event has no
    // new value. Some engines reapply the committed data; suppress that too.
    if (!(justComposed !== null && text === justComposed)) commit(text);
    justComposed = null;
    resetEditor();
  });
  resetEditor();
  return {
    setPointerMode: mode => { pointerMode = mode; },
    setTextInput(active, multiline, x, y, width, height, nextFocusId = active) {
      if (composing && (!active || focusId !== nextFocusId)) {
        // Do not deliver an old field's pending preedit into a newly focused
        // field. Blur ends native composition; ignore its trailing commit.
        preedit('', true);
        discardComposition = true;
        editor.blur();
        composing = false;
        resetEditor();
      }
      focusId = nextFocusId;
      textActive = !!active;
      editor.setAttribute('aria-label', multiline ? 'W multiline text editor' : 'W text editor');
      editor.setAttribute('enterkeyhint', multiline ? 'enter' : 'done');
      const r = canvas.getBoundingClientRect();
      editor.style.left = `${Math.max(r.left, r.left + x)}px`;
      editor.style.top = `${Math.max(r.top, r.top + y)}px`;
      if (!textActive && doc.activeElement === editor) {
        editor.blur();
        canvas.focus({ preventScroll: true });
      }
    },
    cancel,
  };
}

// Size the drawing surface in CSS pixels, independently of its Retina buffer.
// Safe-area padding is measured on the wrapper by the browser; visualViewport
// accounts for the software keyboard and browser chrome without UA sniffing.
export function viewportSize({ width, height, requestedWidth, requestedHeight,
  insetLeft = 0, insetRight = 0, insetTop = 0, insetBottom = 0, dpr = 1 }) {
  const logicalWidth = Math.max(1, Math.floor(Math.min(requestedWidth, width - insetLeft - insetRight)));
  const logicalHeight = Math.max(1, Math.floor(Math.min(requestedHeight, height - insetTop - insetBottom)));
  const ratio = Math.max(1, Number.isFinite(dpr) ? dpr : 1);
  return { width: logicalWidth, height: logicalHeight,
    bufferWidth: Math.round(logicalWidth * ratio), bufferHeight: Math.round(logicalHeight * ratio), ratio };
}

// UI buffers hold 32 characters and 8 navigation events per frame. Preserve ordering and
// carry long paste/composition commits across frames instead of losing text.
export function createEventQueue() {
  const events = [];
  let head = 0;
  let chars = 0;
  let navs = 0;
  return {
    push(kind, code, x, y, mods) { events.push({ kind, code, x, y, mods }); },
    beginFrame() { chars = 0; navs = 0; },
    next() {
      if (head === events.length || (events[head].kind === EVENT.CHAR && chars >= 32) ||
        (events[head].kind === EVENT.NAV && navs >= 8)) return null;
      const next = events[head];
      if (chars && (next.kind === EVENT.DOWN || next.kind === EVENT.UP || next.kind === EVENT.NAV)) return null;
      if (navs && (next.kind === EVENT.CHAR || next.kind === EVENT.DOWN || next.kind === EVENT.UP)) return null;
      const event = events[head++];
      // Avoid shift()'s quadratic copies on large pastes while releasing
      // consumed references. Compact only after at least half is drained.
      if (head === events.length) { events.length = 0; head = 0; }
      else if (head >= 4096 && head * 2 >= events.length) {
        events.splice(0, head); head = 0;
      }
      if (event.kind === EVENT.CHAR) chars++;
      if (event.kind === EVENT.NAV) navs++;
      return event;
    },
  };
}

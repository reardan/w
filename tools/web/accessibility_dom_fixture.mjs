// Minimal DOM contract fixture shared by the bridge tests and wasm ABI runner.
// It does not emulate browser accessibility trees or screen reader behavior.
export function makeDocument() {
  const document = { activeElement: null };
  class Element {
    constructor(tag) {
      this.tagName = tag;
      this.attributes = new Map();
      this.children = [];
      this.style = {};
      this.listeners = new Map();
      this.textContent = '';
      this.value = '';
      this.selectionStart = 0;
      this.selectionEnd = 0;
      this.selectionDirection = 'none';
    }
    // Like a browser, a programmatic selection fires 'select'.
    setSelectionRange(start, end, direction = 'none') {
      this.selectionStart = start;
      this.selectionEnd = end;
      this.selectionDirection = direction;
      this.emit('select');
    }
    setAttribute(k, v) { this.attributes.set(k, String(v)); }
    getAttribute(k) { return this.attributes.get(k) ?? null; }
    removeAttribute(k) { this.attributes.delete(k); }
    appendChild(el) { this.children.push(el); el.parentNode = this; return el; }
    replaceChildren(...children) { this.children = children; for (const c of children) c.parentNode = this; }
    addEventListener(name, fn) {
      if (!this.listeners.has(name)) this.listeners.set(name, []);
      this.listeners.get(name).push(fn);
    }
    emit(name, extra = {}) {
      const event = { target: this, preventDefault() { this.prevented = true; }, ...extra };
      for (const fn of this.listeners.get(name) ?? []) fn(event);
      return event;
    }
    focus() { document.activeElement = this; this.emit('focus'); }
    blur() { if (document.activeElement === this) document.activeElement = null; }
  }
  document.createElement = tag => new Element(tag);
  return document;
}

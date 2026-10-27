import assert from 'node:assert/strict';
import { createAccessibility, makeAccessibilityEnv } from './accessibility.mjs';
import { makeDocument } from './accessibility_dom_fixture.mjs';
const document = makeDocument(), container = document.createElement('div'), canvas = document.createElement('canvas');
canvas.setAttribute('tabindex', '0');
const access = createAccessibility({ document, container, canvas });
const memory = new WebAssembly.Memory({ initial: 1 });
const env = makeAccessibilityEnv({ memory: () => memory, access });
const root = () => container.children[0].children[0];
const children = () => root().children;
const decode = e => ({ id: e.id, action: e.action, value: new TextDecoder().decode(e.data) });
const begin = () => {
  assert.equal(env.gfx_access_begin(12, 256, 7), 1);
  assert.equal(env.gfx_access_add(1, 0, 1, 0, 0, 0), 1);
  assert.equal(env.gfx_access_add(2, 1, 6, 64, 3, 0), 1);
  assert.equal(env.gfx_access_add(3, 1, 8, 64, 6, 0), 1);
  assert.equal(env.gfx_access_add(4, 1, 7, 66, 10, 0), 1);
  assert.equal(access.text(2, 1, '<img src=x onerror=fail()>'), 1);
  assert.equal(access.text(2, 3, 'Help\u0000日本'), 1);
  assert.equal(access.text(3, 2, 'a\u0000é'), 1);
};
assert.equal(access.begin(0, 256, 7), 0);
assert.equal(access.begin(100001, 256, 7), 0);
assert.equal(access.begin(1, 16777217, 7), 0);
assert.equal(access.begin(1, 256, 0), 0);
assert.equal(access.begin(1, 256, 7), 1);
assert.equal(access.commit(0), 0, 'empty publication');
assert.equal(access.begin(1, 256, 7), 1);
assert.equal(access.add(1, 0, 1, 0, 0, 0), 1);
assert.equal(access.add(2, 1, 6, 64, 3, 0), 0, 'node budget');
assert.equal(access.commit(0), 0);
begin();
assert.equal(env.gfx_access_commit(2), 1);
let [button, textbox, checkbox] = children();
assert.equal(root().getAttribute('role'), 'document');
assert.equal(button.getAttribute('role'), 'button');
assert.equal(button.getAttribute('aria-label'), '<img src=x onerror=fail()>');
assert.equal(button.children.length, 0);
assert.equal(container.children[0].children[1].textContent, 'Help\u0000日本');
assert.equal(textbox.value, 'a\u0000é');
assert.equal(textbox.readOnly, false);
assert.equal(checkbox.getAttribute('aria-checked'), 'true');
assert.equal(document.activeElement, button);
assert.equal(access.next(7, 256), null, 'programmatic focus must not echo an action');
assert.equal(canvas.getAttribute('aria-hidden'), 'true');
assert.equal(canvas.getAttribute('tabindex'), '-1');
button.emit('click');
assert.deepEqual(decode(access.next(7, 256)), { id: 2, action: 1, value: '' });
assert.equal(button.emit('keydown', { key: ' ' }).prevented, true);
assert.equal(access.next(7, 256).action, 1);
button.emit('keydown', { key: 'Enter', repeat: true });
button.emit('click', { target: textbox });
assert.equal(access.next(7, 256), null);
checkbox.emit('keydown', { key: ' ' });
assert.equal(access.next(7, 256).action, 8);
textbox.focus();
assert.equal(access.next(7, 256).action, 2);
textbox.value = '文\u0000🙂';
textbox.emit('input');
assert.equal(access.next(8, 256), null, 'different snapshot cannot drain actions');
assert.equal(env.gfx_access_next(7, 65530, 1024, 256), 0, 'header bounds');
assert.equal(env.gfx_access_next(7, 512, 65535, 256), 0, 'value bounds');
assert.equal(env.gfx_access_next(7, 512, 512, 256), 0, 'overlapping buffers');
assert.equal(env.gfx_access_next(7, 512, 1024, 1), 0, 'small buffer must preserve queued request');
memory.grow(1);
assert.equal(env.gfx_access_next(7, 512, 1024, 256), 1);
const metadata = new Int32Array(memory.buffer, 512, 3);
assert.deepEqual([...metadata], [3, 4, 8]);
assert.equal(new TextDecoder().decode(new Uint8Array(memory.buffer, 1024, 8)), '文\u0000🙂');
textbox.value = 'ignored preedit'; textbox.emit('input', { isComposing: true });
assert.equal(access.next(7, 256), null, 'composition is not committed text');
textbox.value = 'x'.repeat(257); textbox.emit('input');
assert.equal(access.next(7, 256), null, 'bounded request text');
textbox.value = 'x'.repeat(200); textbox.emit('input'); textbox.emit('input');
assert.equal(access.next(7, 256).data.length, 200);
assert.equal(access.next(7, 256), null, 'total queued bytes bounded');
textbox.emit('input'); assert.equal(access.next(7, 256).data.length, 200, 'draining restores byte budget');
for (let i = 0; i < 65; i++) button.emit('click');
for (let i = 0; i < 64; i++) assert.equal(access.next(7, 256).action, 1);
assert.equal(access.next(7, 256), null, 'bounded queue');
button.emit('click');
const old = button;
begin(); assert.equal(env.gfx_access_commit(0), 1);
old.emit('click');
assert.equal(access.next(7, 256), null, 'publish drops old queue and rejects stale DOM actions');
[button, textbox] = children();
const installed = root();
assert.equal(env.gfx_access_begin(12, 256, 8), 1);
assert.equal(env.gfx_access_add(1, 0, 1, 0, 0, 0), 1);
assert.equal(env.gfx_access_add(1, 0, 1, 0, 0, 0), 0);
assert.equal(env.gfx_access_commit(0), 0);
assert.equal(root(), installed, 'invalid publication is atomic');
button.emit('click'); assert.equal(access.next(7, 256).action, 1);
for (const invalid of [
  () => env.gfx_access_add(10, 999, 6, 0, 1, 0),
  () => env.gfx_access_add(10, 1, 99, 0, 1, 0),
  () => env.gfx_access_add(10, 1, 4, 0, 0, 0),
  () => env.gfx_access_add(10, 0, 1, 0, 0, 0),
  () => env.gfx_access_add(10, 3, 3, 0, 0, 0),
  () => env.gfx_access_add(10, 1, 6, 128, 0, 0),
  () => env.gfx_access_text(1, 1, -1, 2),
  () => env.gfx_access_text(1, 1, 0, 1),
  () => env.gfx_access_text(1, 1, memory.buffer.byteLength - 1, 2),
  () => access.text(1, 1, 'x'.repeat(257)),
]) {
  begin(); assert.equal(invalid(), 0); assert.equal(env.gfx_access_commit(0), 0); assert.equal(root(), installed);
}
begin(); assert.equal(access.commit(99), 0); assert.equal(root(), installed);
begin(); new Uint8Array(memory.buffer)[2048] = 255;
assert.equal(env.gfx_access_text(1, 1, 2048, 1), 0);
assert.equal(env.gfx_access_commit(0), 0);
begin();
const bom = new TextEncoder().encode('\ufeffname'); new Uint8Array(memory.buffer, 2048, bom.length).set(bom);
assert.equal(env.gfx_access_text(2, 1, 2048, bom.length), 1);
assert.equal(env.gfx_access_commit(0), 1);
assert.equal(children()[0].getAttribute('aria-label'), '\ufeffname', 'UTF-8 BOM is text, not a transport marker');
// Disabled/hidden ancestry, readonly values, headings, names and roles.
assert.equal(access.begin(12, 256, 9), 1);
access.add(1, 0, 1, 0, 0, 0);
access.add(2, 1, 2, 1, 0, 0);
access.add(3, 2, 6, 64, 3, 0);
access.add(4, 1, 8, 80, 6, 0);
access.add(5, 1, 2, 32, 0, 0);
access.add(6, 5, 6, 64, 3, 0);
access.add(7, 1, 4, 0, 0, 2);
access.add(8, 1, 3, 0, 0, 0); access.text(8, 1, '<b>Literal</b>');
assert.equal(access.commit(0), 1);
const disabled = children()[0].children[0], readonly = children()[1], hidden = children()[2].children[0];
assert.notEqual(disabled.tabIndex, 0); assert.notEqual(hidden.tabIndex, 0);
assert.equal(hidden.getAttribute('aria-hidden'), 'true');
assert.equal(readonly.readOnly, true);
assert.equal(children()[3].getAttribute('aria-level'), '2');
assert.equal(children()[4].textContent, '<b>Literal</b>');
disabled.emit('click'); hidden.emit('click'); readonly.value = 'changed'; readonly.emit('input');
assert.equal(access.next(9, 256), null);
access.close();
readonly.emit('input');
assert.equal(access.next(9, 256), null);
assert.equal(container.children.length, 0);
assert.equal(canvas.getAttribute('aria-hidden'), null);
assert.equal(canvas.getAttribute('tabindex'), '0');
// Widget roles: radio, switch, combobox, tab list/tab, progress bar, dialog.
assert.equal(access.begin(16, 256, 10), 1);
access.add(1, 0, 1, 0, 0, 0);
access.add(2, 1, 21, 64, 2, 0); access.text(2, 1, 'Confirm');
access.add(3, 2, 15, 66, 3, 0);
access.add(4, 2, 16, 64, 10, 0);
access.add(5, 2, 17, 72, 3, 0); access.text(5, 2, 'Dark');
access.add(6, 2, 18, 0, 0, 0);
access.add(7, 6, 19, 68, 3, 0);
access.add(8, 2, 20, 0, 0, 0); access.text(8, 2, '50%');
access.add(9, 2, 7, 64, 3, 0);
assert.equal(access.commit(4), 1);
const dialog = children()[0];
const [radio, toggle, combo, tablist, progress, menuCheck] = dialog.children;
assert.equal(dialog.getAttribute('role'), 'dialog');
assert.equal(dialog.getAttribute('aria-modal'), 'true');
assert.equal(radio.getAttribute('role'), 'radio');
assert.equal(radio.getAttribute('aria-checked'), 'true');
assert.equal(toggle.getAttribute('role'), 'switch');
assert.equal(toggle.getAttribute('aria-checked'), 'false');
assert.equal(combo.getAttribute('role'), 'combobox');
assert.equal(combo.getAttribute('aria-expanded'), 'true');
assert.equal(combo.textContent, 'Dark');
assert.equal(tablist.getAttribute('role'), 'tablist');
assert.equal(tablist.children[0].getAttribute('role'), 'tab');
assert.equal(tablist.children[0].getAttribute('aria-selected'), 'true');
assert.equal(progress.getAttribute('role'), 'progressbar');
assert.equal(progress.getAttribute('aria-valuetext'), '50%');
assert.equal(document.activeElement, toggle);
toggle.emit('keydown', { key: ' ' });
assert.equal(access.next(10, 256).action, 8, 'a switch toggles');
radio.emit('click');
assert.equal(access.next(10, 256).action, 1, 'a radio activates');
menuCheck.emit('click');
assert.equal(access.next(10, 256).action, 1, 'a checkbox without toggle activates');
access.close();
assert.equal(access.begin(4, 64, 11), 1);
assert.equal(access.add(1, 0, 22, 0, 0, 0), 0, 'roles past the table are rejected');
assert.equal(access.begin(4, 64, 11), 1);
assert.equal(access.add(1, 0, 21, 0, 0, 0), 1);
access.close();
// Caret and selection: published in code points, set on the textarea in
// UTF-16 units without echoing, and user moves queued as SET_SELECTION.
assert.equal(access.begin(8, 256, 12), 1);
access.add(1, 0, 1, 0, 0, 0);
access.add(2, 1, 8, 64, 22, 0); access.text(2, 2, 'a\u{1F642}b\nc');
assert.equal(access.selection(2, 1, 1, 3), 1);
access.add(3, 1, 8, 80, 16, 0); access.text(3, 2, 'ro');
access.add(4, 1, 8, 64, 6, 0); access.text(4, 2, 'plain');
assert.equal(access.commit(0), 1);
let [editor, readonlyEditor, plain] = children();
assert.deepEqual([editor.selectionStart, editor.selectionEnd, editor.selectionDirection], [1, 4, 'backward']);
assert.equal(access.next(12, 256), null, 'a published selection is not echoed');
editor.setSelectionRange(0, 6, 'forward');
assert.deepEqual(decode(access.next(12, 256)), { id: 2, action: 16, value: '0 5' });
editor.emit('keyup'); editor.emit('selectionchange');
assert.equal(access.next(12, 256), null, 'no duplicate requests');
editor.value = 'xy'; editor.selectionStart = 2; editor.selectionEnd = 2; editor.selectionDirection = 'none';
editor.emit('input');
assert.deepEqual(decode(access.next(12, 256)), { id: 2, action: 4, value: 'xy' });
assert.deepEqual(decode(access.next(12, 256)), { id: 2, action: 16, value: '2 2' }, 'the caret after an edit');
readonlyEditor.setSelectionRange(0, 1);
assert.deepEqual(decode(access.next(12, 256)), { id: 3, action: 16, value: '0 1' }, 'read-only text selects');
plain.setSelectionRange(0, 2);
assert.equal(access.next(12, 256), null, 'no SET_SELECTION action, no request');
for (const invalid of [
  () => access.selection(2, 1, 1, 9),
  () => access.selection(2, 2, 1, 3),
  () => access.selection(2, 3, 3, 1),
  () => access.selection(9, 0, 0, 0),
  () => access.add(5, 1, 8, 64, 32, 0),
]) {
  assert.equal(access.begin(8, 256, 13), 1);
  access.add(1, 0, 1, 0, 0, 0);
  access.add(2, 1, 8, 64, 22, 0); access.text(2, 2, 'a\u{1F642}b\nc');
  assert.equal(invalid(), 0); assert.equal(access.commit(0), 0);
}
access.close();
const absent = makeAccessibilityEnv({ memory: () => memory });
assert.equal(absent.gfx_access_begin(1, 1, 1), 0);
assert.equal(absent.gfx_access_next(1, 512, 1024, 1), 0);
absent.gfx_access_close();
console.log('web accessibility DOM/ABI contracts OK');

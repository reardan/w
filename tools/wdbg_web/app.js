// wdbg_web UI: talks to tools/wdbg_web.w's JSON API, which fronts wdbg's
// text command loop. All wdbg output is parsed here, in the browser.
'use strict';

const $ = (id) => document.getElementById(id);

const ui = {
	state: 'none',
	program: '',
	files: [],
	sources: new Map(),     // path -> array of lines
	shownFile: null,
	stop: null,             // {func, file, line} of the selected frame
	breakpoints: [],        // {n, file, line, text}
	busy: false,
	polling: null,
	history: [],
	historyPos: 0,
};

// The access code arrives in the URL once; the server then sets a cookie.
// Keep sending it as a header too, and drop it from the address bar.
const code = new URLSearchParams(location.search).get('code') || sessionStorage.getItem('wdbg_code') || '';
if (code) {
	try { sessionStorage.setItem('wdbg_code', code); } catch (e) { /* private mode */ }
	history.replaceState(null, '', location.pathname);
}

async function api(path, options = {}) {
	const headers = Object.assign({ 'X-Wdbg-Code': code }, options.headers || {});
	const resp = await fetch(path, Object.assign({}, options, { headers, credentials: 'same-origin' }));
	const type = resp.headers.get('Content-Type') || '';
	const body = type.startsWith('application/json') ? await resp.json() : await resp.text();
	if (!resp.ok) {
		const msg = typeof body === 'string' ? body : (body.error || resp.statusText);
		throw new Error(msg.trim());
	}
	return body;
}

// ---- parsing wdbg's text output ------------------------------------------------

// "main (/abs/path/file.w:12)" -> {func, file, line}
const locRe = /^(?:#\d+\s+)?(\S+) \((\/.+):(\d+)\)/;

function parseLocation(text) {
	for (const ln of text.split('\n')) {
		const m = locRe.exec(ln.trim());
		if (m) return { func: m[1], file: m[2], line: Number(m[3]) };
	}
	return null;
}

// Last location announced in a chunk of command output (a step or a hit).
function lastLocation(text) {
	let found = null;
	for (const ln of text.split('\n')) {
		const m = /(\S+) \((\/[^()]+):(\d+)\)/.exec(ln);
		if (m) found = { func: m[1], file: m[2], line: Number(m[3]) };
	}
	return found;
}

function parseBreakpoints(text) {
	const out = [];
	for (const ln of text.split('\n')) {
		const m = /^breakpoint (\d+) at \S+ \((\/.+?):(\d+)\)/.exec(ln.trim());
		if (m) out.push({ n: Number(m[1]), file: m[2], line: Number(m[3]), text: ln.trim() });
	}
	return out;
}

function parseVars(text) {
	const rows = [];
	for (const ln of text.split('\n')) {
		const t = ln.trim();
		if (!t) continue;
		const eq = t.indexOf(' = ');
		if (eq > 0) rows.push([t.slice(0, eq), t.slice(eq + 3)]);
		else rows.push(['', t]);
	}
	return rows;
}

// ---- rendering -----------------------------------------------------------------

function basename(p) { return p.slice(p.lastIndexOf('/') + 1); }

function setState(state) {
	ui.state = state;
	const el = $('state');
	el.textContent = state;
	el.className = 'state ' + state;
	const stopped = state === 'stopped';
	for (const b of document.querySelectorAll('#controls button[data-cmd]')) b.disabled = !stopped || ui.busy;
	$('console-input').disabled = !stopped;
	if (state === 'running' && !ui.polling) ui.polling = setInterval(poll, 400);
	if (state !== 'running' && ui.polling) { clearInterval(ui.polling); ui.polling = null; }
}

function consoleWrite(text, cls) {
	if (!text) return;
	const con = $('console');
	const span = document.createElement('span');
	if (cls) span.className = cls;
	span.textContent = text;
	con.appendChild(span);
	con.scrollTop = con.scrollHeight;
}

function renderFilePicker() {
	const sel = $('file-picker');
	const files = ui.files.slice();
	if (ui.program && !files.includes(ui.program)) files.unshift(ui.program);
	sel.innerHTML = '';
	// The program's own files first, the standard library after.
	files.sort((a, b) => (a === ui.program ? -1 : b === ui.program ? 1 : a.localeCompare(b)));
	for (const f of files) {
		const opt = document.createElement('option');
		opt.value = f;
		opt.textContent = f === ui.program ? basename(f) + '  (program)' : f;
		sel.appendChild(opt);
	}
	if (ui.shownFile) sel.value = ui.shownFile;
}

async function loadSource(file) {
	if (!ui.sources.has(file)) {
		const text = await api('/api/source?file=' + encodeURIComponent(file));
		ui.sources.set(file, text.replace(/\n$/, '').split('\n'));
	}
	return ui.sources.get(file);
}

async function showFile(file, scrollLine) {
	let lines;
	try {
		lines = await loadSource(file);
	} catch (e) {
		consoleWrite('cannot show ' + file + ': ' + e.message + '\n', 'err');
		return;
	}
	ui.shownFile = file;
	$('file-picker').value = file;
	const src = $('source');
	src.innerHTML = '';
	const frag = document.createDocumentFragment();
	lines.forEach((text, i) => {
		const row = document.createElement('div');
		row.className = 'line';
		row.dataset.line = i + 1;
		const g = document.createElement('span');
		g.className = 'gutter';
		g.textContent = i + 1;
		g.title = 'Toggle breakpoint';
		const t = document.createElement('span');
		t.className = 'text';
		t.textContent = text || ' ';
		row.append(g, t);
		frag.appendChild(row);
	});
	src.appendChild(frag);
	decorateSource();
	if (scrollLine) {
		const row = src.querySelector(`.line[data-line="${scrollLine}"]`);
		if (row) row.scrollIntoView({ block: 'center' });
	}
}

function decorateSource() {
	const src = $('source');
	for (const row of src.querySelectorAll('.line.bp, .line.current')) row.classList.remove('bp', 'current');
	for (const bp of ui.breakpoints) {
		if (bp.file !== ui.shownFile) continue;
		const row = src.querySelector(`.line[data-line="${bp.line}"]`);
		if (row) row.classList.add('bp');
	}
	if (ui.stop && ui.stop.file === ui.shownFile) {
		const row = src.querySelector(`.line[data-line="${ui.stop.line}"]`);
		if (row) row.classList.add('current');
	}
}

function renderVars(tableId, text) {
	const table = $(tableId);
	table.innerHTML = '';
	const rows = parseVars(text);
	if (rows.length === 0 || /^no |^\?/.test(text.trim())) {
		const tr = table.insertRow();
		const td = tr.insertCell();
		td.className = 'empty';
		td.textContent = text.trim() || 'none';
		return;
	}
	for (const [k, v] of rows) {
		const tr = table.insertRow();
		tr.insertCell().textContent = k;
		tr.insertCell().textContent = v;
	}
}

function renderBacktrace(text) {
	const ol = $('backtrace');
	ol.innerHTML = '';
	for (const ln of text.split('\n')) {
		const t = ln.trim();
		if (!t) continue;
		const li = document.createElement('li');
		li.textContent = t;
		const m = /^#(\d+)/.exec(t);
		if (m) li.addEventListener('click', () => runCommand('f ' + m[1]));
		ol.appendChild(li);
	}
	if (!ol.children.length) ol.innerHTML = '<li class="empty">no frames</li>';
}

function renderBreakpoints(text) {
	ui.breakpoints = parseBreakpoints(text);
	const ul = $('breakpoints');
	ul.innerHTML = '';
	for (const bp of ui.breakpoints) {
		const li = document.createElement('li');
		li.textContent = '#' + bp.n + '  ' + basename(bp.file) + ':' + bp.line;
		li.title = bp.text;
		li.addEventListener('click', () => showFile(bp.file, bp.line));
		const del = document.createElement('span');
		del.className = 'del';
		del.textContent = '✕';
		del.title = 'Delete breakpoint';
		del.addEventListener('click', (ev) => { ev.stopPropagation(); runCommand('d ' + bp.n); });
		li.appendChild(del);
		ul.appendChild(li);
	}
	if (!ui.breakpoints.length) ul.innerHTML = '<li class="empty">click a line number to add one</li>';
	decorateSource();
}

async function refreshInspect() {
	if (ui.state !== 'stopped') return;
	let info;
	try {
		info = await api('/api/inspect');
	} catch (e) {
		return;
	}
	renderVars('locals', info.locals);
	renderVars('args', info.args);
	renderBacktrace(info.backtrace);
	renderBreakpoints(info.breakpoints);
	$('watchpoints').textContent = info.watchpoints.trim();
	ui.stop = parseLocation(info.where);
	$('where').textContent = ui.stop ? `${ui.stop.func}  ${basename(ui.stop.file)}:${ui.stop.line}` : info.where.split('\n')[0];
	if (ui.stop) {
		if (ui.stop.file !== ui.shownFile) await showFile(ui.stop.file, ui.stop.line);
		else {
			decorateSource();
			const row = $('source').querySelector(`.line[data-line="${ui.stop.line}"]`);
			if (row) row.scrollIntoView({ block: 'nearest' });
		}
	} else {
		decorateSource();
	}
}

// ---- commands ------------------------------------------------------------------

async function runCommand(cmd, echo = true) {
	if (ui.state !== 'stopped' || ui.busy) return;
	ui.busy = true;
	setState(ui.state);
	if (echo) consoleWrite('wdbg> ' + cmd + '\n', 'cmd');
	try {
		const r = await api('/api/cmd', { method: 'POST', body: cmd, headers: { 'Content-Type': 'text/plain' } });
		consoleWrite(r.output);
		ui.busy = false;
		setState(r.state);
		if (r.state === 'stopped') await refreshInspect();
	} catch (e) {
		ui.busy = false;
		consoleWrite(e.message + '\n', 'err');
		await refreshState();
	}
}

async function poll() {
	try {
		const r = await api('/api/poll');
		consoleWrite(r.output);
		if (r.state !== 'running') {
			setState(r.state);
			if (r.state === 'stopped') await refreshInspect();
		}
	} catch (e) { /* transient; keep polling */ }
}

async function refreshState() {
	const st = await api('/api/state');
	ui.program = st.program;
	ui.files = st.files;
	$('program').textContent = st.program;
	document.title = 'wdbg ' + (st.program ? basename(st.program) : '');
	renderFilePicker();
	setState(st.state);
	// --core without a program: a post-mortem view, no live session.
	document.body.classList.toggle('core-only', st.has_core && !st.program);
	if (st.has_core && !st.program) $('state').textContent = 'core dump';
	if (st.has_core) await loadCore();
	return st;
}

function toggleBreakpoint(line) {
	if (!ui.shownFile) return;
	const bp = ui.breakpoints.find((b) => b.file === ui.shownFile && b.line === line);
	if (bp) runCommand('d ' + bp.n);
	else runCommand('b ' + ui.shownFile + ':' + line);
}

// ---- core dumps (--core) -------------------------------------------------------

async function loadCore() {
	const panel = $('core-panel');
	panel.hidden = false;
	let core;
	try { core = await api('/api/core'); } catch (e) { $('core').textContent = e.message; return; }
	const box = $('core');
	box.innerHTML = '';
	if (core.error) { box.textContent = core.error; return; }
	const dl = document.createElement('dl');
	const add = (k, v) => {
		if (v === undefined) return;
		const dt = document.createElement('dt'); dt.textContent = k;
		const dd = document.createElement('dd'); dd.textContent = String(v);
		dl.append(dt, dd);
	};
	add('signal', core.signal_name ? `${core.signal_name} (${core.signal})` : core.signal);
	add('pc', core.pc);
	add('fault addr', core.fault_address);
	add('binary', core.binary);
	add('source', core.source);
	box.appendChild(dl);
	const ol = document.createElement('ol');
	ol.className = 'frames';
	(core.frames || []).forEach((f, i) => {
		const li = document.createElement('li');
		li.textContent = `#${i}  ${f.function || f.pc}` + (f.file ? `  ${basename(f.file)}:${f.line}` : '');
		if (f.file) li.addEventListener('click', () => showFile(f.file, f.line).then(() => markCoreLine(f)));
		ol.appendChild(li);
	});
	box.appendChild(ol);
	const regs = document.createElement('pre');
	regs.className = 'raw';
	regs.textContent = Object.entries(core.registers || {}).map(([k, v]) => k + ' ' + v).join('\n');
	box.appendChild(regs);
	const first = (core.frames || []).find((f) => f.file);
	if (first) { await showFile(first.file, first.line); markCoreLine(first); }
}

function markCoreLine(f) {
	ui.stop = { func: f.function, file: f.file, line: f.line };
	decorateSource();
}

// ---- wiring --------------------------------------------------------------------

function wire() {
	for (const b of document.querySelectorAll('#controls button[data-cmd]')) {
		b.addEventListener('click', () => runCommand(b.dataset.cmd));
	}
	$('restart').addEventListener('click', async () => {
		if (ui.busy) return;
		ui.busy = true;
		consoleWrite('[restarting]\n', 'cmd');
		try {
			const r = await api('/api/restart', { method: 'POST' });
			consoleWrite(r.output);
		} catch (e) { consoleWrite(e.message + '\n', 'err'); }
		ui.busy = false;
		ui.stop = null;
		await refreshState();
		await refreshInspect();
	});
	$('source').addEventListener('click', (ev) => {
		const g = ev.target.closest('.gutter');
		if (g) toggleBreakpoint(Number(g.parentElement.dataset.line));
	});
	$('file-picker').addEventListener('change', (ev) => showFile(ev.target.value));
	$('console-form').addEventListener('submit', (ev) => {
		ev.preventDefault();
		const input = $('console-input');
		const cmd = input.value.trim();
		if (!cmd) return;
		ui.history.push(cmd);
		ui.historyPos = ui.history.length;
		input.value = '';
		runCommand(cmd);
	});
	$('console-input').addEventListener('keydown', (ev) => {
		const input = ev.target;
		if (ev.key === 'ArrowUp' && ui.historyPos > 0) {
			ui.historyPos -= 1; input.value = ui.history[ui.historyPos]; ev.preventDefault();
		} else if (ev.key === 'ArrowDown' && ui.historyPos < ui.history.length) {
			ui.historyPos += 1; input.value = ui.history[ui.historyPos] || ''; ev.preventDefault();
		}
	});
	document.addEventListener('keydown', (ev) => {
		const keys = { F5: 'c', F10: 'n', F11: ev.shiftKey ? 'fin' : 's' };
		if (keys[ev.key]) { ev.preventDefault(); runCommand(keys[ev.key]); }
	});
}

async function start() {
	wire();
	try {
		const st = await refreshState();
		const first = st.program || st.files[0];
		if (first) await showFile(first);
		await refreshInspect();
		const pending = await api('/api/poll');
		consoleWrite(pending.output);
		if (!document.body.classList.contains('core-only')) setState(pending.state);
	} catch (e) {
		consoleWrite(e.message + '\n', 'err');
		setState('none');
	}
}

start();

/**
 * Backuper Web UI - Main JavaScript
 * Handles frontend logic, API interactions, and UI updates.
 */

// ── Theme Management ────────────────────────────────────────────────────────
(function() {
    const r = document.documentElement;
    let d = matchMedia('(prefers-color-scheme:dark)').matches ? 'dark' : 'light';
    r.setAttribute('data-theme', d);
    const t = document.querySelector('[data-theme-toggle]');
    const sun = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="5"/><path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"/></svg>';
    const moon = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>';

    function apply() {
        if (t) t.innerHTML = d === 'dark' ? sun : moon;
    }
    apply();
    if (t) {
        t.addEventListener('click', () => {
            d = d === 'dark' ? 'light' : 'dark';
            r.setAttribute('data-theme', d);
            apply();
        });
    }
})();

// ── Configuration & State ───────────────────────────────────────────────────
let _savedBackup = '',
    _savedStacks = '';

async function loadConfig() {
    try {
        const r = await fetch('/config');
        const cfg = await r.json();
        const inputBackup = document.getElementById('input-backup-dir');
        const inputStacks = document.getElementById('input-stacks-dir');
        if (inputBackup) inputBackup.value = cfg.backup_dir || '';
        if (inputStacks) inputStacks.value = cfg.stacks_dir || '';
        _savedBackup = cfg.backup_dir || '';
        _savedStacks = cfg.stacks_dir || '';
    } catch (e) {
        console.warn('config load failed', e);
    }
}

// ── Dirty State Detection ───────────────────────────────────────────────────
function markDirty() {
    const bd = document.getElementById('input-backup-dir').value.trim();
    const sd = document.getElementById('input-stacks-dir').value.trim();
    const dirty = (bd !== _savedBackup) || (sd !== _savedStacks);
    const saveBar = document.getElementById('save-bar');
    if (saveBar) saveBar.classList.toggle('show', dirty);
    const saveResult = document.getElementById('save-result');
    if (saveResult) saveResult.textContent = '';
}

async function savePaths() {
    const body = {
        backup_dir: document.getElementById('input-backup-dir').value.trim(),
        stacks_dir: document.getElementById('input-stacks-dir').value.trim(),
    };
    try {
        const res = await fetch('/config', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        const data = await res.json();
        const r = document.getElementById('save-result');
        if (data.ok) {
            r.textContent = '✓ Saved';
            _savedBackup = body.backup_dir;
            _savedStacks = body.stacks_dir;
            document.getElementById('save-bar').classList.remove('show');
            setTimeout(() => { r.textContent = '' }, 2000);
        } else {
            r.textContent = 'Error: ' + data.error;
            r.style.color = 'var(--error)';
        }
    } catch (e) {
        alert('Failed to save config: ' + e.message);
    }
}

// ── Flag Management ─────────────────────────────────────────────────────────
const exclusive = [
    ['--copy-all', '--reject-all'],
    ['--archive', '--archive-replace']
];

function toggleFlag(btn) {
    const flag = btn.dataset.flag,
        was = btn.classList.contains('active');
    for (const g of exclusive) {
        if (g.includes(flag)) {
            g.forEach(f => {
                const b = document.querySelector(`[data-flag="${f}"]`);
                if (b) b.classList.remove('active');
            });
        }
    }
    btn.classList.toggle('active', !was);
}

function getFlags() {
    return Array.from(document.querySelectorAll('.flag-toggle.active')).map(b => b.dataset.flag);
}

// ── UI Status ───────────────────────────────────────────────────────────────
function setStatus(state, text) {
    const b = document.getElementById('status-badge');
    if (!b) return;
    b.className = state;
    const statusText = b.querySelector('#status-text');
    if (statusText) statusText.textContent = text;
    const dot = b.querySelector('.dot');
    if (dot) dot.className = 'dot' + (state === 'running' ? ' pulse' : '');
}

// ── Logging ─────────────────────────────────────────────────────────────────
const logEl = document.getElementById('log');
const logWrap = document.getElementById('log-wrap');

function ansiToHtml(raw) {
    const map = { '32': 'ansi-green', '33': 'ansi-yellow', '31': 'ansi-red', '36': 'ansi-blue', '1': 'ansi-bold' };
    let html = '';
    const parts = raw.replace(/\x1b\[([0-9;]*)m/g, '\x00$1\x00').split('\x00');
    parts.forEach((p, i) => {
        if (i % 2 === 1) {
            const cls = p.split(';').map(c => map[c] || '').filter(Boolean).join(' ');
            html += cls ? `</span><span class="${cls}">` : '';
        } else {
            html += p.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
        }
    });
    return html;
}

function appendLog(line) {
    if (logWrap) logWrap.classList.add('visible');
    if (logEl) {
        logEl.innerHTML += ansiToHtml(line) + '\n';
        logEl.scrollTop = logEl.scrollHeight;
    }
}

function clearLog() {
    if (logEl) logEl.innerHTML = '';
    if (logWrap) logWrap.classList.remove('visible');
}

// ── Backup Execution (SSE) ─────────────────────────────────────────────────
let es = null;
let _discoveredStacks = [];

async function runBackup() {
    const btn = document.getElementById('btn-backup');
    const originalText = btn.innerHTML;
    btn.disabled = true;
    btn.textContent = 'Discovering...';
    
    try {
        const res = await fetch('/api/discover-containers');
        const data = await res.json();
        
        if (!data.ok) {
            alert('Failed to discover containers: ' + data.error);
            btn.disabled = false;
            btn.innerHTML = originalText;
            return;
        }
        
        _discoveredStacks = data.containers || [];
        
        if (_discoveredStacks.length === 0) {
            alert('No backupable containers found.');
            btn.disabled = false;
            btn.innerHTML = originalText;
            return;
        }
        
        // Populate modal
        const list = document.getElementById('selection-list');
        if (list) {
            list.innerHTML = _discoveredStacks.map((s, i) => `
                <label style="display: flex; align-items: center; gap: 0.5rem; cursor: pointer; padding: 0.25rem 0.5rem; background: var(--surface-2); border-radius: var(--radius); border: 1px solid var(--border);">
                    <input type="checkbox" class="stack-select" value="${s.path}" checked>
                    <span style="font-family: var(--mono); font-size: 0.85rem; color: var(--text);">${s.name}</span>
                </label>
            `).join('');
        }
        
        const bd = document.getElementById('selection-backdrop');
        if (bd) {
            bd.style.display = 'flex';
            setTimeout(() => bd.classList.add('open'), 10);
        }
    } catch (err) {
        alert('Failed to discover containers: ' + err.message);
    }
    
    btn.disabled = false;
    btn.innerHTML = originalText;
}

function closeSelectionModal() {
    const bd = document.getElementById('selection-backdrop');
    if (bd) {
        bd.classList.remove('open');
        setTimeout(() => bd.style.display = 'none', 300);
    }
}

function toggleAllSelection(check) {
    document.querySelectorAll('.stack-select').forEach(cb => cb.checked = check);
}

function confirmSelection() {
    const selected = Array.from(document.querySelectorAll('.stack-select:checked')).map(cb => cb.value);
    
    if (selected.length === 0) {
        alert('Please select at least one container.');
        return;
    }
    
    closeSelectionModal();
    executeBackup(selected);
}

function executeBackup(stacks) {
    if (es) { es.close(); es = null; }
    clearLog();
    const flags = getFlags();
    if (stacks && stacks.length > 0) {
        flags.push('--containers', ...stacks);
    }
    const btn = document.getElementById('btn-backup');
    if (btn) btn.disabled = true;
    setStatus('running', 'Running…');
    const logMeta = document.getElementById('log-meta');
    if (logMeta) logMeta.textContent = 'Output — started ' + new Date().toLocaleTimeString();
    const btnAbort = document.getElementById('btn-abort');
    if (btnAbort) btnAbort.style.display = 'inline-flex';

    const progressWrap = document.getElementById('job-progress-wrap');
    const progressBar = document.getElementById('job-progress-bar');
    const subProgressBar = document.getElementById('sub-progress-bar');
    const statusText = document.getElementById('job-status-text');
    const subStatusText = document.getElementById('sub-status-text');
    const percentText = document.getElementById('job-percent');
    const subPercentText = document.getElementById('sub-percent');
    const currentFileText = document.getElementById('job-current-file');

    if (progressWrap) progressWrap.style.display = 'block';
    if (statusText) statusText.textContent = 'Starting backup...';
    if (progressBar) progressBar.style.width = '0%';
    if (subProgressBar) subProgressBar.style.width = '0%';
    if (percentText) percentText.textContent = '0%';
    if (subPercentText) subPercentText.textContent = '0%';
    if (currentFileText) currentFileText.textContent = '';

    const qs = flags.length ? '?flags=' + encodeURIComponent(flags.join(' ')) : '';
    es = new EventSource('/stream' + qs);
    let lastPhase = 'starting';

    es.addEventListener('log', e => appendLog(JSON.parse(e.data)));
    es.addEventListener('line', e => appendLog(JSON.parse(e.data)));
    es.addEventListener('prompt', e => {
        const data = JSON.parse(e.data);
        const bd = document.getElementById('prompt-backdrop');
        if(bd) {
            document.getElementById('prompt-context').textContent = data.context ? data.context.join('\n') : '';
            document.getElementById('prompt-text').textContent = data.text || 'Action required';
            bd.classList.add('open');
        }
    });

    es.addEventListener('status', e => {
        const status = JSON.parse(e.data);
        lastPhase = status.phase || lastPhase;

        if (!status.running && status.phase !== 'complete') return;

        const overallPercent = status.total > 0 ? Math.round((status.progress / status.total) * 100) : 0;
        if (statusText) statusText.textContent = `Overall: ${status.progress} of ${status.total}`;
        if (progressBar) progressBar.style.width = overallPercent + '%';
        if (percentText) percentText.textContent = overallPercent + '%';

        let stepLabel = 'Processing...';
        let progressInfo = '';

        if (status.phase === 'discover') stepLabel = 'Step 1: Discovering...';
        else if (status.phase === 'extract') stepLabel = 'Step 2: Extracting configs...';
        else if (status.phase === 'copy') {
            stepLabel = 'Step 3: Copying data...';
            if (status.sub_total > 0) {
                const mb = (v) => (v / (1024 * 1024)).toFixed(1);
                progressInfo = ` (${mb(status.sub_progress)}MB / ${mb(status.sub_total)}MB)`;
            }
        }
        else if (status.phase === 'archive') stepLabel = 'Step 4: Archiving...';

        if (subStatusText) subStatusText.textContent = stepLabel + progressInfo;
        const subPercent = status.sub_total > 0 ? Math.round((status.sub_progress / status.sub_total) * 100) : 0;
        if (subProgressBar) subProgressBar.style.width = subPercent + '%';
        if (subPercentText) subPercentText.textContent = subPercent + '%';
        if (currentFileText) currentFileText.textContent = status.sub_current_file || status.current || '';
    });

    es.addEventListener('done', e => {
        loadArchives();
        const code = parseInt(e.data, 10);
        if (es) { es.close(); es = null; }
        if (btn) btn.disabled = false;
        if (btnAbort) btnAbort.style.display = 'none';
        setStatus(code === 0 ? 'ok' : 'error', code === 0 ? 'Completed ✓' : 'Failed (exit ' + code + ')');
        appendLog('\n--- backup exited with code ' + code + ' ---');
        if (logMeta) logMeta.textContent = 'Output — finished ' + new Date().toLocaleTimeString();
        
        if (code === 0) {
            if (progressBar) progressBar.style.width = '100%';
            if (percentText) percentText.textContent = '100%';
            if (subProgressBar) subProgressBar.style.width = '100%';
            if (subPercentText) subPercentText.textContent = '100%';
            if (statusText) statusText.textContent = 'Backup complete ✓';
            if (subStatusText) subStatusText.textContent = 'Finished';
            if (currentFileText) currentFileText.textContent = '';
        }
    });
    es.onerror = () => {
        if (es) { es.close(); es = null; }
        if (btn) btn.disabled = false;
        if (btnAbort) btnAbort.style.display = 'none';
        setStatus('error', 'Connection lost');
        appendLog('\n--- connection lost ---');
    };
}

// ── File Browser ────────────────────────────────────────────────────────────
let _browserTarget = null;
let _browserCurrent = '/';

const folderIcon = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>';
const upIcon = '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="15 18 9 12 15 6"/></svg>';

function openBrowser(target) {
    _browserTarget = target;
    const title = document.getElementById('browser-title');
    const label = target === 'backup_dir' ? 'Backup output directory' : 'Dockge stacks directory';
    if (title) title.textContent = 'Choose: ' + label;
    const cur = document.getElementById(target === 'backup_dir' ? 'input-backup-dir' : 'input-stacks-dir').value.trim();
    browseTo(cur || '/');
    const backdrop = document.getElementById('backdrop');
    if (backdrop) backdrop.classList.add('open');
}

function closeBrowser() {
    const backdrop = document.getElementById('backdrop');
    if (backdrop) backdrop.classList.remove('open');
    _browserTarget = null;
}

function backdropClick(e) {
    if (e.target === e.currentTarget) closeBrowser();
}

function buildBreadcrumb(path) {
    const crumb = document.getElementById('browser-crumb');
    if (!crumb) return;
    const parts = path.split('/').filter(Boolean);
    let html = '<span class="crumb-seg" data-nav="/">/ </span>';
    let acc = '';
    parts.forEach((p, i) => {
        acc += '/' + p;
        const isLast = (i === parts.length - 1);
        html += '<span class="crumb-sep">/</span>' +
            '<span class="crumb-seg' + (isLast ? ' active' : '') + '" data-nav="' + acc + '">' + p + '</span>';
    });
    crumb.innerHTML = html;
}

async function browseTo(path) {
    _browserCurrent = path;
    const curPathDisplay = document.getElementById('browser-cur-path');
    if (curPathDisplay) curPathDisplay.textContent = path;
    buildBreadcrumb(path);

    const list = document.getElementById('browser-list');
    if (!list) return;
    list.innerHTML = '<li class="dir-item"><span class="spin">↻</span>  Loading…</li>';

    try {
        const res = await fetch('/ls?path=' + encodeURIComponent(path));
        const data = await res.json();
        if (data.error) {
            list.innerHTML = '<li class="dir-empty">' + data.error + '</li>';
            return;
        }

        let html = '';
        if (data.parent !== data.path) {
            html += '<li class="dir-item is-up" data-nav="' + data.parent + '">' + upIcon + ' .. (up one level)</li>';
        }
        if (data.entries.length === 0) {
            html += '<li class="dir-empty">No subdirectories here</li>';
        }
        for (const e of data.entries) {
            html += '<li class="dir-item is-folder" data-nav="' + e.path + '">' + folderIcon + ' ' + e.name + '</li>';
        }
        list.innerHTML = html;
    } catch (err) {
        list.innerHTML = '<li class="dir-empty">Error: ' + err + '</li>';
    }
}

// Delegated click listener for breadcrumbs & dir list navigation
document.addEventListener('click', function(e) {
    const el = e.target.closest('[data-nav]');
    if (!el) return;
    const backdrop = document.getElementById('backdrop');
    if (backdrop && !backdrop.classList.contains('open')) return;
    browseTo(el.dataset.nav);
});

function confirmBrowser() {
    if (!_browserTarget) return;
    const inputId = _browserTarget === 'backup_dir' ? 'input-backup-dir' : 'input-stacks-dir';
    const input = document.getElementById(inputId);
    if (input) input.value = _browserCurrent;
    markDirty();
    closeBrowser();
}

// ── Archive Management ──────────────────────────────────────────────────────
const archiveIcon = '<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><polyline points="21 8 21 21 3 21 3 8"/><rect x="1" y="3" width="22" height="5"/><line x1="10" y1="12" x2="14" y2="12"/></svg>';
const dlIcon = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>';

function fmtSize(bytes) {
    if (bytes < 1024) return bytes + 'B';
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + 'KB';
    if (bytes < 1073741824) return (bytes / 1048576).toFixed(1) + 'MB';
    return (bytes / 1073741824).toFixed(2) + 'GB';
}

function fmtDate(ts) { return new Date(ts * 1000).toLocaleString() }

async function loadArchives() {
    const section = document.getElementById('archives-section');
    const grid = document.getElementById('archive-grid');
    const count = document.getElementById('archive-count');
    const btnAll = document.getElementById('btn-dl-all');
    if (!grid) return;
    grid.innerHTML = '<div class="archives-empty">Loading…</div>';
    if (section) section.classList.add('visible');
    try {
        const res = await fetch('/archives');
        const data = await res.json();
        const list = data.archives || [];
        if (count) count.textContent = list.length === 0 ? 'No archives found' : list.length + ' archive' + (list.length === 1 ? '' : 's') + ' in ' + data.backup_dir;
        if (btnAll) btnAll.disabled = (list.length === 0);
        if (list.length === 0) {
            grid.innerHTML = '<div class="archives-empty">No .tar.gz files found in the backup directory.<br>Run a backup with --archive or --archive-replace first.</div>';
            return;
        }
        grid.innerHTML = list.map(a => {
            const encRel = encodeURIComponent(a.name);
            return '<div class="archive-card">' +
                '<input type="checkbox" class="archive-select" value="' + a.name + '" style="margin-right: 10px;" checked>' +
                '<div class="archive-icon">' + archiveIcon + '</div>' +
                '<div class="archive-info">' +
                '<div class="archive-name" title="' + a.name + '">' + a.name + '</div>' +
                '<div class="archive-meta">' + fmtSize(a.size) + ' &nbsp;·&nbsp; ' + fmtDate(a.mtime) + '</div>' +
                '</div>' +
                '<a class="btn-dl" href="/download/' + encRel + '" download="' + a.name + '">' + dlIcon + ' Download</a>' +
                '</div>';
        }).join('');
    } catch (err) {
        grid.innerHTML = '<div class="archives-empty">Error loading archives: ' + err + '</div>';
    }
}

// Check if we should use native download (for files > 2GB)
async function shouldUseNativeDownload() {
    // For download-all, always use native - it's instant and handles any size
    return true;
}

async function downloadAll() {
    const btn = document.getElementById('btn-dl-all');
    if (!btn) return;
    
    btn.disabled = true;
    btn.textContent = 'Starting download…';
    
    try {
        // Use native browser download (instant, no memory issues)
        const ts = new Date().toISOString().slice(0, 19).replace(/[-:]/g, '');
        const a = document.createElement('a');
        a.href = '/download-all';
        a.download = `backuper_all_${ts}.tar.gz`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        
        // Reset button after a short delay
        setTimeout(() => {
            btn.disabled = false;
            btn.innerHTML = dlIcon + ' Download All';
        }, 1000);
    } catch (err) {
        console.error('Download failed:', err);
        btn.disabled = false;
        btn.innerHTML = dlIcon + ' Download All';
        btn.style.background = 'var(--error)';
        setTimeout(() => {
            btn.style.background = '';
        }, 3000);
        alert('Download failed: ' + (err.message || 'Unknown error'));
    }
}

// ── Upload Archive ──────────────────────────────────────────────────────────
async function uploadArchive(event) {
    const file = event.target.files[0];
    if (!file) return;

    const btn = document.getElementById('btn-restore');
    const originalHtml = btn.innerHTML;
    btn.disabled = true;
    btn.textContent = 'Uploading...';
    setStatus('running', 'Uploading...');

    try {
        const res = await fetch('/upload?filename=' + encodeURIComponent(file.name), {
            method: 'POST',
            headers: { 'Content-Type': 'application/octet-stream' },
            body: file
        });

        const data = await res.json();
        if (res.ok && data.ok) {
            setStatus('ok', 'Upload complete ✓');
            appendLog('\n--- Uploaded: ' + file.name + ' ---');
            loadArchives(); // Automatically refresh the archives grid
        } else {
            setStatus('error', 'Upload failed');
            appendLog('\n--- Upload failed: ' + (data.error || 'Unknown error') + ' ---');
            alert('Upload failed: ' + data.error);
        }
    } catch (err) {
        setStatus('error', 'Connection lost');
        appendLog('\n--- Upload failed: ' + err.message + ' ---');
        alert('Upload failed: ' + err.message);
    } finally {
        event.target.value = ''; // Reset the input so the same file can be uploaded again
        btn.disabled = false;
        btn.innerHTML = originalHtml;
    }
}

// ── Batch Restore ───────────────────────────────────────────────────────────
async function runBatchRestore() {
    const checkboxes = document.querySelectorAll('.archive-select:checked');
    const selected = Array.from(checkboxes).map(cb => cb.value);

    if (selected.length === 0) {
        alert('Error: Please select at least one archive to restore.');
        return;
    }

    if (!confirm(`Are you sure you want to restore ${selected.length} archives?`)) return;

    const btn = document.getElementById('btn-restore-action');
    const progressWrap = document.getElementById('job-progress-wrap');
    const progressBar = document.getElementById('job-progress-bar');
    const subProgressBar = document.getElementById('sub-progress-bar');
    const statusText = document.getElementById('job-status-text');
    const subStatusText = document.getElementById('sub-status-text');
    const percentText = document.getElementById('job-percent');
    const subPercentText = document.getElementById('sub-percent');
    const currentFileText = document.getElementById('job-current-file');
    const btnAbort = document.getElementById('btn-abort');

    if (btn) {
        btn.disabled = true;
        btn.textContent = 'Restoring...';
    }
    if (btnAbort) btnAbort.style.display = 'inline-flex';
    if (progressWrap) progressWrap.style.display = 'block';
    if (statusText) statusText.textContent = 'Starting restore...';
    if (progressBar) progressBar.style.width = '0%';
    if (subProgressBar) subProgressBar.style.width = '0%';
    if (percentText) percentText.textContent = '0%';
    if (subPercentText) subPercentText.textContent = '0%';
    if (currentFileText) currentFileText.textContent = '';

    clearLog();
    appendLog('--- Initializing Batch Restore ---');

    // Start status + log listener
    const sse = new EventSource('/stream?mode=listen');
    let lastPhase = 'starting';

    const getPhaseDebug = () => {
        let el = document.getElementById('job-phase-debug');
        if (!el && progressWrap) {
            el = document.createElement('div');
            el.id = 'job-phase-debug';
            el.style = 'font-size: 10px; color: var(--muted); margin-top: 5px; font-family: var(--mono); text-align: right; opacity: 0.6;';
            progressWrap.appendChild(el);
        }
        return el;
    };

    sse.addEventListener('log', e => appendLog(JSON.parse(e.data)));
    sse.addEventListener('line', e => appendLog(JSON.parse(e.data)));

    sse.addEventListener('status', e => {
        const status = JSON.parse(e.data);
        lastPhase = status.phase;
        const debug = getPhaseDebug();
        if (debug) debug.textContent = `PHASE: ${status.phase.toUpperCase()}`;

        if (!status.running && status.phase !== 'complete') return;

        const overallPercent = status.total > 0 ? Math.round((status.progress / status.total) * 100) : 0;
        if (statusText) statusText.textContent = `Overall: ${status.progress + 1} of ${status.total}`;
        if (progressBar) progressBar.style.width = overallPercent + '%';
        if (percentText) percentText.textContent = overallPercent + '%';

        let stepLabel = 'Processing...';
        let progressInfo = '';

        if (status.phase === 'preparing') {
            stepLabel = 'Step 1: Preparing...';
        } else if (status.phase === 'extracting') {
            stepLabel = 'Step 1: Extracting...';
            const mb = (v) => (v / (1024 * 1024)).toFixed(1);
            progressInfo = ` (${mb(status.sub_progress)}MB / ${mb(status.sub_total)}MB)`;
        } else if (status.phase === 'restoring') {
            stepLabel = 'Step 2: Restoring...';
        }

        if (subStatusText) subStatusText.textContent = stepLabel + progressInfo;
        const subPercent = status.sub_total > 0 ? Math.round((status.sub_progress / status.sub_total) * 100) : 0;
        if (subProgressBar) subProgressBar.style.width = subPercent + '%';
        if (subPercentText) subPercentText.textContent = subPercent + '%';
        if (currentFileText) currentFileText.textContent = status.sub_current_file || status.current;
    });

    sse.addEventListener('done', () => {
        if (lastPhase === 'complete') {
            if (progressBar) progressBar.style.width = '100%';
            if (percentText) percentText.textContent = '100%';
            if (subProgressBar) subProgressBar.style.width = '100%';
            if (subPercentText) subPercentText.textContent = '100%';
            if (statusText) statusText.textContent = 'Restore complete ✓';
            if (subStatusText) subStatusText.textContent = 'Finished';
            if (currentFileText) currentFileText.textContent = '';
            if (btn) {
                btn.disabled = false;
                btn.textContent = 'Restore Stack';
            }
            if (btnAbort) btnAbort.style.display = 'none';
            loadArchives();
        }
        sse.close();
    });

    sse.onerror = () => {
        if (btnAbort) btnAbort.style.display = 'none';
        sse.close();
    };

    try {
        const res = await fetch('/api/restore', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ archives: selected })
        });
        const data = await res.json();
        if (!res.ok) {
            alert('Error: ' + (data.error || 'Unknown error'));
            if (btn) {
                btn.disabled = false;
                btn.textContent = 'Restore Stack';
            }
            if (progressWrap) progressWrap.style.display = 'none';
            if (btnAbort) btnAbort.style.display = 'none';
            sse.close();
        }
    } catch (err) {
        alert('Restore failed: ' + err.message);
        if (btn) {
            btn.disabled = false;
            btn.textContent = 'Restore Stack';
        }
        if (progressWrap) progressWrap.style.display = 'none';
        if (btnAbort) btnAbort.style.display = 'none';
        sse.close();
    }
}

// ── Abort Job ───────────────────────────────────────────────────────────────
async function abortJob() {
    if (!confirm('Are you sure you want to abort the running process?')) return;
    try {
        const res = await fetch('/api/abort', { method: 'POST' });
        const data = await res.json();
        if (data.ok) {
            appendLog('\n--- User requested abort ---');
        } else {
            alert('Failed to abort job');
        }
    } catch (err) {
        console.error(err);
    }
}

// ── Prompt Response ─────────────────────────────────────────────────────────
async function respondToPrompt(answer) {
    const bd = document.getElementById('prompt-backdrop');
    if(bd) bd.classList.remove('open');
    try {
        await fetch('/api/respond', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ answer })
        });
    } catch(err) {
        appendLog('\n--- Failed to respond to prompt: ' + err.message + ' ---');
    }
}

// ── Initialization ──────────────────────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
    loadConfig();
    loadArchives();
});

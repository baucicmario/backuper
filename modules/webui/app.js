// ── Theme ─────────────────────────────────────────────────────────────────────
(function(){
  const r=document.documentElement;
  let d=matchMedia('(prefers-color-scheme:dark)').matches?'dark':'light';
  r.setAttribute('data-theme',d);
  const t=document.querySelector('[data-theme-toggle]');
  const sun='<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="5"/><path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"/></svg>';
  const moon='<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/></svg>';
  function apply(){t.innerHTML=d==='dark'?sun:moon}apply();
  t.addEventListener('click',()=>{d=d==='dark'?'light':'dark';r.setAttribute('data-theme',d);apply()});
})();

// ── Load config ───────────────────────────────────────────────────────────────
let _savedBackup='', _savedStacks='';

async function loadConfig(){
  try{
    const r=await fetch('/config');
    const cfg=await r.json();
    document.getElementById('input-backup-dir').value=cfg.backup_dir||'';
    document.getElementById('input-stacks-dir').value=cfg.stacks_dir||'';
    _savedBackup=cfg.backup_dir||'';
    _savedStacks=cfg.stacks_dir||'';
  }catch(e){console.warn('config load failed',e)}
}

loadConfig();
loadArchives();

// ── Dirty state ───────────────────────────────────────────────────────────────
function markDirty(){
  const bd=document.getElementById('input-backup-dir').value.trim();
  const sd=document.getElementById('input-stacks-dir').value.trim();
  const dirty=(bd!==_savedBackup)||(sd!==_savedStacks);
  document.getElementById('save-bar').classList.toggle('show', dirty);
  document.getElementById('save-result').textContent='';
}

async function savePaths(){
  const body={
    backup_dir:document.getElementById('input-backup-dir').value.trim(),
    stacks_dir:document.getElementById('input-stacks-dir').value.trim(),
  };
  const res=await fetch('/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  const data=await res.json();
  const r=document.getElementById('save-result');
  if(data.ok){
    r.textContent='✓ Saved';
    _savedBackup=body.backup_dir;_savedStacks=body.stacks_dir;
    document.getElementById('save-bar').classList.remove('show');
    setTimeout(()=>{r.textContent=''},2000);
  }else{r.textContent='Error: '+data.error;r.style.color='var(--error)'}
}

// ── Flags ─────────────────────────────────────────────────────────────────────
const exclusive=[['--copy-all','--reject-all'],['--archive','--archive-replace']];

function toggleFlag(btn){
  const flag=btn.dataset.flag,was=btn.classList.contains('active');
  for(const g of exclusive) if(g.includes(flag)) g.forEach(f=>document.querySelector(`[data-flag="${f}"]`)?.classList.remove('active'));
  btn.classList.toggle('active',!was);
}

function getFlags(){return Array.from(document.querySelectorAll('.flag-toggle.active')).map(b=>b.dataset.flag)}

// ── Status ────────────────────────────────────────────────────────────────────
function setStatus(state,text){
  const b=document.getElementById('status-badge');
  b.className=state;b.querySelector('#status-text').textContent=text;
  b.querySelector('.dot').className='dot'+(state==='running'?' pulse':'');
}

// ── Log ────────────────────────────────────────────────────────────────────────
const logEl=document.getElementById('log');
const logWrap=document.getElementById('log-wrap');

function ansiToHtml(raw){
  const map={'32':'ansi-green','33':'ansi-yellow','31':'ansi-red','36':'ansi-blue','1':'ansi-bold'};
  let html='';
  const parts=raw.replace(/\x1b\[([0-9;]*)m/g,'\x00$1\x00').split('\x00');
  parts.forEach((p,i)=>{
    if(i%2===1){const cls=p.split(';').map(c=>map[c]||'').filter(Boolean).join(' ');html+=cls?`</span><span class="${cls}">`:'';}
    else html+=p.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  });
  return html;
}

function appendLog(line){logWrap.classList.add('visible');logEl.innerHTML+=ansiToHtml(line)+'\n';logEl.scrollTop=logEl.scrollHeight}
function clearLog(){logEl.innerHTML='';logWrap.classList.remove('visible')}

// ── Run backup (SSE) ──────────────────────────────────────────────────────────
let es=null;

function runBackup(){
  if(es){es.close();es=null}
  clearLog();
  const flags=getFlags();
  const btn=document.getElementById('btn-backup');
  btn.disabled=true;setStatus('running','Running…');
  document.getElementById('log-meta').textContent='Output — started '+new Date().toLocaleTimeString();

  const qs=flags.length?'?flags='+encodeURIComponent(flags.join(' ')):'';
  es=new EventSource('/stream'+qs);
  es.addEventListener('line',e=>appendLog(JSON.parse(e.data)));
  es.addEventListener('done',e=>{
    loadArchives();
    const code=parseInt(e.data,10);es.close();es=null;btn.disabled=false;
    setStatus(code===0?'ok':'error',code===0?'Completed ✓':'Failed (exit '+code+')');
    appendLog('\n--- backup exited with code '+code+' ---');
    document.getElementById('log-meta').textContent='Output — finished '+new Date().toLocaleTimeString();
  });
  es.onerror=()=>{es.close();es=null;btn.disabled=false;setStatus('error','Connection lost');appendLog('\n--- connection lost ---')};
}

// ── File browser ──────────────────────────────────────────────────────────────
let _browserTarget=null;
let _browserCurrent='/';

const folderIcon='<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z"/></svg>';
const upIcon='<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="15 18 9 12 15 6"/></svg>';

function openBrowser(target){
  _browserTarget=target;
  const label=target==='backup_dir'?'Backup output directory':'Dockge stacks directory';
  document.getElementById('browser-title').textContent='Choose: '+label;
  const cur=document.getElementById(target==='backup_dir'?'input-backup-dir':'input-stacks-dir').value.trim();
  browseTo(cur||'/');
  document.getElementById('backdrop').classList.add('open');
}

function closeBrowser(){document.getElementById('backdrop').classList.remove('open');_browserTarget=null}
function backdropClick(e){if(e.target===e.currentTarget)closeBrowser()}

function buildBreadcrumb(path){
  const crumb=document.getElementById('browser-crumb');
  const parts=path.split('/').filter(Boolean);
  let html='<span class="crumb-seg" data-nav="/">/ </span>';
  let acc='';
  parts.forEach((p,i)=>{
    acc+='/'+p;
    const isLast=(i===parts.length-1);
    html+='<span class="crumb-sep">/</span>'
         +'<span class="crumb-seg'+(isLast?' active':'')+'" data-nav="'+acc+'">'+p+'</span>';
  });
  crumb.innerHTML=html;
}

async function browseTo(path){
  _browserCurrent=path;
  document.getElementById('browser-cur-path').textContent=path;
  buildBreadcrumb(path);

  const list=document.getElementById('browser-list');
  list.innerHTML='<li class="dir-item"><span class="spin">↻</span>  Loading…</li>';

  try{
    const res=await fetch('/ls?path='+encodeURIComponent(path));
    const data=await res.json();
    if(data.error){list.innerHTML='<li class="dir-empty">'+data.error+'</li>';return}

    let html='';
    if(data.parent!==data.path){
      html+='<li class="dir-item is-up" data-nav="'+data.parent+'">'+upIcon+' .. (up one level)</li>';
    }
    if(data.entries.length===0){
      html+='<li class="dir-empty">No subdirectories here</li>';
    }
    for(const e of data.entries){
      html+='<li class="dir-item is-folder" data-nav="'+e.path+'">'+folderIcon+' '+e.name+'</li>';
    }
    list.innerHTML=html;
  }catch(err){
    list.innerHTML='<li class="dir-empty">Error: '+err+'</li>';
  }
}

// Delegated click listener for breadcrumbs & dir list navigation
document.addEventListener('click', function(e){
  const el=e.target.closest('[data-nav]');
  if(!el) return;
  if(!document.getElementById('backdrop').classList.contains('open')) return;
  browseTo(el.dataset.nav);
});

function confirmBrowser(){
  if(!_browserTarget)return;
  const inputId=_browserTarget==='backup_dir'?'input-backup-dir':'input-stacks-dir';
  document.getElementById(inputId).value=_browserCurrent;
  markDirty();
  closeBrowser();
}

// ── Archives ───────────────────────────────────────────────────────────────
const archiveIcon='<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><polyline points="21 8 21 21 3 21 3 8"/><rect x="1" y="3" width="22" height="5"/><line x1="10" y1="12" x2="14" y2="12"/></svg>';
const dlIcon='<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>';

function fmtSize(bytes){
  if(bytes<1024) return bytes+'B';
  if(bytes<1048576) return (bytes/1024).toFixed(1)+'KB';
  if(bytes<1073741824) return (bytes/1048576).toFixed(1)+'MB';
  return (bytes/1073741824).toFixed(2)+'GB';
}

function fmtDate(ts){return new Date(ts*1000).toLocaleString()}

async function loadArchives(){
  const section=document.getElementById('archives-section');
  const grid=document.getElementById('archive-grid');
  const count=document.getElementById('archive-count');
  const btnAll=document.getElementById('btn-dl-all');
  grid.innerHTML='<div class="archives-empty">Loading…</div>';
  section.classList.add('visible');
  try{
    const res=await fetch('/archives');
    const data=await res.json();
    const list=data.archives||[];
    count.textContent=list.length===0?'No archives found':list.length+' archive'+(list.length===1?'':'s')+' in '+data.backup_dir;
    btnAll.disabled=(list.length===0);
    if(list.length===0){grid.innerHTML='<div class="archives-empty">No .tar.gz files found in the backup directory.<br>Run a backup with --archive or --archive-replace first.</div>';return}
    grid.innerHTML=list.map(a=>{
      const encRel=encodeURIComponent(a.name);
      return '<div class="archive-card">'
        +'<div class="archive-icon">'+archiveIcon+'</div>'
        +'<div class="archive-info">'
          +'<div class="archive-name" title="'+a.name+'">'+a.name+'</div>'
          +'<div class="archive-meta">'+fmtSize(a.size)+' &nbsp;·&nbsp; '+fmtDate(a.mtime)+'</div>'
        +'</div>'
        +'<a class="btn-dl" href="/download/'+encRel+'" download="'+a.name+'">'+dlIcon+' Download</a>'
        +'</div>';
    }).join('');
  }catch(err){
    grid.innerHTML='<div class="archives-empty">Error loading archives: '+err+'</div>';
  }
}

function downloadAll(){
  const btn=document.getElementById('btn-dl-all');
  btn.disabled=true;btn.textContent='Preparing…';
  const a=document.createElement('a');
  a.href='/download-all';
  a.download='backuper_all.tar.gz';
  document.body.appendChild(a);a.click();document.body.removeChild(a);
  setTimeout(()=>{btn.disabled=false;btn.innerHTML='<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg> Download All'},3000);
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
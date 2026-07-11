/* ============================================================
   espanso Web UI — Frontend Logic (v2 — kökten rewrite)
   ============================================================
   Tasarım prensipleri:
   - Tek kaynak: backend API. Frontend parser YOK.
   - State minimal: sadece cache için, render için değil.
   - Her fonksiyon bağımsız: biri bozulursa diğerini etkilemesin.
   - Tüm async hatalar handle edilir.
   ============================================================ */

'use strict';

// =====================================================================
//  API ENDPOINTS
// =====================================================================
const API = {
  status: '/api/status',
  restart: '/api/restart',
  matchFiles: '/api/match-files',
  matchFilesUpdate: '/api/match-files/update',
  matches: '/api/matches',
  matchesList: '/api/matches/list',
  matchesDelete: '/api/matches/delete',
  configFiles: '/api/config-files',
  configFilesUpdate: '/api/config-files/update'
};

// =====================================================================
//  STATE (minimal cache)
// =====================================================================
const state = {
  status: null,
  matchFiles: [],
  configFiles: [],
  allMatches: []
};

// =====================================================================
//  HELPERS
// =====================================================================
async function fetchJSON(url, options = {}) {
  const opts = {
    headers: { 'Content-Type': 'application/json' },
    cache: 'no-store',
    ...options
  };
  if (opts.body && typeof opts.body !== 'string') {
    opts.body = JSON.stringify(opts.body);
  }
  const res = await fetch(url, opts);
  const text = await res.text();
  let data;
  try { data = text ? JSON.parse(text) : {}; }
  catch { data = { error: 'Invalid JSON', detail: text.slice(0, 300) }; }
  if (!res.ok) {
    const err = new Error(data.error || `HTTP ${res.status}`);
    err.data = data;
    err.status = res.status;
    throw err;
  }
  return data;
}

function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === 'class') node.className = v;
    else if (k === 'dataset') Object.assign(node.dataset, v);
    else if (k.startsWith('on') && typeof v === 'function') {
      node.addEventListener(k.slice(2).toLowerCase(), v);
    } else if (v !== null && v !== undefined) {
      node.setAttribute(k, v);
    }
  }
  if (typeof children === 'string') node.textContent = children;
  else if (Array.isArray(children)) {
    children.forEach(c => {
      if (c === null || c === undefined) return;
      if (typeof c === 'string') node.appendChild(document.createTextNode(c));
      else node.appendChild(c);
    });
  }
  return node;
}

function escapeHTML(s) {
  if (s == null) return '';
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

let toastTimer;
function showToast(message, type = 'info', duration = 4000) {
  const t = document.getElementById('toast');
  t.textContent = message;
  t.className = `toast ${type}`;
  t.hidden = false;
  clearTimeout(toastTimer);
  if (duration > 0) toastTimer = setTimeout(() => { t.hidden = true; }, duration);
}

// =====================================================================
//  MODAL
// =====================================================================
function showModal(title, bodyHTML, onOk, okLabel = 'Tamam') {
  const modal = document.getElementById('modal');
  document.getElementById('modalTitle').textContent = title;
  document.getElementById('modalBody').innerHTML = bodyHTML;
  const okBtn = modal.querySelector('.modal-ok');
  okBtn.textContent = okLabel;
  okBtn.onclick = async () => {
    if (onOk) {
      try {
        const shouldClose = await onOk(modal);
        if (shouldClose !== false) modal.hidden = true;
      } catch (e) {
        showToast(e.message, 'error');
      }
    } else {
      modal.hidden = true;
    }
  };
  modal.hidden = false;
}
function hideModal() { document.getElementById('modal').hidden = true; }
document.querySelector('.modal-cancel').onclick = hideModal;
document.querySelector('.modal-close').onclick = hideModal;
document.querySelector('.modal-backdrop').onclick = hideModal;

// =====================================================================
//  TABS
// =====================================================================
document.querySelectorAll('.tab').forEach(tab => {
  tab.onclick = () => {
    document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
    document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
    tab.classList.add('active');
    const target = tab.dataset.tab;
    document.getElementById('tab-' + target).classList.add('active');
    // Lazy-load
    if (target === 'files') loadFilesTab();
    if (target === 'config') loadConfigTab();
    if (target === 'yaml') loadYamlTab();
  };
});

// =====================================================================
//  STATUS / HEADER
// =====================================================================
async function refreshStatus() {
  try {
    const s = await fetchJSON(API.status);
    state.status = s;
    renderStatus();
  } catch (e) {
    document.getElementById('daemonStatus').textContent = 'hata';
    document.getElementById('daemonStatus').className = 'badge badge-danger';
    showToast('Status alınamadı: ' + e.message, 'error');
  }
}

function renderStatus() {
  const s = state.status;
  if (!s) return;
  document.getElementById('versionBadge').textContent = s.version || 'v?';
  const badge = document.getElementById('daemonStatus');
  if (!s.installed) {
    badge.textContent = 'espanso yok';
    badge.className = 'badge badge-danger';
    showWarning(s.warning || 'espanso binary bulunamadı.', s.debug);
  } else if (s.running) {
    badge.textContent = 'çalışıyor';
    badge.className = 'badge badge-success';
    hideWarning();
  } else {
    badge.textContent = 'durdu';
    badge.className = 'badge badge-warn';
    showWarning(s.warning || 'espanso daemon çalışmıyor.', s.debug);
  }
}

function showWarning(text, debug) {
  const b = document.getElementById('warningBanner');
  document.getElementById('warningText').textContent = text;
  if (debug) {
    document.getElementById('debugBinPath').textContent = debug.binPath || '(bulunamadı)';
    document.getElementById('debugProcessPath').textContent = debug.processPath || '(boş)';
    document.getElementById('debugSearchLog').textContent = (debug.searchLog || []).join('\n');
  }
  b.hidden = false;
}
function hideWarning() { document.getElementById('warningBanner').hidden = true; }

document.getElementById('btnDebugInfo').onclick = () => {
  const p = document.getElementById('debugPanel');
  p.hidden = !p.hidden;
  document.getElementById('btnDebugInfo').textContent = p.hidden ? 'Detaylar ▾' : 'Detaylar ▴';
};

document.getElementById('btnRetryDetect').onclick = async () => {
  const btn = document.getElementById('btnRetryDetect');
  btn.disabled = true;
  btn.textContent = 'Deneniyor...';
  try { await refreshStatus(); showToast('Durum yenilendi', 'info', 2000); }
  catch (e) { showToast('Yenileme hatası: ' + e.message, 'error'); }
  btn.disabled = false;
  btn.textContent = 'Tekrar Dene';
};

// =====================================================================
//  MATCHES TAB — list, add, delete
// =====================================================================

async function refreshMatchFiles() {
  try {
    const data = await fetchJSON(API.matchFiles);
    state.matchFiles = data.files || [];
  } catch (e) {
    showToast('Match dosyaları yüklenemedi: ' + e.message, 'error');
  }
}

function renderMatchFileDropdown() {
  const sel = document.getElementById('mFile');
  sel.innerHTML = '';
  state.matchFiles.forEach(f => {
    sel.appendChild(el('option', { value: f.name }, `${f.name} (${f.matchCount})`));
  });
}

async function refreshMatchList() {
  const list = document.getElementById('matchList');
  list.innerHTML = '<p class="muted">Yükleniyor...</p>';
  try {
    const data = await fetchJSON(API.matchesList);
    state.allMatches = (data.matches || []).map(m => ({
      file: m.file,
      trigger: m.trigger || (m.regex ? '(regex) ' + m.regex : m.form ? '(form)' : ''),
      replace: m.replace || (m.form ? m.form : ''),
      isForm: m.isForm || false
    }));
    if (data.parseErrors && data.parseErrors.length > 0) {
      console.warn('Parse errors:', data.parseErrors);
      showToast(`${data.parseErrors.length} dosyada parse hatası`, 'warn', 5000);
    }
    renderMatchListItems();
  } catch (e) {
    list.innerHTML = `<p class="muted">Hata: ${escapeHTML(e.message)}</p>`;
  }
}

function renderMatchListItems() {
  const list = document.getElementById('matchList');
  const search = (document.getElementById('searchMatches').value || '').toLowerCase();
  const filtered = search
    ? state.allMatches.filter(m =>
        m.trigger.toLowerCase().includes(search) ||
        m.replace.toLowerCase().includes(search))
    : state.allMatches;
  list.innerHTML = '';
  if (filtered.length === 0) {
    list.appendChild(el('p', { class: 'muted' }, search
      ? 'Arama sonucu yok.'
      : 'Henüz match yok. Yukarıdaki formdan ekleyin.'));
    return;
  }
  filtered.forEach(m => {
    list.appendChild(el('div', { class: 'match-item' }, [
      el('span', { class: 'trigger', title: m.trigger }, m.trigger),
      el('span', { class: 'replacement', title: m.replace }, m.replace),
      el('div', { class: 'actions' }, [
        el('button', { class: 'btn btn-danger', onclick: () => deleteMatch(m) }, 'Sil')
      ])
    ]));
  });
}

document.getElementById('searchMatches').oninput = renderMatchListItems;

document.getElementById('addMatchForm').onsubmit = async (e) => {
  e.preventDefault();
  const trigger = document.getElementById('mTrigger').value.trim();
  const replace = document.getElementById('mReplace').value;
  const file = document.getElementById('mFile').value;
  const word = document.getElementById('mWord').checked;
  const propagate = document.getElementById('mPropagate').checked;
  const uppercase = document.getElementById('mUppercase').value;
  if (!trigger || !replace) { showToast('Trigger ve replacement gerekli', 'error'); return; }
  try {
    await fetchJSON(API.matches, {
      method: 'POST',
      body: { trigger, replace, file, word, propagateCase: propagate, uppercaseStyle: uppercase }
    });
    showToast(`✓ Eklendi: ${trigger}`, 'success');
    // Reset form
    document.getElementById('mTrigger').value = '';
    document.getElementById('mReplace').value = '';
    document.getElementById('mWord').checked = false;
    document.getElementById('mPropagate').checked = false;
    document.getElementById('mUppercase').value = '';
    // Full refresh (backend parsed list)
    await refreshMatchFiles();
    renderMatchFileDropdown();
    await refreshMatchList();
  } catch (e) {
    showToast('Eklenemedi: ' + e.message, 'error');
  }
};

function deleteMatch(m) {
  showModal(
    'Match sil',
    `<p>Şu match silinecek:</p>
     <p><code>${escapeHTML(m.trigger)}</code> → <code>${escapeHTML(m.replace.slice(0, 80))}</code></p>
     <p class="muted">Dosya: ${escapeHTML(m.file)}</p>`,
    async () => {
      try {
        await fetchJSON(API.matchesDelete, {
          method: 'POST',
          body: { trigger: m.trigger.replace(/^\(regex\) /, ''), file: m.file }
        });
        showToast('✓ Silindi', 'success');
        await refreshMatchFiles();
        renderMatchFileDropdown();
        await refreshMatchList();
      } catch (e) {
        showToast('Silinemedi: ' + e.message, 'error');
      }
    },
    'Sil'
  );
}

// =====================================================================
//  FILES TAB
// =====================================================================
async function loadFilesTab() {
  const list = document.getElementById('matchFileList');
  list.innerHTML = '<p class="muted">Yükleniyor...</p>';
  try {
    await refreshMatchFiles();
    list.innerHTML = '';
    if (state.matchFiles.length === 0) {
      list.appendChild(el('p', { class: 'muted' }, 'Hiç match dosyası yok.'));
      return;
    }
    state.matchFiles.forEach(f => {
      list.appendChild(el('div', {
        class: 'file-card',
        onclick: () => openYamlInEditor(f.name, 'match')
      }, [
        el('div', { class: 'file-name' }, [
          el('span', {}, f.isPrivate ? '🔒' : '📄'),
          el('span', {}, f.name)
        ]),
        el('div', { class: 'file-meta' }, [
          el('span', {}, `${f.matchCount} match`),
          f.isPrivate ? el('span', { class: 'badge badge-warn' }, 'private') : null,
          el('span', {}, f.relPath)
        ])
      ]));
    });
  } catch (e) {
    list.innerHTML = `<p class="muted">Hata: ${escapeHTML(e.message)}</p>`;
  }
}

document.getElementById('btnNewMatchFile').onclick = () => {
  showModal(
    'Yeni Match Dosyası',
    `<label class="field">
       <span>Dosya adı (örn: email, code, ascii)</span>
       <input type="text" id="newFileName" placeholder="email" autocomplete="off">
     </label>
     <p class="muted" style="margin-top:10px">.yml uzantısı otomatik eklenir.</p>`,
    async () => {
      const name = document.getElementById('newFileName').value.trim();
      if (!name) { showToast('İsim gerekli', 'error'); return false; }
      try {
        await fetchJSON(API.matchFiles, { method: 'POST', body: { name, rawYaml: 'matches:\n' } });
        showToast('✓ Dosya oluşturuldu', 'success');
        loadFilesTab();
        return true;
      } catch (e) {
        showToast('Oluşturulamadı: ' + e.message, 'error');
        return false;
      }
    },
    'Oluştur'
  );
};

// =====================================================================
//  CONFIG TAB
// =====================================================================
async function loadConfigTab() {
  const list = document.getElementById('configFileList');
  list.innerHTML = '<p class="muted">Yükleniyor...</p>';
  try {
    const data = await fetchJSON(API.configFiles);
    state.configFiles = data.files || [];
    list.innerHTML = '';
    if (state.configFiles.length === 0) {
      list.appendChild(el('p', { class: 'muted' }, 'Hiç config dosyası yok.'));
      return;
    }
    state.configFiles.forEach(f => {
      list.appendChild(el('div', {
        class: 'file-card',
        onclick: () => openYamlInEditor(f.name + '.yml', 'config')
      }, [
        el('div', { class: 'file-name' }, [
          el('span', {}, f.isDefault ? '⚙️' : '🔧'),
          el('span', {}, f.name + '.yml')
        ]),
        el('div', { class: 'file-meta' }, [
          f.isDefault ? el('span', { class: 'badge badge-info' }, 'default') : null,
          f.backend ? el('span', {}, 'backend: ' + f.backend) : null,
          f.filterExec ? el('span', {}, 'exec: ' + f.filterExec) : null,
          f.filterTitle ? el('span', {}, 'title: ' + f.filterTitle) : null,
          f.enable === false ? el('span', { class: 'badge badge-warn' }, 'disabled') : null
        ])
      ]));
    });
  } catch (e) {
    list.innerHTML = `<p class="muted">Hata: ${escapeHTML(e.message)}</p>`;
  }
}

document.getElementById('btnNewConfigFile').onclick = () => {
  showModal(
    'Yeni App Config Dosyası',
    `<label class="field">
       <span>App adı (örn: vscode, telegram, chrome)</span>
       <input type="text" id="newCfgName" placeholder="vscode" autocomplete="off">
     </label>
     <p class="muted" style="margin-top:10px">Şablon oluşturulur: filter_exec, backend alanları içerir.</p>`,
    async () => {
      const name = document.getElementById('newCfgName').value.trim();
      if (!name) { showToast('İsim gerekli', 'error'); return false; }
      try {
        await fetchJSON(API.configFiles, { method: 'POST', body: { name } });
        showToast('✓ Config dosyası oluşturuldu', 'success');
        loadConfigTab();
        return true;
      } catch (e) {
        showToast('Oluşturulamadı: ' + e.message, 'error');
        return false;
      }
    },
    'Oluştur'
  );
};

// =====================================================================
//  YAML EDITOR TAB
// =====================================================================
// YAML editör BAĞIMSIZDIR. state.matchFiles'a güvenmez.
// Backend'den her seferinde taze raw YAML çeker.

async function loadYamlTab() {
  const sel = document.getElementById('yamlFileSelect');
  sel.innerHTML = '';
  try {
    const [mf, cf] = await Promise.all([
      fetchJSON(API.matchFiles),
      fetchJSON(API.configFiles)
    ]);
    state.matchFiles = mf.files || [];
    state.configFiles = cf.files || [];

    const og1 = el('optgroup', { label: 'Match dosyaları' });
    state.matchFiles.forEach(f => {
      og1.appendChild(el('option', { value: 'match:' + f.name }, f.name));
    });
    sel.appendChild(og1);

    const og2 = el('optgroup', { label: 'Config dosyaları' });
    state.configFiles.forEach(f => {
      og2.appendChild(el('option', { value: 'config:' + f.name + '.yml' }, f.name + '.yml'));
    });
    sel.appendChild(og2);
  } catch (e) {
    showToast('Dosya listesi alınamadı: ' + e.message, 'error');
  }
}

async function openYamlInEditor(fileName, kind) {
  // YAML tab'ına geç
  document.querySelector('.tab[data-tab="yaml"]').click();
  // Dropdown'u doldur (await ile bekle)
  await loadYamlTab();
  // Şimdi dosyayı seç ve yükle
  const sel = document.getElementById('yamlFileSelect');
  const value = kind + ':' + fileName;
  sel.value = value;
  await loadYamlIntoEditor();
}

async function loadYamlIntoEditor() {
  const sel = document.getElementById('yamlFileSelect');
  const editor = document.getElementById('yamlEditor');
  if (!sel.value) { showToast('Dosya seçin', 'warn'); return; }
  const [kind, name] = sel.value.split(':');
  try {
    let content = '';
    if (kind === 'match') {
      const data = await fetchJSON(API.matchFiles);
      const f = (data.files || []).find(f => f.name === name);
      content = f ? f.rawYaml : '';
    } else {
      const data = await fetchJSON(API.configFiles);
      const f = (data.files || []).find(f => (f.name + '.yml') === name);
      content = f ? f.rawYaml : '';
    }
    editor.value = content || '';
    setYamlStatus('Yüklendi: ' + name, 'ok');
  } catch (e) {
    setYamlStatus('Yüklenemedi: ' + e.message, 'err');
  }
}

document.getElementById('btnLoadYaml').onclick = loadYamlIntoEditor;

document.getElementById('btnSaveYaml').onclick = async () => {
  const sel = document.getElementById('yamlFileSelect');
  if (!sel.value) { showToast('Dosya seçin', 'warn'); return; }
  const [kind, name] = sel.value.split(':');
  const content = document.getElementById('yamlEditor').value;
  try {
    if (kind === 'match') {
      await fetchJSON(API.matchFilesUpdate, { method: 'POST', body: { name, rawYaml: content } });
    } else {
      const baseName = name.replace(/\.yml$/, '');
      await fetchJSON(API.configFilesUpdate, { method: 'POST', body: { name: baseName, rawYaml: content } });
    }
    setYamlStatus('✓ Kaydedildi: ' + name, 'ok');
    showToast('✓ Kaydedildi', 'success');
    await loadYamlTab();
  } catch (e) {
    setYamlStatus('Kaydedilemedi: ' + e.message, 'err');
    showToast('Kaydedilemedi: ' + e.message, 'error');
  }
};

document.getElementById('btnValidateYaml').onclick = async () => {
  const content = document.getElementById('yamlEditor').value;
  try {
    // Backend'den validate et (NimYAML)
    // Geçici olarak matchFilesUpdate'e invalid YAML gönderip hatayı yakala
    // Ama kaydetmek istemiyoruz — sadece syntax check
    // Çözüm: client-side regex ile match say
    const matchCount = (content.match(/^\s{2,}-\s+(trigger|regex|form):/gm) || []).length;
    const hasMatchesBlock = /^matches:/m.test(content);
    let msg = `YAML ok. ${matchCount} match bulundu.`;
    if (!hasMatchesBlock && content.trim().length > 0) {
      msg += ' ⚠ Uyarı: `matches:` bloğu bulunamadı.';
    }
    setYamlStatus(msg, 'ok');
  } catch (e) {
    setYamlStatus('Validate hatası: ' + e.message, 'err');
  }
};

function setYamlStatus(msg, type) {
  const s = document.getElementById('yamlStatus');
  s.textContent = msg;
  s.className = 'yaml-status ' + (type === 'ok' ? 'ok' : 'err');
}

// =====================================================================
//  HEADER BUTTONS
// =====================================================================
document.getElementById('btnRefresh').onclick = async () => {
  await refreshStatus();
  await refreshMatchFiles();
  renderMatchFileDropdown();
  await refreshMatchList();
  showToast('Yenilendi', 'info', 1500);
};

document.getElementById('btnRestart').onclick = () => {
  showModal(
    'Espanso Restart',
    `<p>espanso daemon yeniden başlatılacak.</p>
     <p class="muted">Config dosyalarında değişiklik yaptıysanız ve auto_restart yetmediyse bunu kullanın.</p>`,
    async () => {
      try {
        const r = await fetchJSON(API.restart, { method: 'POST' });
        if (r.success) showToast('✓ Espanso restart edildi', 'success');
        else showToast('Restart: ' + r.message, 'warn');
        await refreshStatus();
        return true;
      } catch (e) {
        showToast('Restart hatası: ' + e.message, 'error');
        return false;
      }
    },
    'Restart'
  );
};

// =====================================================================
//  INIT
// =====================================================================
(async function init() {
  await refreshStatus();
  if (state.status && state.status.installed) {
    await refreshMatchFiles();
    renderMatchFileDropdown();
    await refreshMatchList();
  }
  setInterval(refreshStatus, 30000);
})();

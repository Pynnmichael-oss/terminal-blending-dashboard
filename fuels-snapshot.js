const TANK_ID_MAP = {
  "23155":"TK55", "23156":"TK56", "23157":"TK57", "23158":"TK58",
  "27403":"TK03", "27404":"TK04", "27405":"TK05", "31487":"TK87"
};
const SNAPSHOT_KEY = "gp_fuelsManagerSnapshot";

function parseFuelsManagerFile(arrayBuffer) {
  const wb = XLSX.read(arrayBuffer, { type: 'array' });
  const sheet = wb.Sheets[wb.SheetNames[0]];
  const rows = XLSX.utils.sheet_to_json(sheet);
  const groups = {};
  rows.forEach(row => {
    const m = String(row.Tank || '').match(/(\d+)/);
    if (!m) return;
    const mapped = TANK_ID_MAP[m[1]];
    if (!mapped) return;
    (groups[mapped] = groups[mapped] || []).push(row);
  });
  const byTank = {};
  Object.values(TANK_ID_MAP).forEach(tankId => {
    const tankRows = (groups[tankId] || []).slice().sort((a, b) => new Date(b.PulledAt) - new Date(a.PulledAt));
    let picked = null, skippedBadRows = 0;
    for (const row of tankRows) {
      const available = Number(row.Available);
      const workingCap = Number(row.WorkingCap);
      if (available > 0 && available <= workingCap * 1.2) { picked = row; break; }
      skippedBadRows++;
    }
    byTank[tankId] = picked ? {
      available: picked.Available,
      workingCap: picked.WorkingCap,
      product: picked.Product || '',
      pulledAt: picked.PulledAt,
      skippedBadRows
    } : null;
  });
  return byTank;
}

function saveSnapshot(byTank) {
  localStorage.setItem(SNAPSHOT_KEY, JSON.stringify({ tanks: byTank, confirmedAt: new Date().toISOString() }));
}

function loadSnapshot() {
  try {
    const raw = localStorage.getItem(SNAPSHOT_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== 'object' || !parsed.tanks) return null;
    return parsed;
  } catch (_) {
    return null;
  }
}

async function syncLiveTankSnapshot() {
  try {
    const response = await fetch(`data/tanks.json?ts=${Date.now()}`, { cache: 'no-store' });
    if (!response.ok) throw new Error(`Tank feed returned ${response.status}`);
    const snapshot = await response.json();
    if (!snapshot || typeof snapshot !== 'object' || !snapshot.tanks) return null;
    localStorage.setItem(SNAPSHOT_KEY, JSON.stringify(snapshot));
    return snapshot;
  } catch (error) {
    console.warn('Live tank feed unavailable; using saved snapshot.', error);
    return loadSnapshot();
  }
}

function applyLiveTankDetails(snapshot) {
  if (!snapshot || !snapshot.tanks) return;
  Object.entries(snapshot.tanks).forEach(([tankId, entry]) => {
    if (!entry) return;
    try {
      if (typeof TANK_FARM_ORIGINAL !== 'undefined' && entry.workingCap > 0 && TANK_FARM_ORIGINAL[tankId]) {
        TANK_FARM_ORIGINAL[tankId].capacity = Number(entry.workingCap);
      }
    } catch (_) {}

    const tankEl = document.querySelector(`.farm .tank[data-tank="${tankId}"]`);
    if (!tankEl) return;

    const product = String(entry.product || '').toUpperCase();
    const groupEl = tankEl.querySelector('.grp');
    const fillEl = tankEl.querySelector('.fill');
    if (groupEl && product) groupEl.textContent = product === 'REGULAR' ? 'Regular' : product;
    if (fillEl) {
      fillEl.classList.remove('reg', 'prem', 'ulsd');
      fillEl.classList.add(product.includes('ULSD') ? 'ulsd' : product.includes('PREM') ? 'prem' : 'reg');
    }

    const statusEl = tankEl.querySelector('.st');
    if (statusEl && entry.tankCommand) {
      const running = String(entry.tankCommand).toLowerCase() === 'run';
      statusEl.textContent = entry.tankCommand;
      statusEl.classList.toggle('run', running);
      statusEl.classList.toggle('stop', !running);
    }
  });
}

window.addEventListener('DOMContentLoaded', () => {
  syncLiveTankSnapshot().then(snapshot => {
    if (!snapshot) return;
    applyLiveTankDetails(snapshot);
    if (typeof renderTankFarm === 'function') renderTankFarm();
  });
});

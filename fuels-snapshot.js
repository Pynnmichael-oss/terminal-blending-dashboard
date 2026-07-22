const TANK_ID_MAP = { "23155":"TK55", "23156":"TK56", "27403":"TK03", "27404":"TK04", "27405":"TK05" };
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
      if (available > 0 && available <= workingCap * 1.2) {
        picked = row;
        break;
      }
      skippedBadRows++;
    }
    byTank[tankId] = picked ? { available: picked.Available, pulledAt: picked.PulledAt, skippedBadRows } : null;
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

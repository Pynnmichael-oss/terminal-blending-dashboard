const T4_KEY = "gp_t4Schedule";
const GRADE_PRODUCT = {"4D":"REG","3D":"PREM","75":"ULSD"};

function parseT4Paste(text){
  const lines = text.trim().split('\n').filter(l => l.trim());
  const batches = [];
  let skipped = 0;
  lines.forEach(line => {
    const cols = line.split('\t');
    if (cols.length < 15) { skipped++; return; }
    if (/^Start Date/i.test(cols[0])) return; // header row, not a skip
    const dt = cols[0], lineId = cols[1], batchCode = cols[5];
    const vol = parseFloat((cols[12]||'').replace(/,/g,''));
    const rate = parseFloat((cols[14]||'').replace(/,/g,''));
    if (!batchCode || isNaN(vol) || isNaN(rate)) { skipped++; return; }
    const parts = batchCode.split('-');
    const grade = parts[2];
    if (!GRADE_PRODUCT[grade]) { skipped++; return; }
    const s = normalizeDateTime(dt);
    if (!s) { skipped++; return; }
    batches.push({s, line: lineId, code: batchCode, vol, rate});
  });
  return {batches, skipped};
}
function normalizeDateTime(s){
  const m = s.trim().match(/^(\d{2})\/(\d{2})\/(\d{2})\s+(\d{2}):(\d{2})$/);
  if (!m) return null;
  const [, mm, dd, yy, hh, min] = m;
  return `20${yy}-${mm}-${dd}T${hh}:${min}:00`;
}
function saveT4(batches){
  localStorage.setItem(T4_KEY, JSON.stringify({batches, confirmedAt: new Date().toISOString()}));
}
function loadT4(){
  try{
    const raw = localStorage.getItem(T4_KEY);
    if(!raw) return null;
    const parsed = JSON.parse(raw);
    if(!parsed || !Array.isArray(parsed.batches)) return null;
    return parsed;
  }catch(_){ return null; }
}

const T4_KEY = "gp_t4Schedule";
const GRADE_PRODUCT = {"4D":"REG","3D":"PREM","75":"ULSD"};

// Row-start signature: Start Date, Line #, Ver #, then an Evt Loc code (e.g. "FM1").
// This pattern only occurs once per row (the row's own "Date Created" field is followed
// by a username, not by Line/Ver/Evt-Loc numbers), so it reliably marks each new row
// regardless of whether rows are separated by newlines (Excel paste) or run together
// with no line breaks at all (pasting an HTML table straight from an email).
const ROW_START = /(\d{2}\/\d{2}\/\d{2}\s+\d{2}:\d{2})\s+(\d+)\s+(\d+)\s+([A-Z0-9]{2,6})\b/g;
const BATCH_CODE = /\b([A-Z]{2,5}-[A-Z]{2,5}-[A-Z0-9]{2,3}-\d{2,4}(?:-[A-Z]{2,5})?)\b/;
const VOL_RATE = /([\d,]+\.?\d*)\s+Bbls\s+([\d,]+\.?\d*)/i;

function parseT4Paste(text){
  const raw = (text || '').replace(/\r\n?/g, '\n');
  const batches = [];
  let skipped = 0;
  if (!raw.trim()) return {batches, skipped};

  const starts = [];
  let m;
  ROW_START.lastIndex = 0;
  while ((m = ROW_START.exec(raw))) {
    starts.push({index: m.index, dt: m[1], line: m[2]});
  }
  if (starts.length === 0) return {batches, skipped: 1};

  for (let i = 0; i < starts.length; i++) {
    const chunkStart = starts[i].index;
    const chunkEnd = i + 1 < starts.length ? starts[i + 1].index : raw.length;
    const chunk = raw.slice(chunkStart, chunkEnd);

    const batchMatch = chunk.match(BATCH_CODE);
    const volRateMatch = chunk.match(VOL_RATE);
    if (!batchMatch || !volRateMatch) { skipped++; continue; }

    const batchCode = batchMatch[1];
    const vol = parseFloat(volRateMatch[1].replace(/,/g, ''));
    const rate = parseFloat(volRateMatch[2].replace(/,/g, ''));
    if (isNaN(vol) || isNaN(rate)) { skipped++; continue; }

    const grade = batchCode.split('-')[2];
    if (!GRADE_PRODUCT[grade]) { skipped++; continue; }

    const s = normalizeDateTime(starts[i].dt);
    if (!s) { skipped++; continue; }

    batches.push({s, line: starts[i].line, code: batchCode, vol, rate});
  }
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

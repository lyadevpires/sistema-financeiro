// Leitura de extrato bancário e fatura de cartão (CSV/Excel já convertidos em tabela).
// Funções puras, sem DOM e sem rede: testadas em tests/parser.test.mjs.
const pad = n => String(n).padStart(2, '0');
const iso = d => `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`;
export const semAcento = s => String(s ?? '').normalize('NFD').replace(/[̀-ͯ]/g,'').toLowerCase().trim();

// Número brasileiro ou americano, com sinal no começo, no fim ("1.234,56-"),
// entre parênteses ou com D/C (como o Itaú escreve).
export function parseNum(v){
  if (typeof v === 'number') return v;
  let s = String(v ?? '').trim(); if (!s) return NaN;
  const neg = /^-|-$|^\(.*\)$|\bD$/i.test(s);
  s = s.replace(/[^\d,.]/g, '');
  if (!s) return NaN;
  if (s.includes(',') && s.includes('.')) s = s.lastIndexOf(',') > s.lastIndexOf('.') ? s.replace(/\./g,'').replace(',', '.') : s.replace(/,/g, '');
  else if (s.includes(',')) s = s.replace(/\./g,'').replace(',', '.');
  else if ((s.match(/\./g) || []).length > 1) s = s.replace(/\.(?=.*\.)/g, '');
  const n = Number(s); return isNaN(n) ? NaN : (neg ? -Math.abs(n) : n);
}
const MES_ABR = { jan:1, fev:2, mar:3, abr:4, mai:5, jun:6, jul:7, ago:8, set:9, out:10, nov:11, dez:12 };
export function parseData(v, ano){
  if (v instanceof Date && !isNaN(v)) { const d = new Date(v.getTime() + 12*3600e3); return iso(d); }
  if (typeof v === 'number' && v > 20000 && v < 80000) { const d = new Date(Date.UTC(1899, 11, 30) + v * 864e5); return `${d.getUTCFullYear()}-${pad(d.getUTCMonth()+1)}-${pad(d.getUTCDate())}`; }
  const s = semAcento(v);
  let m = s.match(/^(\d{4})-(\d{2})-(\d{2})/); if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = s.match(/^(\d{1,2})[\/.-](\d{1,2})(?:[\/.-](\d{2,4}))?$/) || s.match(/^(\d{1,2})[\/.-](\d{1,2})(?:[\/.-](\d{2,4}))?\b/);
  if (m) { let y = m[3] ? +m[3] : ano; if (y < 100) y += 2000; const d = +m[1], mo = +m[2]; if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) return `${y}-${pad(mo)}-${pad(d)}`; }
  m = s.match(/^(\d{1,2})\s*(?:de\s*)?([a-z]{3})[a-z]*\.?(?:\s*(?:de\s*)?(\d{2,4}))?/);
  if (m && MES_ABR[m[2]]) { let y = m[3] ? +m[3] : ano; if (y < 100) y += 2000; return `${y}-${pad(MES_ABR[m[2]])}-${pad(+m[1])}`; }
  return null;
}
export function parseCSV(text){
  const sep = (text.split('\n').slice(0, 10).join('\n').match(/;/g) || []).length > (text.split('\n').slice(0, 10).join('\n').match(/,/g) || []).length / 2 ? ';' : (text.includes('\t') ? '\t' : ',');
  const rows = []; let row = [], cell = '', q = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i+1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; continue; }
    if (c === '"') q = true; else if (c === sep) { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i+1] === '\n') i++; row.push(cell); rows.push(row); row = []; cell = ''; }
    else cell += c;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }
  return rows;
}
export const PULAR = /^(saldo\b|s\s?a\s?l\s?d\s?o|saldo anterior|saldo do dia|saldo final|saldo total|total\b|lancamentos futuros|sdo)/;
// Transforma uma tabela (linhas × colunas) em lançamentos de extrato.
// Procura a linha de cabeçalho; se não achar, deduz as colunas pelo conteúdo.
export function tabelaParaExtrato(rows, ano){
  rows = rows.map(r => r.map(c => c instanceof Date ? c : (c ?? '')));
  let h = -1, col = {};
  for (let i = 0; i < Math.min(rows.length, 40); i++) {
    const n = rows[i].map(semAcento);
    const achaData = n.findIndex(c => /^data\b|^dt\b|^date/.test(c));
    const achaValor = n.findIndex(c => /^valor|credito|debito|entrada|saida|^amount/.test(c));
    if (achaData >= 0 && achaValor >= 0) {
      h = i;
      const idx = re => n.findIndex(c => re.test(c));
      col = { data: achaData, desc: idx(/lancamento|descricao|historico|estabelecimento|detalhe|^description|^memo/),
              doc: idx(/^doc|documento|^n[ºo°]/), valor: idx(/^valor|^amount/), credito: idx(/credito|entrada/),
              debito: idx(/debito|saida/), saldo: idx(/^saldo/) };
      break;
    }
  }
  if (h < 0) {
    const amostra = rows.slice(0, 60);
    const ncol = Math.max(...amostra.map(r => r.length));
    const conta = f => [...Array(ncol).keys()].map(j => amostra.filter(r => f(r[j])).length);
    const datas = conta(v => parseData(v, ano)), nums = conta(v => typeof v === 'number' || /\d,\d{2}-?\s*[DC]?$/i.test(String(v))), textos = conta(v => typeof v === 'string' && /[a-z]{3}/i.test(v) && !parseData(v, ano));
    const best = arr => arr.indexOf(Math.max(...arr));
    col = { data: best(datas), valor: best(nums.map((n, j) => j === best(datas) ? -1 : n)), desc: best(textos), doc: -1, credito: -1, debito: -1, saldo: -1 };
    const numCols = nums.map((n, j) => [n, j]).filter(([n, j]) => n > amostra.length / 3 && j !== col.data).map(([, j]) => j);
    if (numCols.length >= 2) { col.valor = numCols[0]; col.saldo = numCols[numCols.length - 1]; }
  }
  const out = [], avisos = [];
  for (let i = h + 1; i < rows.length; i++) {
    const r = rows[i]; const data = parseData(r[col.data], ano); if (!data) continue;
    const desc = String(r[col.desc] ?? '').replace(/\s+/g, ' ').trim();
    if (!desc || PULAR.test(semAcento(desc))) continue;
    let valor;
    if (col.valor >= 0 && String(r[col.valor]).trim() !== '') valor = parseNum(r[col.valor]);
    else { const c = col.credito >= 0 ? parseNum(r[col.credito]) : NaN, d = col.debito >= 0 ? parseNum(r[col.debito]) : NaN;
      valor = (isNaN(c) ? 0 : Math.abs(c)) - (isNaN(d) ? 0 : Math.abs(d)); }
    if (!valor || isNaN(valor)) continue;
    const saldo = col.saldo >= 0 ? parseNum(r[col.saldo]) : NaN;
    out.push({ data, descricao: desc, documento: col.doc >= 0 ? String(r[col.doc] ?? '').trim() || null : null, valor: Math.round(valor * 100) / 100, saldo: isNaN(saldo) ? null : saldo });
  }
  if (h < 0) avisos.push('Não encontrei cabeçalho no arquivo; deduzi as colunas pelo conteúdo. Confira a prévia.');
  return { linhas: out, avisos };
}
// Chave que identifica a linha: reimportar um período que se sobrepõe não duplica.
export function chavesExtrato(linhas){
  const vistos = {};
  return linhas.map(l => { const k = `${l.data}|${l.valor.toFixed(2)}|${semAcento(l.descricao).replace(/\s+/g,' ')}|${l.documento || ''}`; vistos[k] = (vistos[k] || 0) + 1; return `${k}#${vistos[k]}`; });
}


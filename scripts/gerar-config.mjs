// Gera public/config.js a partir das variáveis de ambiente.
// Na Vercel: Project Settings → Environment Variables → SUPABASE_URL e SUPABASE_ANON_KEY.
// Local: crie um arquivo .env (veja .env.example) ou exporte as variáveis.
import { writeFileSync, existsSync, readFileSync } from 'node:fs';

if (existsSync('.env')) {
  for (const linha of readFileSync('.env', 'utf8').split('\n')) {
    const m = linha.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, '');
  }
}
// Colar ou enviar pelo PowerShell costuma trazer BOM e quebra de linha; o navegador recusa isso no cabeçalho da requisição.
const limpa = v => (v || '').replace(/^﻿/, '').trim();
const url = limpa(process.env.SUPABASE_URL);
const anonKey = limpa(process.env.SUPABASE_ANON_KEY);
if (/[^\x21-\x7E]/.test(url + anonKey)) {
  console.error('SUPABASE_URL ou SUPABASE_ANON_KEY tem caractere invisível ou acentuado. Cole o valor de novo, sem espaços.');
  process.exit(1);
}
if (!url || !anonKey) {
  const msg = 'SUPABASE_URL e/ou SUPABASE_ANON_KEY não definidas.';
  if (process.env.VERCEL) { console.error(msg + ' Configure em Project Settings → Environment Variables.'); process.exit(1); }
  console.warn(msg + ' O app vai pedir os dados na tela (modo local).');
}
if (/service_role/.test(Buffer.from((anonKey.split('.')[1] || ''), 'base64').toString())) {
  console.error('Isto é a service_role key. Use a anon key: a service_role ignora o RLS e não pode ir para o navegador.');
  process.exit(1);
}
writeFileSync('public/config.js', url && anonKey ? `window.__FIN_CONFIG = ${JSON.stringify({ url, anonKey })};\n` : '');
console.log('public/config.js gerado' + (url ? ` para ${url}` : ' (vazio)'));

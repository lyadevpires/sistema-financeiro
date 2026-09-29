// Roda um ou mais arquivos .sql num Postgres (substitui o psql, que o Windows bloqueia nesta máquina).
//   npm run carregar -- dados-privados/01-cadastros.sql dados-privados/02-historico-2026.sql
// A connection string é pedida na tela (não fica no histórico do terminal nem em arquivo).
// Se preferir, defina SUPABASE_DB_URL antes. Painel do Supabase → Connect → Session pooler (porta 5432).
// Cada arquivo roda inteiro de uma vez: se der erro, nada daquele arquivo fica gravado.
import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline/promises';
import pg from 'pg';

const arquivos = process.argv.slice(2);
if (!arquivos.length) {
  console.error('Informe os arquivos: npm run carregar -- dados-privados/01-cadastros.sql');
  process.exit(1);
}

const tela = createInterface({ input: process.stdin, output: process.stdout });
const url = process.env.SUPABASE_DB_URL || (await tela.question('Connection string do banco (Session pooler): ')).trim();
let destino;
try {
  const u = new URL(url);
  destino = `${u.username}@${u.hostname}:${u.port || 5432}${u.pathname}`;
} catch {
  console.error('Connection string inválida. Copie de: Supabase → Connect → Session pooler.');
  process.exit(1);
}

console.log(`\nDestino: ${destino}`);
for (const f of arquivos) console.log(`  • ${f}`);
if ((await tela.question('Digite SIM para carregar: ')).trim().toLowerCase() !== 'sim') {
  console.log('Cancelado.');
  process.exit(0);
}
tela.close();

// O pooler do Supabase usa um certificado da própria Supabase, fora da lista do Node: criptografa sem validar a cadeia.
const cliente = new pg.Client({ connectionString: url.replace(/[?&]sslmode=[^&]*/, ''), ssl: { rejectUnauthorized: false } });
try {
  await cliente.connect();
} catch (e) {
  const motivo = {
    '28P01': 'senha incorreta. Confira a senha do banco (Project Settings → Database → Reset password para trocar).',
    'ENOTFOUND': 'endereço do servidor não encontrado. Confira a connection string.',
    'ETIMEDOUT': 'o servidor não respondeu. Confira a porta (5432) e a internet.',
  }[e.code] || e.message;
  console.error(`Não conectou: ${motivo}\nNada foi gravado.`);
  process.exit(1);
}
try {
  for (const f of arquivos) {
    const sql = readFileSync(f, 'utf8');
    const inicio = Date.now();
    process.stdout.write(`Carregando ${f}... `);
    try {
      // Com begin/commit no arquivo, a transação é dele; sem, o Postgres roda o texto todo como uma transação só.
      await cliente.query(sql);
    } catch (e) {
      await cliente.query('rollback').catch(() => {});
      console.log('ERRO');
      console.error(`${e.message}${e.position ? ` (posição ${e.position} do arquivo)` : ''}\nNada deste arquivo foi gravado.`);
      process.exitCode = 1;
      break;
    }
    console.log(`ok (${((Date.now() - inicio) / 1000).toFixed(1)}s)`);
  }
  if (!process.exitCode) {
    const { rows } = await cliente.query(`
      select 'fornecedores' as tabela, count(*) from fornecedores union all
      select 'categorias', count(*) from categorias union all
      select 'contas_bancarias', count(*) from contas_bancarias union all
      select 'recorrencias', count(*) from recorrencias union all
      select 'lancamentos', count(*) from lancamentos`);
    console.table(rows);
  }
} finally {
  await cliente.end();
}

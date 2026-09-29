// Modo demonstração — SÓ em localhost com ?demo na URL (ver index.html).
// Imita o cliente do Supabase com dados FICTÍCIOS em memória, para revisar telas sem login
// e sem tocar no banco. Nada aqui vai para o Supabase; nenhum dado real.

const pad = n => String(n).padStart(2, '0');
const iso = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const hoje = new Date();
const mesesAtras = n => new Date(hoje.getFullYear(), hoje.getMonth() - n, 1);
let seq = 0;
const id = () => 'demo-' + (++seq);
// gerador pseudoaleatório fixo: as telas ficam iguais a cada recarga
let semente = 42;
const rnd = () => (semente = (semente * 16807) % 2147483647) / 2147483647;
const varia = (v, p = 0.12) => Math.round(v * (1 + (rnd() * 2 - 1) * p) * 100) / 100;

const categorias = [
  ['Vendas plataforma', 'receita', 'Receitas'], ['Mentorias', 'receita', 'Receitas'], ['Patrocínios', 'receita', 'Receitas'],
  ['Rendimentos', 'receita', 'Financeiro'],
  ['Anúncios redes sociais', 'despesa', 'Marketing e aquisição'], ['Anúncios busca', 'despesa', 'Marketing e aquisição'],
  ['Prestadores PJ', 'despesa', 'Pessoas'], ['Salários', 'despesa', 'Pessoas'], ['Pró-labore', 'despesa', 'Pessoas'], ['Benefícios', 'despesa', 'Pessoas'],
  ['Impostos sobre vendas', 'despesa', 'Impostos'], ['IRPJ e CSLL', 'despesa', 'Impostos'],
  ['Local de eventos', 'despesa', 'Eventos'], ['Alimentação eventos', 'despesa', 'Eventos'],
  ['Sistemas e cloud', 'despesa', 'Tecnologia e sistemas'], ['Aluguel', 'despesa', 'Estrutura e escritório'], ['Contabilidade', 'despesa', 'Serviços profissionais'],
  ['Tarifas bancárias', 'despesa', 'Financeiro'], ['Transferência', 'neutra', 'Movimentações (fora do resultado)'],
].map(([nome, tipo, grupo]) => ({ id: id(), nome, tipo, grupo, ativo: true }));
const cat = n => categorias.find(c => c.nome === n);
const contas = [
  { id: id(), nome: 'Banco Azul', tipo: 'corrente', saldo_inicial: 1800000, data_saldo_inicial: iso(mesesAtras(9)), ativo: true },
  { id: id(), nome: 'Banco Verde', tipo: 'corrente', saldo_inicial: 900000, data_saldo_inicial: iso(mesesAtras(9)), ativo: true },
  { id: id(), nome: 'Cartão final 0001', tipo: 'cartao', saldo_inicial: 0, ativo: true },
];
const fornecedores = ['Plataforma de Vendas', 'Rede Social Ads', 'Buscador Ads', 'Fulano Prestador PJ', 'Ciclana Prestadora PJ', 'Imobiliária Exemplo', 'Contábil Exemplo', 'Hotel Eventos Exemplo']
  .map(nome => ({ id: id(), nome, tipo: /PJ/.test(nome) ? 'pj' : 'fornecedor', ativo: true }));
const forn = n => fornecedores.find(f => f.nome === n);
const centros = ['Marketing', 'Produto', 'Administrativo'].map(nome => ({ id: id(), nome, ativo: true }));

// lançamentos: 9 meses pagos + 3 previstos
const lancamentos = [];
const add = (tipo, descricao, valor, catNome, dia, m, extra = {}) => {
  const comp = mesesAtras(m), venc = new Date(comp.getFullYear(), comp.getMonth(), Math.min(dia, 28));
  const pago = venc <= hoje && m > 0 ? true : venc < new Date(hoje.getFullYear(), hoje.getMonth(), hoje.getDate() - 3);
  const c = cat(catNome);
  lancamentos.push({ id: id(), tipo, descricao, valor: Math.abs(valor), categoria_id: c.id, categoria: c.nome, categoria_tipo: c.tipo, categoria_grupo: c.grupo,
    conta_id: contas[tipo === 'receber' ? 0 : (rnd() > .5 ? 0 : 1)].id, data_competencia: iso(comp), data_vencimento: iso(venc),
    data_pagamento: pago ? iso(venc) : null, status: pago ? 'pago' : 'previsto', fatura_id: null, tags: [], ...extra });
};
for (let m = 9; m >= -3; m--) {
  const cresc = 1 + (9 - m) * 0.06;
  [5, 12, 19, 26].forEach(d => add('receber', 'Repasse plataforma de vendas', varia(620000 * cresc, .25), 'Vendas plataforma', d, m, { fornecedor: 'Plataforma de Vendas' }));
  add('receber', 'Mentoria em grupo', varia(210000, .3), 'Mentorias', 10, m);
  if (m % 3 === 0) add('receber', 'Patrocínio de evento', varia(60000), 'Patrocínios', 15, m);
  add('receber', 'Rendimento aplicação', varia(4200), 'Rendimentos', 22, m);
  add('pagar', 'Anúncios rede social', varia(780000 * cresc, .2), 'Anúncios redes sociais', 8, m, { fornecedor: 'Rede Social Ads' });
  add('pagar', 'Anúncios buscador', varia(120000, .4), 'Anúncios busca', 8, m, { fornecedor: 'Buscador Ads' });
  add('pagar', 'Fulano Prestador PJ', 18000, 'Prestadores PJ', 5, m, { fornecedor: 'Fulano Prestador PJ' });
  add('pagar', 'Ciclana Prestadora PJ', 14500, 'Prestadores PJ', 5, m, { fornecedor: 'Ciclana Prestadora PJ' });
  add('pagar', 'Folha CLT', varia(82000, .04), 'Salários', 5, m);
  add('pagar', 'Pró-labore sócios', 180000, 'Pró-labore', 3, m);
  add('pagar', 'Plano de saúde', varia(34000, .05), 'Benefícios', 3, m);
  add('pagar', 'COFINS, PIS e ISS', varia(390000 * cresc, .15), 'Impostos sobre vendas', 20, m);
  if ((hoje.getMonth() - m + 12) % 3 === 0) add('pagar', 'IRPJ e CSLL do trimestre', varia(520000, .1), 'IRPJ e CSLL', 28, m);
  if (m % 2 === 0) { add('pagar', 'Locação espaço evento', varia(160000, .3), 'Local de eventos', 14, m, { fornecedor: 'Hotel Eventos Exemplo' }); add('pagar', 'Buffet evento', varia(70000, .3), 'Alimentação eventos', 14, m); }
  add('pagar', 'Servidores e ferramentas', varia(62000, .1), 'Sistemas e cloud', 10, m);
  add('pagar', 'Aluguel escritório', 38000, 'Aluguel', 5, m, { fornecedor: 'Imobiliária Exemplo' });
  add('pagar', 'Honorários contábeis', 9800, 'Contabilidade', 10, m, { fornecedor: 'Contábil Exemplo' });
  add('pagar', 'Tarifas', varia(850, .3), 'Tarifas bancárias', 28, m);
}
lancamentos.forEach(l => { l.situacao = l.status !== 'pago' && l.data_vencimento < iso(hoje) ? 'atrasado' : l.status; });

// "views" calculadas como no banco
const mesDe = d => d.slice(0, 8) + '01';
function vwFluxo(){
  const o = {};
  lancamentos.filter(l => l.categoria_tipo !== 'neutra').forEach(l => {
    const m = mesDe(l.data_pagamento || l.data_vencimento); o[m] ??= { mes: m, receitas_realizadas: 0, despesas_realizadas: 0, receitas_previstas: 0, despesas_previstas: 0 };
    const k = (l.tipo === 'receber' ? 'receitas_' : 'despesas_') + (l.status === 'pago' ? 'realizadas' : 'previstas'); o[m][k] += l.valor;
  });
  return Object.values(o);
}
function vwResultado(){
  const o = {};
  lancamentos.filter(l => l.categoria_tipo !== 'neutra').forEach(l => {
    const k = [l.data_competencia, l.tipo, l.categoria].join('|');
    o[k] ??= { mes: l.data_competencia, tipo: l.tipo, grupo: l.categoria_grupo, categoria: l.categoria, centro_custo: 'Sem centro', realizado: 0, previsto: 0 };
    o[k][l.status === 'pago' ? 'realizado' : 'previsto'] += l.valor;
  });
  return Object.values(o);
}
const vwSaldo = () => contas.map(c => ({ ...c, pendentes: 0, saldo_extrato: null, data_extrato: null,
  saldo_atual: c.tipo === 'cartao' ? 0 : c.saldo_inicial + lancamentos.filter(l => l.conta_id === c.id && l.status === 'pago').reduce((a, l) => a + (l.tipo === 'receber' ? 1 : -1) * l.valor, 0) }));

const tabelas = {
  perfis: () => [{ id: 'demo-user', email: 'demo@exemplo.com', nome: 'Pessoa Demo', papel: 'admin', fornecedor_id: null }],
  parametros: () => [{ id: true, percentual_encargos_clt: 35.8, dia_pagamento_nf: 5, dia_limite_envio_nf: 25 }],
  categorias: () => categorias, centros_custo: () => centros, contas_bancarias: () => contas, fornecedores: () => fornecedores,
  projetos: () => [], regras_classificacao: () => [], notas_fiscais: () => [], extrato_linhas: () => [], extrato_importacoes: () => [], anexos: () => [], faturas: () => [],
  recorrencias: () => [], auditoria: () => [], lancamentos: () => lancamentos,
  vw_lancamentos: () => lancamentos, vw_fluxo_mensal: vwFluxo, vw_resultado_categoria: vwResultado, vw_saldo_contas: vwSaldo,
  vw_faturas: () => [], vw_extrato: () => [], vw_projetos: () => [], vw_custo_pessoas: () => [],
};

// construtor de consulta: guarda os filtros e resolve quando alguém dá await
function consulta(tabela){
  const f = [], st = { ordem: [], limite: null, head: false, count: false, um: null };
  const b = {
    select(_c, opt = {}){ st.head = !!opt.head; st.count = !!opt.count; return b; },
    eq(c, v){ f.push(r => String(r[c]) === String(v)); return b; }, neq(c, v){ f.push(r => String(r[c]) !== String(v)); return b; },
    in(c, vs){ f.push(r => vs.map(String).includes(String(r[c]))); return b; }, is(c, v){ f.push(r => (r[c] ?? null) === v); return b; },
    gte(c, v){ f.push(r => r[c] != null && r[c] >= v); return b; }, lte(c, v){ f.push(r => r[c] != null && r[c] <= v); return b; },
    gt(c, v){ f.push(r => r[c] > v); return b; }, lt(c, v){ f.push(r => r[c] < v); return b; },
    ilike(c, v){ const re = new RegExp(v.replace(/%/g, '.*'), 'i'); f.push(r => re.test(r[c] || '')); return b; },
    or(){ return b; }, contains(){ return b; }, not(){ return b; }, filter(){ return b; }, match(){ return b; },
    order(c, o = {}){ st.ordem.push([c, o.ascending !== false]); return b; }, limit(n){ st.limite = n; return b; }, range(a, z){ st.faixa = [a, z]; return b; },
    maybeSingle(){ st.um = 'maybe'; return b; }, single(){ st.um = 'single'; return b; },
    insert(){ return Promise.resolve({ data: null, error: { message: 'Modo demonstração: nada é gravado.' } }); },
    update(){ return b; }, delete(){ return b; }, upsert(){ return b; },
    then(ok, erro){
      try {
        let rows = (tabelas[tabela]?.() || []).filter(r => f.every(fn => fn(r)));
        for (const [c, asc] of [...st.ordem].reverse()) rows = [...rows].sort((a, z) => (a[c] > z[c] ? 1 : a[c] < z[c] ? -1 : 0) * (asc ? 1 : -1));
        const total = rows.length;
        if (st.faixa) rows = rows.slice(st.faixa[0], st.faixa[1] + 1);
        if (st.limite != null) rows = rows.slice(0, st.limite);
        const data = st.head ? null : st.um ? rows[0] ?? null : rows;
        return Promise.resolve({ data, error: null, count: st.count ? total : null }).then(ok, erro);
      } catch (e) { return Promise.reject(e).then(ok, erro); }
    },
  };
  return b;
}

export function criarClienteDemo(){
  const sessao = { user: { id: 'demo-user', email: 'demo@exemplo.com' } };
  return {
    from: consulta,
    rpc: async () => ({ data: null, error: { message: 'Modo demonstração: ações não são executadas.' } }),
    auth: { getSession: async () => ({ data: { session: sessao } }), onAuthStateChange(){}, signOut: async () => location.reload(),
      signInWithPassword: async () => ({ data: { session: sessao } }) },
    storage: { from: () => ({ createSignedUrl: async () => ({ data: null, error: { message: 'Modo demonstração' } }), upload: async () => ({ error: { message: 'Modo demonstração' } }), remove: async () => ({}) }) },
  };
}

-- ============================================================================
-- Plano de contas em 3 níveis + DRE em cascata
--   Linha do DRE (dre_linhas) → Grupo (categorias.grupo) → Categoria
-- Cada categoria de receita/despesa aponta para uma linha do DRE. O valor de uma
-- linha é Σ entradas − Σ saídas das suas categorias; os subtotais (Receita
-- líquida, Margem de contribuição, EBITDA, ...) são a soma acumulada das linhas
-- acima deles. Categorias neutras (transferência, aporte, aplicação) ficam fora.
-- Só acrescenta: nada existente é apagado.
-- ============================================================================

create table if not exists dre_linhas (
  codigo    text primary key,
  nome      text not null,
  ordem     int  not null unique,
  subtotal  boolean not null default false,   -- true = linha de total (= soma de tudo acima)
  descricao text
);

insert into dre_linhas (codigo, nome, ordem, subtotal, descricao) values
  ('receita_bruta',   'Receita bruta',                          10, false, 'Vendas, mentorias, patrocínios'),
  ('deducoes',        'Deduções: impostos, taxas e reembolsos', 20, false, 'PIS, COFINS, ISS, taxas da plataforma, reembolsos e chargebacks'),
  ('receita_liquida', 'Receita líquida',                        25, true,  null),
  ('marketing',       'Marketing e aquisição',                  30, false, 'Mídia paga, comissões, ferramentas de captação'),
  ('entrega',         'Entrega: eventos e mentorias',           40, false, 'Custo de entregar o que foi vendido'),
  ('margem',          'Margem de contribuição',                 45, true,  null),
  ('pessoas',         'Pessoas',                                50, false, 'PJs, salários, encargos, pró-labore, benefícios'),
  ('operacao',        'Tecnologia, estrutura e serviços',       60, false, 'Sistemas, escritório, contabilidade, advogados'),
  ('ebitda',          'EBITDA',                                 65, true,  'Resultado da operação, antes do financeiro e do IR'),
  ('financeiro',      'Resultado financeiro',                   70, false, 'Rendimentos (+), juros, IOF e tarifas (−)'),
  ('outras',          'Outras receitas e despesas',             80, false, 'Não recorrentes ou a classificar'),
  ('resultado_antes', 'Resultado antes do IR',                  85, true,  null),
  ('ir_csll',         'IRPJ e CSLL',                            90, false, 'Lucro Presumido: trimestrais'),
  ('lucro_liquido',   'Lucro líquido',                          95, true,  null)
on conflict (codigo) do nothing;

alter table categorias add column if not exists dre_linha text references dre_linhas(codigo);
alter table categorias drop constraint if exists categorias_dre_neutra;
alter table categorias add constraint categorias_dre_neutra
  check (tipo <> 'neutra' or dre_linha is null);

-- linha do DRE sugerida pelo grupo, para categoria nova que chega sem linha
create or replace function dre_linha_padrao(p_grupo text, p_tipo text) returns text language sql immutable as $$
  select case
    when p_tipo = 'neutra' then null
    when p_grupo in ('Receitas', 'Produtos')                    then 'receita_bruta'
    when p_grupo in ('Impostos', 'Deduções da receita')         then 'deducoes'
    when p_grupo = 'Marketing e aquisição'                      then 'marketing'
    when p_grupo = 'Eventos'                                    then 'entrega'
    when p_grupo = 'Pessoas'                                    then 'pessoas'
    when p_grupo in ('Tecnologia e sistemas', 'Tecnologia', 'Estrutura e escritório', 'Serviços profissionais') then 'operacao'
    when p_grupo = 'Financeiro'                                 then 'financeiro'
    when p_tipo = 'receita'                                     then 'receita_bruta'
    else 'outras' end
$$;

-- preenche a linha pelo grupo quando vier vazia; linha de total não recebe categoria
create or replace function categoria_linha_valida() returns trigger language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.tipo = 'neutra' and old.tipo <> 'neutra' then
    new.dre_linha := null;   -- virou neutra: sai do DRE
  end if;
  if new.dre_linha is null and new.tipo <> 'neutra' then
    new.dre_linha := dre_linha_padrao(new.grupo, new.tipo);
  end if;
  if new.dre_linha is not null and (select subtotal from dre_linhas where codigo = new.dre_linha) then
    raise exception 'A linha "%" é um total do DRE. Escolha uma linha de receita ou despesa.',
      (select nome from dre_linhas where codigo = new.dre_linha);
  end if;
  return new;
end $$;
drop trigger if exists categoria_linha_valida on categorias;
create trigger categoria_linha_valida before insert or update of dre_linha, grupo, tipo on categorias
  for each row execute function categoria_linha_valida();

-- ---------------------------------------------------------------- RLS ----
alter table dre_linhas enable row level security;
drop policy if exists interno_le on dre_linhas;
drop policy if exists admin_escreve on dre_linhas;
create policy interno_le on dre_linhas for select to authenticated using (is_interno());
create policy admin_escreve on dre_linhas for all to authenticated using (is_admin()) with check (is_admin());

-- ------------------------------------------------- categorias que faltavam ----
insert into categorias (nome, tipo, grupo, dre_linha) values
  -- produtos: a receita de cada um aparece separada em Contas a receber e no DRE
  ('FLUXO',                                 'receita', 'Produtos',                           'receita_bruta'),
  ('MASTERFLUXO',                           'receita', 'Produtos',                           'receita_bruta'),
  ('PIS',                                   'despesa', 'Impostos',                           'deducoes'),
  ('Taxas Hotmart',                         'despesa', 'Deduções da receita',                'deducoes'),
  ('Reembolsos e chargebacks',              'despesa', 'Deduções da receita',                'deducoes'),
  ('Comissões de afiliados e coprodução',   'despesa', 'Marketing e aquisição',              'marketing'),
  ('TikTok Ads',                            'despesa', 'Marketing e aquisição',              'marketing'),
  ('Outras mídias pagas',                   'despesa', 'Marketing e aquisição',              'marketing'),
  ('Aplicação financeira',                  'neutra',  'Movimentações (fora do resultado)',  null),
  ('Resgate de aplicação',                  'neutra',  'Movimentações (fora do resultado)',  null),
  ('Empréstimo recebido',                   'neutra',  'Movimentações (fora do resultado)',  null),
  ('Pagamento de empréstimo (principal)',   'neutra',  'Movimentações (fora do resultado)',  null),
  ('Distribuição de lucros',                'neutra',  'Movimentações (fora do resultado)',  null)
on conflict (nome) do nothing;

-- ------------------------------------- classificação inicial das categorias ----
-- 1º por nome (casos específicos), 2º pelo grupo. Só preenche o que está vazio:
-- o que alguém já ajustou na tela não é sobrescrito.
update categorias c set dre_linha = m.linha
from (values
  ('Hotmart','receita_bruta'), ('Receita Mastermind','receita_bruta'), ('Receita de VTSD','receita_bruta'),
  ('Patrocínios','receita_bruta'), ('Receitas Extras','receita_bruta'),
  ('COFINS','deducoes'), ('ISS','deducoes'), ('ICMS','deducoes'), ('Outros Impostos','deducoes'),
  ('IRPJ (Imposto de Renda)','ir_csll'), ('CSLL (Contribuição social)','ir_csll'),
  ('IRRF','operacao'), ('IOF','financeiro'),
  ('Profissionais Externos Terceirizados  Eventos','entrega'),
  ('Analisadores','entrega'), ('rbMentoria','entrega'), ('rbVTSD','entrega'),
  ('Comissões','marketing'), ('Automação de e-mails','operacao'), ('Encurtadores e URLS','operacao'),
  ('Juros de Investimento e Aplicações','financeiro'),
  ('Devolução Diversos(fornecedores e outros)','outras'), ('Receitas desconhecidas','outras'),
  ('Despesas desconhecidas','outras'), ('Reembolso serviço 129M','outras')
) as m(nome, linha)
where c.nome = m.nome and c.dre_linha is null and c.tipo <> 'neutra';

update categorias set dre_linha = dre_linha_padrao(grupo, tipo)
where dre_linha is null and tipo <> 'neutra';

-- ------------------------------------------------------------------ view ----
-- Base do DRE: por mês de competência, linha, grupo e categoria.
-- valor com sinal: entrada soma, saída subtrai. Sem categoria → "Sem classificação" (nada some do DRE).
drop view if exists vw_dre;
create view vw_dre with (security_invoker = true) as
select l.data_competencia                                    as mes,
       coalesce(c.dre_linha, 'outras')                       as dre_linha,
       coalesce(d.ordem, 80)                                 as ordem,
       coalesce(c.grupo, 'Sem grupo')                        as grupo,
       coalesce(c.nome, 'Sem classificação')                 as categoria,
       coalesce(sum(case when l.tipo = 'receber' then l.valor else -l.valor end)
                filter (where l.status = 'pago'), 0)                         as realizado,
       coalesce(sum(case when l.tipo = 'receber' then l.valor else -l.valor end)
                filter (where l.status in ('previsto','aprovado')), 0)       as previsto
from lancamentos l
left join categorias c on c.id = l.categoria_id
left join dre_linhas d on d.codigo = c.dre_linha
where l.status <> 'cancelado'
  and coalesce(c.tipo, '') <> 'neutra'
group by 1, 2, 3, 4, 5;

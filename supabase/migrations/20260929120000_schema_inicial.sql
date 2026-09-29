-- ============================================================================
-- SISTEMA FINANCEIRO · schema inicial
-- Contas a pagar, contas a receber, recorrências, projetos/eventos, pessoas
-- e PORTAL DE NOTAS FISCAIS para colaboradores PJ.
--
-- Migration inicial. Aplicar com `supabase db push` (veja docs/deploy.md).
-- Carga de dados reais: dados-privados/ (fora do git). Regras: docs/regras-de-negocio.md.
--
-- Modelo mental: igual ao Granatum. Tudo que entra ou sai de dinheiro é UM
-- "lançamento" (tabela lancamentos), classificado por categoria, centro de
-- custo, conta, fornecedor/cliente e tags. Contas a pagar e a receber são a
-- mesma tabela filtrada por tipo. Isso é o que permite exportar de volta
-- para o Granatum sem tradução e montar fluxo de caixa com uma query só.
-- ============================================================================

create extension if not exists pgcrypto;

-- ----------------------------------------------------------------------------
-- 1. PERFIS DE ACESSO
--   admin       → tudo, inclusive gerenciar usuários
--   financeiro  → opera o sistema (cria, edita, aprova NF, marca pago)
--   leitura     → vê tudo, não altera nada (ex.: sócios, diretoria)
--   colaborador → PJ externo: só enxerga e envia as PRÓPRIAS notas fiscais
-- Todo cadastro novo nasce "colaborador" (o menor acesso possível). Quem é
-- da equipe interna é promovido pelo admin na tela Usuários.
-- ----------------------------------------------------------------------------
create table if not exists perfis (
  id            uuid primary key references auth.users(id) on delete cascade,
  nome          text,
  email         text,
  papel         text not null default 'colaborador'
                check (papel in ('admin','financeiro','leitura','colaborador')),
  fornecedor_id uuid,               -- FK criada depois de fornecedores
  created_at    timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- 2. CADASTROS BÁSICOS (os mesmos eixos de classificação do Granatum)
-- ----------------------------------------------------------------------------
create table if not exists categorias (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null unique,
  -- neutra = entra/sai do caixa mas não é resultado (transferência entre
  -- contas, aporte de sócio). Fica fora do DRE e do fluxo de resultado.
  tipo       text not null check (tipo in ('despesa','receita','neutra')),
  grupo      text,
  ativo      boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists centros_custo (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null unique,
  ativo      boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists contas_bancarias (
  id                 uuid primary key default gen_random_uuid(),
  nome               text not null unique,
  tipo               text not null default 'corrente'
                     check (tipo in ('corrente','investimento','cartao','caixa')),
  saldo_inicial      numeric(14,2) not null default 0,
  data_saldo_inicial date,
  ativo              boolean not null default true,
  created_at         timestamptz not null default now()
);

-- Pessoas e empresas com quem há movimento: PJ, CLT, sócios, fornecedores, clientes.
create table if not exists fornecedores (
  id                     uuid primary key default gen_random_uuid(),
  nome                   text not null unique,
  tipo                   text not null default 'fornecedor'
                         check (tipo in ('pj','clt','socio','fornecedor','cliente')),
  documento              text,          -- CNPJ/CPF
  email                  text,          -- liga o login do PJ a este cadastro
  telefone               text,
  chave_pix              text,
  dados_bancarios        text,
  categoria_padrao_id    uuid references categorias(id),
  centro_custo_padrao_id uuid references centros_custo(id),
  conta_padrao_id        uuid references contas_bancarias(id),
  valor_mensal           numeric(14,2), -- PJ: valor combinado por mês
  salario_bruto          numeric(14,2), -- CLT: base do custo com encargos
  dia_pagamento          int check (dia_pagamento between 1 and 31),
  exige_nf               boolean not null default false,
  ativo                  boolean not null default true,
  observacoes            text,
  created_at             timestamptz not null default now()
);
create unique index if not exists fornecedores_email_uk
  on fornecedores (lower(email)) where email is not null and email <> '';

alter table perfis drop constraint if exists perfis_fornecedor_fk;
alter table perfis add constraint perfis_fornecedor_fk
  foreign key (fornecedor_id) references fornecedores(id) on delete set null;

-- Projetos / eventos / lançamentos de produto. Ligados aos lançamentos pelo
-- campo projeto_id OU pela tag (ex.: "PE - Master Fluxo"), para aproveitar o
-- padrão de tags que o time já usa no Granatum.
create table if not exists projetos (
  id                uuid primary key default gen_random_uuid(),
  nome              text not null unique,
  tag               text unique,
  tipo              text not null default 'evento'
                    check (tipo in ('evento','lancamento','produto','outro')),
  orcamento_despesa numeric(14,2) not null default 0,
  meta_receita      numeric(14,2) not null default 0,
  data_inicio       date,
  data_fim          date,
  ativo             boolean not null default true,
  created_at        timestamptz not null default now()
);

-- Parâmetros gerais (tabela de uma linha só: id sempre = true).
create table if not exists parametros (
  id                       boolean primary key default true check (id),
  -- INSS patronal 20% + RAT ~2% + terceiros 5,8% + FGTS 8% ≈ 35,8%.
  -- Empresa no Simples Nacional tem outra conta: ajuste na tela Parâmetros.
  percentual_encargos_clt  numeric(5,2) not null default 35.8,
  dia_pagamento_nf         int not null default 5  check (dia_pagamento_nf between 1 and 31),
  dia_limite_envio_nf      int not null default 25 check (dia_limite_envio_nf between 1 and 31),
  instrucoes_portal        text default 'Envie sua nota fiscal até o dia limite para garantir o pagamento no prazo. Aceitamos PDF ou XML.'
);
insert into parametros (id) values (true) on conflict do nothing;

-- ----------------------------------------------------------------------------
-- 3. RECORRÊNCIAS (modelos que geram lançamentos todo mês)
-- aguarda_nf = true → o lançamento do mês nasce "previsto" e só vira
-- "aprovado" quando a NF do PJ for aprovada. Assim o fluxo de caixa já
-- enxerga o custo, mas ninguém paga sem nota.
-- ----------------------------------------------------------------------------
create table if not exists recorrencias (
  id              uuid primary key default gen_random_uuid(),
  tipo            text not null check (tipo in ('pagar','receber')),
  descricao       text not null,
  valor           numeric(14,2) not null check (valor > 0),
  categoria_id    uuid references categorias(id),
  centro_custo_id uuid references centros_custo(id),
  conta_id        uuid references contas_bancarias(id),
  fornecedor_id   uuid references fornecedores(id),
  projeto_id      uuid references projetos(id),
  custo_nivel     text check (custo_nivel in ('fixo','variavel')),
  dia_vencimento  int not null check (dia_vencimento between 1 and 31),
  periodicidade   text not null default 'mensal'
                  check (periodicidade in ('mensal','trimestral','anual')),
  inicio          date not null default date_trunc('month', current_date)::date,
  fim             date,
  tags            text[] not null default '{}',
  aguarda_nf      boolean not null default false,
  ativo           boolean not null default true,
  created_at      timestamptz not null default now()
);
-- evita recorrência duplicada (e deixa o seed rodar mais de uma vez)
create unique index if not exists recorrencias_uk
  on recorrencias (tipo, descricao, categoria_id) nulls not distinct;

-- ----------------------------------------------------------------------------
-- 4. LANÇAMENTOS (contas a pagar + contas a receber)
-- ----------------------------------------------------------------------------
create table if not exists lancamentos (
  id               uuid primary key default gen_random_uuid(),
  tipo             text not null check (tipo in ('pagar','receber')),
  descricao        text not null,
  valor            numeric(14,2) not null check (valor > 0),   -- sempre positivo; o sinal vem do tipo
  categoria_id     uuid references categorias(id),
  centro_custo_id  uuid references centros_custo(id),
  conta_id         uuid references contas_bancarias(id),
  fornecedor_id    uuid references fornecedores(id),
  projeto_id       uuid references projetos(id),
  data_competencia date not null,      -- mês a que o gasto/receita pertence (DRE)
  data_vencimento  date not null,      -- quando deve ser pago (fluxo de caixa previsto)
  data_pagamento   date,               -- quando saiu/entrou de fato (fluxo realizado)
  status           text not null default 'previsto'
                   check (status in ('previsto','aprovado','pago','cancelado')),
  forma_pagamento  text check (forma_pagamento in
                   ('pix','boleto','transferencia','cartao_credito','debito_automatico','dinheiro','outro')),
  custo_nivel      text check (custo_nivel in ('fixo','variavel')),
  tags             text[] not null default '{}',
  parcela          int,
  total_parcelas   int,
  recorrencia_id   uuid references recorrencias(id) on delete set null,
  origem           text not null default 'manual'
                   check (origem in ('manual','recorrencia','nota_fiscal','importacao','conciliacao')),
  observacoes      text,
  created_by       uuid default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint pago_exige_data check (status <> 'pago' or data_pagamento is not null)
);
-- impede que "gerar recorrências" rode duas vezes e duplique o mês
create unique index if not exists lancamentos_recorrencia_mes_uk
  on lancamentos (recorrencia_id, data_competencia) where recorrencia_id is not null;
create index if not exists lancamentos_venc_idx   on lancamentos (data_vencimento);
create index if not exists lancamentos_pgto_idx   on lancamentos (data_pagamento);
create index if not exists lancamentos_status_idx on lancamentos (tipo, status);
create index if not exists lancamentos_forn_idx   on lancamentos (fornecedor_id, data_competencia);
create index if not exists lancamentos_tags_idx   on lancamentos using gin (tags);

-- ----------------------------------------------------------------------------
-- 5. NOTAS FISCAIS (portal do colaborador)
-- Fluxo: enviada → aprovada (gera/atualiza lançamento a pagar) → paga
--                ↘ rejeitada (colaborador corrige e reenvia → enviada)
-- ----------------------------------------------------------------------------
create table if not exists notas_fiscais (
  id                      uuid primary key default gen_random_uuid(),
  fornecedor_id           uuid not null references fornecedores(id),
  enviado_por             uuid references auth.users(id) default auth.uid(),
  competencia             date not null,   -- mês do serviço (sempre dia 1)
  numero                  text not null,
  data_emissao            date,
  valor                   numeric(14,2) not null check (valor > 0),
  descricao_servico       text,
  arquivo_path            text not null,   -- caminho no bucket "notas-fiscais"
  arquivo_nome            text,
  status                  text not null default 'enviada'
                          check (status in ('enviada','aprovada','rejeitada','paga')),
  motivo_rejeicao         text,
  lancamento_id           uuid references lancamentos(id) on delete set null,
  data_prevista_pagamento date,            -- espelho do lançamento, para o PJ ver
  data_pagamento          date,            -- espelho do lançamento, para o PJ ver
  analisado_por           uuid references auth.users(id),
  analisado_em            timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint nf_numero_uk unique (fornecedor_id, numero)
);
create index if not exists nf_status_idx on notas_fiscais (status, competencia);

-- ----------------------------------------------------------------------------
-- 6. AUDITORIA (quem mudou o quê, antes/depois)
-- ----------------------------------------------------------------------------
create table if not exists auditoria (
  id          bigserial primary key,
  tabela      text not null,
  registro_id text,
  acao        text not null,
  antes       jsonb,
  depois      jsonb,
  usuario     uuid default auth.uid(),
  em          timestamptz not null default now()
);
create index if not exists auditoria_em_idx on auditoria (em desc);

-- ============================================================================
-- FUNÇÕES AUXILIARES DE PERMISSÃO
-- security definer: leem perfis ignorando RLS, o que evita recursão infinita
-- quando a própria policy de perfis precisa saber o papel de quem consulta.
-- ============================================================================
create or replace function papel_atual() returns text
language sql stable security definer set search_path = public as $$
  select papel from perfis where id = auth.uid()
$$;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select papel = 'admin' from perfis where id = auth.uid()), false)
$$;

create or replace function is_financeiro() returns boolean   -- pode alterar dados
language sql stable security definer set search_path = public as $$
  select coalesce((select papel in ('admin','financeiro') from perfis where id = auth.uid()), false)
$$;

create or replace function is_interno() returns boolean      -- pode ver dados da empresa
language sql stable security definer set search_path = public as $$
  select coalesce((select papel in ('admin','financeiro','leitura') from perfis where id = auth.uid()), false)
$$;

create or replace function meu_fornecedor() returns uuid
language sql stable security definer set search_path = public as $$
  select fornecedor_id from perfis where id = auth.uid()
$$;

-- último dia do mês quando o dia pedido não existe (ex.: dia 31 em fevereiro)
-- número no formato brasileiro (1.234,56), para mensagens e textos
create or replace function brl(p numeric) returns text
language sql immutable as $$
  select translate(to_char(p, 'FM999,999,999,990.00'), ',.', '.,')
$$;

create or replace function dia_no_mes(p_mes date, p_dia int) returns date
language sql immutable as $$
  select make_date(
    extract(year from p_mes)::int,
    extract(month from p_mes)::int,
    least(p_dia, extract(day from (date_trunc('month', p_mes) + interval '1 month - 1 day'))::int)
  )
$$;

-- ============================================================================
-- CADASTRO AUTOMÁTICO DE PERFIL
-- Quando alguém cria login, ganha perfil "colaborador" e, se o e-mail bater
-- com o e-mail de um fornecedor cadastrado, já fica vinculado a ele.
-- ============================================================================
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into perfis (id, email, nome, papel, fornecedor_id)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'nome', split_part(new.email, '@', 1)),
    'colaborador',
    (select f.id from fornecedores f where lower(f.email) = lower(new.email) and f.ativo limit 1)
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Se o e-mail do fornecedor for preenchido DEPOIS que o PJ já criou login,
-- o vínculo acontece aqui.
create or replace function vincular_perfil_por_email() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email is not null and new.email <> ''
     and (tg_op = 'INSERT' or lower(coalesce(old.email,'')) <> lower(new.email)) then
    update perfis set fornecedor_id = new.id
     where lower(email) = lower(new.email) and fornecedor_id is null;
  end if;
  return new;
end $$;

drop trigger if exists fornecedores_vincula_perfil on fornecedores;
create trigger fornecedores_vincula_perfil
  after insert or update of email on fornecedores
  for each row execute function vincular_perfil_por_email();

-- Usuários que já existiam antes deste schema (se rodar num projeto antigo)
insert into perfis (id, email, nome, papel)
select u.id, u.email, split_part(u.email, '@', 1), 'colaborador'
from auth.users u
on conflict (id) do nothing;

-- ============================================================================
-- TRIGGERS DE REGRA DE NEGÓCIO
-- ============================================================================

-- updated_at
create or replace function set_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

drop trigger if exists lancamentos_updated on lancamentos;
create trigger lancamentos_updated before update on lancamentos
  for each row execute function set_updated_at();
drop trigger if exists nf_updated on notas_fiscais;
create trigger nf_updated before update on notas_fiscais
  for each row execute function set_updated_at();

-- Blindagem da NF: o colaborador só consegue mexer nos campos dele.
-- Mesmo que alguém chame a API direto (sem passar pela tela), não dá para
-- se autoaprovar, trocar o fornecedor ou mexer numa nota já aprovada.
create or replace function nf_protege_campos() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.competencia := date_trunc('month', new.competencia)::date;

  if is_financeiro() then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if meu_fornecedor() is null then
      raise exception 'Seu acesso ainda não foi vinculado a um cadastro de fornecedor. Fale com o financeiro.';
    end if;
    new.fornecedor_id := meu_fornecedor();
    new.enviado_por   := auth.uid();
  else
    if old.status not in ('enviada','rejeitada') then
      raise exception 'Esta nota já foi %. Para corrigir, fale com o financeiro.', old.status;
    end if;
    new.fornecedor_id := old.fornecedor_id;
    new.enviado_por   := old.enviado_por;
  end if;

  new.status                  := 'enviada';
  new.motivo_rejeicao         := null;
  new.lancamento_id           := null;
  new.analisado_por           := null;
  new.analisado_em            := null;
  new.data_prevista_pagamento := null;
  new.data_pagamento          := null;
  return new;
end $$;

drop trigger if exists nf_protege on notas_fiscais;
create trigger nf_protege before insert or update on notas_fiscais
  for each row execute function nf_protege_campos();

-- Quando o lançamento de uma NF muda (pago, nova data), o PJ vê no portal.
create or replace function lancamento_sincroniza_nf() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update notas_fiscais n set
    status = case
               when new.status = 'pago' then 'paga'
               when n.status = 'paga' and new.status <> 'pago' then 'aprovada'
               else n.status end,
    data_pagamento          = case when new.status = 'pago' then new.data_pagamento end,
    data_prevista_pagamento = new.data_vencimento
  where n.lancamento_id = new.id;
  return new;
end $$;

drop trigger if exists lancamentos_sync_nf on lancamentos;
create trigger lancamentos_sync_nf
  after update of status, data_pagamento, data_vencimento on lancamentos
  for each row execute function lancamento_sincroniza_nf();

-- Auditoria genérica
create or replace function registra_auditoria() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_setting('fin.importando', true) = 'on' then
    return coalesce(new, old);
  end if;
  insert into auditoria (tabela, registro_id, acao, antes, depois)
  values (
    tg_table_name,
    coalesce((to_jsonb(new)->>'id'), (to_jsonb(old)->>'id')),
    lower(tg_op),
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['lancamentos','notas_fiscais','fornecedores','recorrencias',
                           'categorias','centros_custo','contas_bancarias','projetos',
                           'perfis','parametros']
  loop
    execute format('drop trigger if exists auditoria_%1$s on %1$s', t);
    execute format('create trigger auditoria_%1$s after insert or update or delete on %1$s
                    for each row execute function registra_auditoria()', t);
  end loop;
end $$;

-- ============================================================================
-- FUNÇÕES CHAMADAS PELA TELA (RPC)
-- ============================================================================

-- Gera os lançamentos de um mês a partir das recorrências ativas.
-- Idempotente: rodar duas vezes no mesmo mês não duplica nada.
create or replace function gerar_recorrencias(p_mes date)
returns int language plpgsql set search_path = public as $$
declare
  v_mes date := date_trunc('month', p_mes)::date;
  v_qtd int;
begin
  if not is_financeiro() then
    raise exception 'Apenas financeiro/admin pode gerar recorrências.';
  end if;

  insert into lancamentos (tipo, descricao, valor, categoria_id, centro_custo_id, conta_id,
                           fornecedor_id, projeto_id, data_competencia, data_vencimento,
                           status, custo_nivel, tags, recorrencia_id, origem)
  select r.tipo, r.descricao, r.valor, r.categoria_id, r.centro_custo_id, r.conta_id,
         r.fornecedor_id, r.projeto_id,
         -- PJ que aguarda NF: o pagamento de outubro é do serviço de setembro
         case when r.aguarda_nf then (v_mes - interval '1 month')::date else v_mes end,
         dia_no_mes(v_mes, r.dia_vencimento),
         'previsto', r.custo_nivel, r.tags, r.id, 'recorrencia'
  from recorrencias r
  where r.ativo
    and r.inicio <= (v_mes + interval '1 month - 1 day')::date
    and (r.fim is null or r.fim >= v_mes)
    and case r.periodicidade
          when 'mensal'     then true
          when 'trimestral' then ((extract(year from v_mes) * 12 + extract(month from v_mes))
                                - (extract(year from r.inicio) * 12 + extract(month from r.inicio)))::int % 3 = 0
          when 'anual'      then extract(month from v_mes) = extract(month from r.inicio)
        end
  on conflict (recorrencia_id, data_competencia) where recorrencia_id is not null do nothing;

  get diagnostics v_qtd = row_count;
  return v_qtd;
end $$;

-- Aprova a NF. Se já existe o lançamento "previsto" do PJ naquela
-- competência (gerado pela recorrência), ele é reaproveitado com o valor da
-- nota; se não existe, um lançamento novo é criado. Retorna o id do lançamento.
create or replace function aprovar_nota_fiscal(p_nf uuid, p_vencimento date default null)
returns uuid language plpgsql set search_path = public as $$
declare
  nf     notas_fiscais;
  f      fornecedores;
  v_lanc uuid;
  v_venc date;
begin
  if not is_financeiro() then
    raise exception 'Apenas financeiro/admin pode aprovar notas.';
  end if;

  select * into nf from notas_fiscais where id = p_nf for update;
  if not found then raise exception 'Nota fiscal não encontrada.'; end if;
  if nf.status <> 'enviada' then
    raise exception 'Só notas com status "enviada" podem ser aprovadas (atual: %).', nf.status;
  end if;

  select * into f from fornecedores where id = nf.fornecedor_id;
  v_venc := coalesce(
    p_vencimento,
    dia_no_mes((nf.competencia + interval '1 month')::date,
               coalesce(f.dia_pagamento, (select dia_pagamento_nf from parametros limit 1), 5)));

  select l.id into v_lanc
    from lancamentos l
   where l.tipo = 'pagar'
     and l.fornecedor_id = nf.fornecedor_id
     and l.data_competencia = nf.competencia
     and l.status = 'previsto'
     and not exists (select 1 from notas_fiscais n2 where n2.lancamento_id = l.id)
   order by l.data_vencimento
   limit 1;

  if v_lanc is not null then
    update lancamentos
       set valor = nf.valor,
           status = 'aprovado',
           data_vencimento = coalesce(p_vencimento, data_vencimento),
           observacoes = concat_ws(' · ', observacoes, 'NF ' || nf.numero)
     where id = v_lanc;
  else
    insert into lancamentos (tipo, descricao, valor, categoria_id, centro_custo_id, conta_id,
                             fornecedor_id, data_competencia, data_vencimento, status,
                             forma_pagamento, origem, observacoes)
    values ('pagar', 'PJ - ' || f.nome || ' (NF ' || nf.numero || ')', nf.valor,
            f.categoria_padrao_id, f.centro_custo_padrao_id, f.conta_padrao_id,
            f.id, nf.competencia, v_venc, 'aprovado',
            case when f.chave_pix is not null and f.chave_pix <> '' then 'pix' end,
            'nota_fiscal', nf.descricao_servico)
    returning id into v_lanc;
  end if;

  update notas_fiscais
     set status = 'aprovada',
         lancamento_id = v_lanc,
         motivo_rejeicao = null,
         analisado_por = auth.uid(),
         analisado_em = now(),
         data_prevista_pagamento = (select data_vencimento from lancamentos where id = v_lanc)
   where id = p_nf;

  return v_lanc;
end $$;

create or replace function rejeitar_nota_fiscal(p_nf uuid, p_motivo text)
returns void language plpgsql set search_path = public as $$
begin
  if not is_financeiro() then
    raise exception 'Apenas financeiro/admin pode rejeitar notas.';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'Informe o motivo — é o que o colaborador vai ler para corrigir.';
  end if;
  update notas_fiscais
     set status = 'rejeitada', motivo_rejeicao = p_motivo,
         analisado_por = auth.uid(), analisado_em = now()
   where id = p_nf and status = 'enviada';
  if not found then
    raise exception 'Só notas com status "enviada" podem ser rejeitadas.';
  end if;
end $$;

-- Desfaz uma aprovação (ex.: aprovou a nota errada). Só se ainda não foi paga.
create or replace function desfazer_aprovacao_nf(p_nf uuid)
returns void language plpgsql set search_path = public as $$
declare nf notas_fiscais;
begin
  if not is_financeiro() then raise exception 'Sem permissão.'; end if;
  select * into nf from notas_fiscais where id = p_nf for update;
  if nf.status <> 'aprovada' then
    raise exception 'Só dá para desfazer notas aprovadas e ainda não pagas.';
  end if;
  update notas_fiscais
     set status = 'enviada', lancamento_id = null, analisado_por = null,
         analisado_em = null, data_prevista_pagamento = null
   where id = p_nf;
  -- lançamento volta a ser previsão (se veio de recorrência) ou é cancelado
  update lancamentos
     set status = case when origem = 'recorrencia' then 'previsto' else 'cancelado' end
   where id = nf.lancamento_id;
end $$;

-- ============================================================================
-- VIEWS (security_invoker = a view respeita o RLS de quem consulta)
-- ============================================================================
-- vw_lancamentos e vw_saldo_contas estão na PARTE 2 (usam extrato, faturas e anexos)

-- Fluxo de caixa mensal: realizado pela data de pagamento, previsto pela de
-- vencimento. Categorias "neutras" (transferências, aportes) ficam fora.
create or replace view vw_fluxo_mensal with (security_invoker = true) as
select date_trunc('month', coalesce(l.data_pagamento, l.data_vencimento))::date as mes,
       coalesce(sum(l.valor) filter (where l.tipo = 'receber' and l.status = 'pago'), 0)                     as receitas_realizadas,
       coalesce(sum(l.valor) filter (where l.tipo = 'pagar'   and l.status = 'pago'), 0)                     as despesas_realizadas,
       coalesce(sum(l.valor) filter (where l.tipo = 'receber' and l.status in ('previsto','aprovado')), 0)   as receitas_previstas,
       coalesce(sum(l.valor) filter (where l.tipo = 'pagar'   and l.status in ('previsto','aprovado')), 0)   as despesas_previstas
from lancamentos l
left join categorias c on c.id = l.categoria_id
where l.status <> 'cancelado'
  and coalesce(c.tipo, '') <> 'neutra'
group by 1;

-- Resultado por categoria (regime de competência) — base do DRE gerencial.
create or replace view vw_resultado_categoria with (security_invoker = true) as
select l.data_competencia as mes,
       l.tipo,
       coalesce(c.grupo, 'Sem grupo')        as grupo,
       coalesce(c.nome,  'Sem categoria')    as categoria,
       coalesce(cc.nome, 'Sem centro')       as centro_custo,
       sum(l.valor) filter (where l.status = 'pago')                     as realizado,
       sum(l.valor) filter (where l.status in ('previsto','aprovado'))   as previsto
from lancamentos l
left join categorias    c  on c.id  = l.categoria_id
left join centros_custo cc on cc.id = l.centro_custo_id
where l.status <> 'cancelado'
  and coalesce(c.tipo, '') <> 'neutra'
group by 1, 2, 3, 4, 5;

-- Projetos/eventos: orçado x realizado
create or replace view vw_projetos with (security_invoker = true) as
select p.*,
       coalesce(sum(l.valor) filter (where l.tipo = 'pagar'   and l.status = 'pago'), 0)                   as despesa_realizada,
       coalesce(sum(l.valor) filter (where l.tipo = 'pagar'   and l.status in ('previsto','aprovado')), 0) as despesa_prevista,
       coalesce(sum(l.valor) filter (where l.tipo = 'receber' and l.status = 'pago'), 0)                   as receita_realizada
from projetos p
left join lancamentos l
       on l.status <> 'cancelado'
      and (l.projeto_id = p.id or (p.tag is not null and l.tags @> array[p.tag]))
group by p.id;

-- Custo mensal real de pessoas. CLT: salário + encargos, com provisão de
-- 13º (1/12) e férias + 1/3 (1,333/12) — encargos incidem sobre tudo.
create or replace view vw_custo_pessoas with (security_invoker = true) as
select f.id, f.nome, f.tipo,
       cc.nome as centro_custo,
       case f.tipo
         when 'clt' then f.salario_bruto
         else f.valor_mensal
       end as base_mensal,
       case f.tipo
         when 'clt' then round(f.salario_bruto * (1 + pa.percentual_encargos_clt / 100)
                                * (1 + 1.0/12 + (4.0/3)/12), 2)
         else f.valor_mensal
       end as custo_mensal
from fornecedores f
cross join parametros pa
left join centros_custo cc on cc.id = f.centro_custo_padrao_id
where f.ativo and f.tipo in ('clt','pj','socio');

-- ============================================================================
-- RLS (quem enxerga o quê)
-- ============================================================================
alter table perfis            enable row level security;
alter table categorias        enable row level security;
alter table centros_custo     enable row level security;
alter table contas_bancarias  enable row level security;
alter table fornecedores      enable row level security;
alter table projetos          enable row level security;
alter table parametros        enable row level security;
alter table recorrencias      enable row level security;
alter table lancamentos       enable row level security;
alter table notas_fiscais     enable row level security;
alter table auditoria         enable row level security;

-- Tabelas de negócio: equipe interna lê, financeiro/admin escreve.
do $$
declare t text;
begin
  foreach t in array array['categorias','centros_custo','contas_bancarias','projetos',
                           'recorrencias','lancamentos']
  loop
    execute format('drop policy if exists interno_le on %I', t);
    execute format('drop policy if exists financeiro_escreve on %I', t);
    execute format('create policy interno_le on %I for select to authenticated using (is_interno())', t);
    execute format('create policy financeiro_escreve on %I for all to authenticated
                    using (is_financeiro()) with check (is_financeiro())', t);
  end loop;
end $$;

-- Fornecedores: interno lê tudo; o PJ lê só o próprio cadastro.
-- O PJ NÃO edita o próprio cadastro (nem a chave PIX): troca de dados de
-- pagamento é o golpe mais comum em contas a pagar, então passa pelo financeiro.
drop policy if exists interno_le on fornecedores;
drop policy if exists financeiro_escreve on fornecedores;
drop policy if exists colaborador_le_proprio on fornecedores;
create policy interno_le on fornecedores for select to authenticated using (is_interno());
create policy colaborador_le_proprio on fornecedores for select to authenticated using (id = meu_fornecedor());
create policy financeiro_escreve on fornecedores for all to authenticated
  using (is_financeiro()) with check (is_financeiro());

-- Parâmetros: todo logado lê (o portal mostra o dia limite); financeiro altera.
drop policy if exists todos_leem on parametros;
drop policy if exists financeiro_altera on parametros;
create policy todos_leem on parametros for select to authenticated using (true);
create policy financeiro_altera on parametros for update to authenticated
  using (is_financeiro()) with check (is_financeiro());

-- Notas fiscais
drop policy if exists nf_interno_le on notas_fiscais;
drop policy if exists nf_financeiro_escreve on notas_fiscais;
drop policy if exists nf_colab_le on notas_fiscais;
drop policy if exists nf_colab_envia on notas_fiscais;
drop policy if exists nf_colab_corrige on notas_fiscais;
drop policy if exists nf_colab_apaga on notas_fiscais;
create policy nf_interno_le on notas_fiscais for select to authenticated using (is_interno());
create policy nf_financeiro_escreve on notas_fiscais for all to authenticated
  using (is_financeiro()) with check (is_financeiro());
create policy nf_colab_le on notas_fiscais for select to authenticated
  using (fornecedor_id = meu_fornecedor());
create policy nf_colab_envia on notas_fiscais for insert to authenticated
  with check (meu_fornecedor() is not null);   -- o trigger força fornecedor_id = o do usuário
create policy nf_colab_corrige on notas_fiscais for update to authenticated
  using (fornecedor_id = meu_fornecedor() and status in ('enviada','rejeitada'))
  with check (fornecedor_id = meu_fornecedor());
create policy nf_colab_apaga on notas_fiscais for delete to authenticated
  using (fornecedor_id = meu_fornecedor() and status = 'enviada');

-- Perfis: cada um vê o seu; interno vê todos; só admin altera.
drop policy if exists perfil_proprio on perfis;
drop policy if exists perfil_interno_le on perfis;
drop policy if exists perfil_admin on perfis;
create policy perfil_proprio on perfis for select to authenticated using (id = auth.uid());
create policy perfil_interno_le on perfis for select to authenticated using (is_interno());
create policy perfil_admin on perfis for all to authenticated
  using (is_admin()) with check (is_admin());

-- Auditoria: só financeiro/admin lê; ninguém escreve direto (só os triggers).
drop policy if exists auditoria_le on auditoria;
create policy auditoria_le on auditoria for select to authenticated using (is_financeiro());

-- ============================================================================
-- STORAGE: bucket privado para os arquivos das NFs
-- Caminho: <fornecedor_id>/<AAAA-MM>/<arquivo>. A primeira pasta é o que
-- garante que cada PJ só lê/grava dentro da própria pasta.
-- ============================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('notas-fiscais', 'notas-fiscais', false, 10485760,
        array['application/pdf','text/xml','application/xml','image/png','image/jpeg'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists nf_arquivo_colab_envia on storage.objects;
drop policy if exists nf_arquivo_colab_le    on storage.objects;
drop policy if exists nf_arquivo_colab_apaga on storage.objects;
drop policy if exists nf_arquivo_interno_le  on storage.objects;
drop policy if exists nf_arquivo_financeiro  on storage.objects;

create policy nf_arquivo_colab_envia on storage.objects for insert to authenticated
  with check (bucket_id = 'notas-fiscais'
              and (storage.foldername(name))[1] = meu_fornecedor()::text);
create policy nf_arquivo_colab_le on storage.objects for select to authenticated
  using (bucket_id = 'notas-fiscais'
         and (storage.foldername(name))[1] = meu_fornecedor()::text);
create policy nf_arquivo_colab_apaga on storage.objects for delete to authenticated
  using (bucket_id = 'notas-fiscais'
         and (storage.foldername(name))[1] = meu_fornecedor()::text);
create policy nf_arquivo_interno_le on storage.objects for select to authenticated
  using (bucket_id = 'notas-fiscais' and is_interno());
create policy nf_arquivo_financeiro on storage.objects for all to authenticated
  using (bucket_id = 'notas-fiscais' and is_financeiro())
  with check (bucket_id = 'notas-fiscais' and is_financeiro());


-- ############################################################################
-- PARTE 2 · O QUE O GRANATUM FAZIA
-- Conciliação bancária, cartões de crédito e faturas, comprovantes e boletos.
-- ############################################################################

-- similaridade de texto: é o que permite achar "PIX ENVIADO ERICA GARCIA"
-- quando o lançamento se chama "PJ Erica"
create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;
grant usage on schema extensions to authenticated;

-- ----------------------------------------------------------------------------
-- 2.1 CARTÕES DE CRÉDITO
-- Um cartão é uma conta do tipo 'cartao'. Cada compra é um lançamento normal
-- (com categoria, centro de custo…) ligado a uma fatura. Quando a fatura é
-- paga, todas as compras dela viram "pago" na data do pagamento — é assim
-- que o DRE mostra o gasto certo (Adobe em "Programas de edição") e o fluxo
-- de caixa mostra a saída no dia certo (o dia em que a fatura foi paga).
-- ----------------------------------------------------------------------------
alter table contas_bancarias add column if not exists final_cartao       text;
alter table contas_bancarias add column if not exists dia_fechamento     int check (dia_fechamento between 1 and 31);
alter table contas_bancarias add column if not exists dia_vencimento     int check (dia_vencimento between 1 and 31);
alter table contas_bancarias add column if not exists conta_pagamento_id uuid references contas_bancarias(id);

create table if not exists faturas (
  id                 uuid primary key default gen_random_uuid(),
  cartao_id          uuid not null references contas_bancarias(id),
  mes_vencimento     date not null,            -- sempre dia 1 do mês em que vence
  data_fechamento    date not null,
  data_vencimento    date not null,
  status             text not null default 'aberta' check (status in ('aberta','fechada','paga')),
  data_pagamento     date,
  valor_pago         numeric(14,2),
  conta_pagamento_id uuid references contas_bancarias(id),
  created_at         timestamptz not null default now(),
  constraint fatura_mes_uk unique (cartao_id, mes_vencimento)
);

-- ----------------------------------------------------------------------------
-- 2.2 EXTRATO BANCÁRIO
-- Cada linha do extrato importado fica guardada. Conciliar = ligar a linha
-- ao(s) lançamento(s) que ela paga. O extrato é a fonte da verdade: ao
-- conciliar, data de pagamento, conta e valor passam a ser os do extrato.
-- ----------------------------------------------------------------------------
create table if not exists extrato_importacoes (
  id           uuid primary key default gen_random_uuid(),
  conta_id     uuid not null references contas_bancarias(id),
  arquivo_nome text,
  formato      text,
  inicio       date,
  fim          date,
  linhas_novas int not null default 0,
  linhas_repetidas int not null default 0,
  importado_por uuid default auth.uid(),
  created_at   timestamptz not null default now()
);

create table if not exists extrato_linhas (
  id              uuid primary key default gen_random_uuid(),
  conta_id        uuid not null references contas_bancarias(id),
  importacao_id   uuid references extrato_importacoes(id) on delete cascade,
  data            date not null,
  descricao       text not null,
  documento       text,
  valor           numeric(14,2) not null check (valor <> 0),   -- negativo = saída
  saldo           numeric(14,2),                               -- se o arquivo trouxer
  hash            text not null,     -- impede importar a mesma linha duas vezes
  status          text not null default 'pendente' check (status in ('pendente','conciliado','ignorado')),
  motivo_ignorado text,
  fatura_id       uuid references faturas(id) on delete set null,
  conciliado_por  uuid,
  conciliado_em   timestamptz,
  created_at      timestamptz not null default now(),
  constraint extrato_linha_uk unique (conta_id, hash)
);
create index if not exists extrato_pend_idx on extrato_linhas (conta_id, status, data);

alter table lancamentos add column if not exists extrato_linha_id uuid references extrato_linhas(id) on delete set null;
alter table lancamentos add column if not exists fatura_id        uuid references faturas(id) on delete set null;
alter table lancamentos add column if not exists data_documento   date;   -- data da compra / emissão do boleto
alter table lancamentos add column if not exists codigo_barras    text;   -- linha digitável do boleto
create index if not exists lancamentos_fatura_idx  on lancamentos (fatura_id);
create index if not exists lancamentos_extrato_idx on lancamentos (extrato_linha_id);
create index if not exists lancamentos_desc_trgm   on lancamentos using gin (lower(descricao) extensions.gin_trgm_ops);

-- Regras: "se o extrato disser X, é categoria Y". Tarifa, IOF, aluguel,
-- Hotmart… cadastrou uma vez, nunca mais classifica na mão.
create table if not exists regras_classificacao (
  id              uuid primary key default gen_random_uuid(),
  padrao          text not null,           -- trecho do texto do extrato, sem diferenciar maiúsculas
  tipo            text not null check (tipo in ('pagar','receber')),
  descricao       text,                    -- descrição que o lançamento vai ter
  categoria_id    uuid references categorias(id),
  centro_custo_id uuid references centros_custo(id),
  fornecedor_id   uuid references fornecedores(id),
  auto_conciliar  boolean not null default true,  -- cria e concilia sozinho em "Aplicar regras"
  ativo           boolean not null default true,
  created_at      timestamptz not null default now(),
  constraint regra_uk unique (padrao, tipo)
);

-- ----------------------------------------------------------------------------
-- 2.3 COMPROVANTES E BOLETOS
-- ----------------------------------------------------------------------------
create table if not exists anexos (
  id            uuid primary key default gen_random_uuid(),
  lancamento_id uuid references lancamentos(id) on delete cascade,
  fatura_id     uuid references faturas(id) on delete cascade,
  tipo          text not null default 'comprovante'
                check (tipo in ('boleto','comprovante','nota_fiscal','contrato','outro')),
  arquivo_path  text not null,
  arquivo_nome  text,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  constraint anexo_tem_dono check (lancamento_id is not null or fatura_id is not null)
);
create index if not exists anexos_lanc_idx on anexos (lancamento_id);

-- ============================================================================
-- FUNÇÕES DE CARTÃO
-- ============================================================================

-- Fatura de um cartão pelo mês de vencimento (cria se não existir).
create or replace function obter_fatura(p_cartao uuid, p_mes date)
returns uuid language plpgsql set search_path = public as $$
declare
  c     contas_bancarias;
  v_mes date := date_trunc('month', p_mes)::date;
  dv int; df int; v_venc date; v_fech date; v_id uuid;
begin
  select * into c from contas_bancarias where id = p_cartao;
  if c.tipo is distinct from 'cartao' then raise exception 'A conta escolhida não é um cartão.'; end if;
  dv := coalesce(c.dia_vencimento, 10);
  df := coalesce(c.dia_fechamento, case when dv > 7 then dv - 7 else dv + 21 end);
  v_venc := dia_no_mes(v_mes, dv);
  v_fech := case when df < dv then dia_no_mes(v_mes, df)
                 else dia_no_mes((v_mes - interval '1 month')::date, df) end;
  insert into faturas (cartao_id, mes_vencimento, data_fechamento, data_vencimento, conta_pagamento_id)
  values (p_cartao, v_mes, v_fech, v_venc, c.conta_pagamento_id)
  on conflict (cartao_id, mes_vencimento) do nothing;
  select id into v_id from faturas where cartao_id = p_cartao and mes_vencimento = v_mes;
  return v_id;
end $$;

-- Em qual fatura cai uma compra feita em p_data.
create or replace function fatura_para_data(p_cartao uuid, p_data date)
returns uuid language plpgsql set search_path = public as $$
declare
  c contas_bancarias; dv int; df int; v_fech date; v_venc date;
begin
  select * into c from contas_bancarias where id = p_cartao;
  dv := coalesce(c.dia_vencimento, 10);
  df := coalesce(c.dia_fechamento, case when dv > 7 then dv - 7 else dv + 21 end);
  v_fech := dia_no_mes(p_data, df);
  if p_data >= v_fech then     -- comprou no dia do fechamento ou depois: vai para o ciclo seguinte
    v_fech := dia_no_mes((date_trunc('month', p_data) + interval '1 month')::date, df);
  end if;
  v_venc := dia_no_mes(v_fech, dv);
  if v_venc <= v_fech then
    v_venc := dia_no_mes((date_trunc('month', v_fech) + interval '1 month')::date, dv);
  end if;
  return obter_fatura(p_cartao, v_venc);
end $$;

-- Toda compra no cartão entra numa fatura e herda dela vencimento e status.
create or replace function lancamento_cartao() returns trigger
language plpgsql set search_path = public as $$
declare f faturas; eh_cartao boolean;
begin
  if tg_op = 'UPDATE' and new.conta_id is distinct from old.conta_id
     and new.fatura_id is not distinct from old.fatura_id then
    new.fatura_id := null;           -- mudou de conta: sai da fatura antiga
  end if;
  select tipo = 'cartao' into eh_cartao from contas_bancarias where id = new.conta_id;
  if new.fatura_id is null and coalesce(eh_cartao, false) then
    new.fatura_id := fatura_para_data(new.conta_id, coalesce(new.data_documento, new.data_competencia));
  end if;
  if new.fatura_id is not null then
    select * into f from faturas where id = new.fatura_id;
    new.conta_id := f.cartao_id;
    new.data_vencimento := f.data_vencimento;
    new.forma_pagamento := coalesce(new.forma_pagamento, 'cartao_credito');
    if new.status <> 'cancelado' then
      if f.status = 'paga' then new.status := 'pago'; new.data_pagamento := f.data_pagamento;
      else new.status := 'aprovado'; new.data_pagamento := null; end if;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists lancamentos_cartao on lancamentos;
create trigger lancamentos_cartao before insert or update of conta_id, fatura_id, data_documento, data_competencia, status
  on lancamentos for each row execute function lancamento_cartao();

create or replace function pagar_fatura(p_fatura uuid, p_data date, p_conta uuid default null, p_valor numeric default null)
returns void language plpgsql set search_path = public as $$
declare v_total numeric;
begin
  if not is_financeiro() then raise exception 'Sem permissão.'; end if;
  select coalesce(sum(case when tipo = 'pagar' then valor else -valor end), 0) into v_total
    from lancamentos where fatura_id = p_fatura and status <> 'cancelado';
  update faturas f
     set status = 'paga', data_pagamento = p_data,
         conta_pagamento_id = coalesce(p_conta, f.conta_pagamento_id,
                                       (select conta_pagamento_id from contas_bancarias where id = f.cartao_id)),
         valor_pago = coalesce(p_valor, v_total)
   where id = p_fatura;
  update lancamentos set status = 'pago' where fatura_id = p_fatura and status <> 'cancelado';
end $$;

create or replace function reabrir_fatura(p_fatura uuid)
returns void language plpgsql set search_path = public as $$
begin
  if not is_financeiro() then raise exception 'Sem permissão.'; end if;
  if exists (select 1 from extrato_linhas where fatura_id = p_fatura and status = 'conciliado') then
    raise exception 'O pagamento desta fatura está conciliado com o extrato. Desfaça a conciliação primeiro.';
  end if;
  update faturas set status = 'aberta', data_pagamento = null, valor_pago = null where id = p_fatura;
  update lancamentos set status = 'aprovado' where fatura_id = p_fatura and status <> 'cancelado';
end $$;

-- ============================================================================
-- FUNÇÕES DE CONCILIAÇÃO
-- ============================================================================

-- Candidatos para uma linha do extrato: lançamentos em aberto (ou pagos sem
-- conciliação) do mesmo sentido, perto da data, com valor igual ou texto
-- parecido; e faturas de cartão com o total igual.
create or replace function sugerir_conciliacao(p_linha uuid)
returns table (tipo text, id uuid, descricao text, valor numeric, data date, fornecedor text, dias int, valor_igual boolean, score numeric)
language sql stable set search_path = public, extensions as $$
  with l as (select * from extrato_linhas where id = p_linha)
  select * from (
    select 'lancamento'::text, x.id, x.descricao, x.valor,
           coalesce(x.data_pagamento, x.data_vencimento), f.nome,
           abs(coalesce(x.data_pagamento, x.data_vencimento) - l.data),
           x.valor = abs(l.valor),
           round(( (x.valor = abs(l.valor))::int * 0.6
                 + greatest(0, 0.3 - abs(coalesce(x.data_pagamento, x.data_vencimento) - l.data) * 0.03)
                 + greatest(similarity(lower(l.descricao), lower(x.descricao)),
                            coalesce(word_similarity(lower(f.nome), lower(l.descricao)), 0)) * 0.4 )::numeric, 3)
      from l
      join lancamentos x on x.extrato_linha_id is null and x.fatura_id is null and x.status <> 'cancelado'
                        and x.tipo = case when l.valor < 0 then 'pagar' else 'receber' end
                        and (x.conta_id is null or x.conta_id = l.conta_id
                             or (select tipo from contas_bancarias where id = x.conta_id) <> 'cartao')
                        and abs(coalesce(x.data_pagamento, x.data_vencimento) - l.data) <= 15
      left join fornecedores f on f.id = x.fornecedor_id
     where x.valor = abs(l.valor)
        or similarity(lower(l.descricao), lower(x.descricao)) > 0.3
        or word_similarity(lower(f.nome), lower(l.descricao)) > 0.6
    union all
    select 'fatura', fa.id, 'Fatura ' || cb.nome || ' · venc. ' || to_char(fa.data_vencimento, 'DD/MM'),
           t.total, fa.data_vencimento, null, abs(fa.data_vencimento - l.data), abs(t.total - abs(l.valor)) < 0.01,
           round(((abs(t.total - abs(l.valor)) < 0.01)::int * 0.6 + greatest(0, 0.3 - abs(fa.data_vencimento - l.data) * 0.03) + 0.2)::numeric, 3)
      from l
      join faturas fa on fa.status <> 'paga' and l.valor < 0 and abs(fa.data_vencimento - l.data) <= 20
      join contas_bancarias cb on cb.id = fa.cartao_id
      cross join lateral (select coalesce(sum(case when y.tipo = 'pagar' then y.valor else -y.valor end), 0) as total
                            from lancamentos y where y.fatura_id = fa.id and y.status <> 'cancelado') t
     where abs(t.total - abs(l.valor)) < 0.01
        or (cb.conta_pagamento_id = l.conta_id
            and (lower(l.descricao) ~ 'fatura|cart' or (cb.final_cartao is not null and l.descricao like '%' || cb.final_cartao || '%')))
  ) s
  order by 9 desc, 7
  limit 8
$$;

-- Classificação sugerida para um texto de extrato: 1º regra cadastrada,
-- 2º fornecedor cujo nome aparece no texto, 3º lançamento com descrição parecida.
create or replace function sugerir_classificacao(p_texto text, p_tipo text)
returns table (origem text, descricao text, categoria_id uuid, centro_custo_id uuid, fornecedor_id uuid, projeto_id uuid, regra_id uuid, auto_conciliar boolean)
language plpgsql stable set search_path = public, extensions as $$
declare t text := lower(p_texto);
begin
  return query
    select 'regra', r.descricao, r.categoria_id, r.centro_custo_id, r.fornecedor_id, null::uuid, r.id, r.auto_conciliar
      from regras_classificacao r
     where r.ativo and r.tipo = p_tipo and t like '%' || lower(r.padrao) || '%'
     order by length(r.padrao) desc limit 1;
  if found then return; end if;

  return query
    select 'fornecedor', x.descricao, x.categoria_id, x.centro_custo_id, f.id, x.projeto_id, null::uuid, false
      from fornecedores f
      left join lateral (select * from lancamentos y where y.fornecedor_id = f.id and y.tipo = p_tipo
                          order by y.data_competencia desc limit 1) x on true
     where f.ativo and length(f.nome) >= 4 and word_similarity(lower(f.nome), t) > 0.75
     order by word_similarity(lower(f.nome), t) desc, length(f.nome) desc limit 1;
  if found then return; end if;

  return query
    select 'historico', x.descricao, x.categoria_id, x.centro_custo_id, x.fornecedor_id, x.projeto_id, null::uuid, false
      from lancamentos x
     where x.tipo = p_tipo and x.categoria_id is not null
       and (lower(x.descricao) % t
            or (length(x.descricao) >= 5 and word_similarity(lower(x.descricao), t) > 0.7))
     order by greatest(similarity(lower(x.descricao), t), word_similarity(lower(x.descricao), t)) desc,
              x.data_competencia desc limit 1;
end $$;

-- Liga uma linha do extrato a um ou mais lançamentos (ex.: um PIX em lote
-- que pagou três prestadores). Com um lançamento só, o valor dele passa a ser
-- o do extrato. Com vários, a soma precisa bater.
create or replace function conciliar(p_linha uuid, p_lancamentos uuid[])
returns void language plpgsql set search_path = public as $$
declare l extrato_linhas; v_soma numeric; v_n int; v_tipo text;
begin
  if not is_financeiro() then raise exception 'Sem permissão.'; end if;
  select * into l from extrato_linhas where id = p_linha for update;
  if l.status <> 'pendente' then raise exception 'Esta linha do extrato já foi %.', l.status; end if;
  v_tipo := case when l.valor < 0 then 'pagar' else 'receber' end;
  select count(*), sum(valor) into v_n, v_soma from lancamentos where id = any(p_lancamentos);
  if v_n = 0 then raise exception 'Escolha ao menos um lançamento.'; end if;
  if exists (select 1 from lancamentos where id = any(p_lancamentos) and tipo <> v_tipo) then
    raise exception 'Linha de % só concilia com conta a %.', case when l.valor < 0 then 'saída' else 'entrada' end, v_tipo;
  end if;
  if exists (select 1 from lancamentos where id = any(p_lancamentos) and fatura_id is not null) then
    raise exception 'Compras de cartão se conciliam pela fatura, não uma a uma.';
  end if;
  if exists (select 1 from lancamentos where id = any(p_lancamentos) and extrato_linha_id is not null) then
    raise exception 'Algum desses lançamentos já está conciliado com outra linha.';
  end if;
  if v_n > 1 and abs(v_soma - abs(l.valor)) >= 0.01 then
    raise exception 'A soma dos lançamentos (%) é diferente do valor do extrato (%).',
      brl(v_soma), brl(abs(l.valor));
  end if;
  update lancamentos
     set status = 'pago', data_pagamento = l.data, conta_id = l.conta_id, extrato_linha_id = l.id,
         valor = case when v_n = 1 then abs(l.valor) else valor end
   where id = any(p_lancamentos);
  update extrato_linhas set status = 'conciliado', conciliado_por = auth.uid(), conciliado_em = now() where id = l.id;
end $$;

create or replace function conciliar_fatura(p_linha uuid, p_fatura uuid)
returns void language plpgsql set search_path = public as $$
declare l extrato_linhas;
begin
  if not is_financeiro() then raise exception 'Sem permissão.'; end if;
  select * into l from extrato_linhas where id = p_linha for update;
  if l.status <> 'pendente' then raise exception 'Esta linha do extrato já foi %.', l.status; end if;
  if l.valor > 0 then raise exception 'Pagamento de fatura é uma saída; esta linha é uma entrada.'; end if;
  perform pagar_fatura(p_fatura, l.data, l.conta_id, abs(l.valor));
  update extrato_linhas set status = 'conciliado', fatura_id = p_fatura, conciliado_por = auth.uid(), conciliado_em = now() where id = l.id;
end $$;

-- Cria o lançamento a partir da linha e já concilia. p_dados traz o que a
-- pessoa preencheu (categoria, centro, fornecedor…). Se p_regra vier, grava a
-- regra para as próximas vezes.
create or replace function conciliar_novo(p_linha uuid, p_dados jsonb, p_regra text default null)
returns uuid language plpgsql set search_path = public as $$
declare l extrato_linhas; r lancamentos; v_id uuid; v_tipo text;
begin
  if not is_financeiro() then raise exception 'Sem permissão.'; end if;
  select * into l from extrato_linhas where id = p_linha for update;
  if l.status <> 'pendente' then raise exception 'Esta linha do extrato já foi %.', l.status; end if;
  v_tipo := case when l.valor < 0 then 'pagar' else 'receber' end;
  r := jsonb_populate_record(null::lancamentos, p_dados);
  insert into lancamentos (tipo, descricao, valor, categoria_id, centro_custo_id, fornecedor_id, projeto_id,
                           data_competencia, data_vencimento, data_pagamento, status, conta_id,
                           forma_pagamento, custo_nivel, tags, observacoes, origem, extrato_linha_id)
  values (v_tipo, coalesce(nullif(r.descricao, ''), l.descricao), abs(l.valor), r.categoria_id, r.centro_custo_id,
          r.fornecedor_id, r.projeto_id, coalesce(r.data_competencia, date_trunc('month', l.data)::date),
          l.data, l.data, 'pago', l.conta_id, r.forma_pagamento, r.custo_nivel, coalesce(r.tags, '{}'),
          r.observacoes, 'conciliacao', l.id)
  returning id into v_id;
  update extrato_linhas set status = 'conciliado', conciliado_por = auth.uid(), conciliado_em = now() where id = l.id;
  if coalesce(trim(p_regra), '') <> '' then
    insert into regras_classificacao (padrao, tipo, descricao, categoria_id, centro_custo_id, fornecedor_id)
    values (trim(p_regra), v_tipo, nullif(r.descricao, ''), r.categoria_id, r.centro_custo_id, r.fornecedor_id)
    on conflict (padrao, tipo) do update
      set descricao = excluded.descricao, categoria_id = excluded.categoria_id,
          centro_custo_id = excluded.centro_custo_id, fornecedor_id = excluded.fornecedor_id, ativo = true;
  end if;
  return v_id;
end $$;

create or replace function desconciliar(p_linha uuid)
returns void language plpgsql set search_path = public as $$
declare l extrato_linhas;
begin
  if not is_financeiro() then raise exception 'Sem permissão.'; end if;
  select * into l from extrato_linhas where id = p_linha for update;
  if l.fatura_id is not null then
    update extrato_linhas set status = 'pendente', fatura_id = null, conciliado_por = null, conciliado_em = null where id = l.id;
    perform reabrir_fatura(l.fatura_id);
    return;
  end if;
  -- lançamento criado na própria conciliação é apagado; os outros voltam a ficar em aberto
  delete from lancamentos where extrato_linha_id = l.id and origem = 'conciliacao';
  update lancamentos set extrato_linha_id = null, status = 'aprovado', data_pagamento = null where extrato_linha_id = l.id;
  update extrato_linhas set status = 'pendente', motivo_ignorado = null, conciliado_por = null, conciliado_em = null where id = l.id;
end $$;

create or replace function ignorar_linha(p_linha uuid, p_motivo text)
returns void language plpgsql set search_path = public as $$
begin
  if not is_financeiro() then raise exception 'Sem permissão.'; end if;
  update extrato_linhas set status = 'ignorado', motivo_ignorado = coalesce(nullif(trim(p_motivo), ''), 'sem motivo'),
         conciliado_por = auth.uid(), conciliado_em = now()
   where id = p_linha and status = 'pendente';
  if not found then raise exception 'Só linhas pendentes podem ser ignoradas.'; end if;
end $$;

-- Conciliação automática de uma conta:
-- 1) linha com candidato de valor exato a até 3 dias, sem ambiguidade → concilia;
-- 2) linha que casa com regra marcada "auto_conciliar" → cria e concilia.
-- O que sobrar fica pendente para decidir na tela.
create or replace function conciliar_automatico(p_conta uuid)
returns table (por_valor int, por_regra int) language plpgsql set search_path = public, extensions as $$
declare l extrato_linhas; c record; n int; sc1 numeric; sc2 numeric; v_valor int := 0; v_regra int := 0; s record;
begin
  if not is_financeiro() then raise exception 'Sem permissão.'; end if;
  for l in select * from extrato_linhas where conta_id = p_conta and status = 'pendente' order by data loop
    -- candidato de valor exato a até 3 dias que seja o único, ou que tenha nome
    -- claramente melhor que o 2º (vários PJs de R$ 9.500 no mesmo dia: vale o nome)
    select count(*), max(x.score) into n, sc1 from sugerir_conciliacao(l.id) x where x.valor_igual and x.dias <= 3;
    select coalesce(max(x.score), 0) into sc2 from (select x.score from sugerir_conciliacao(l.id) x
             where x.valor_igual and x.dias <= 3 order by x.score desc offset 1 limit 1) x;
    if n = 1 or (n > 1 and sc1 - sc2 >= 0.25) then
      select * into c from sugerir_conciliacao(l.id) x where x.valor_igual and x.dias <= 3 order by x.score desc limit 1;
      if c.tipo = 'fatura' then perform conciliar_fatura(l.id, c.id); else perform conciliar(l.id, array[c.id]); end if;
      v_valor := v_valor + 1;
      continue;
    end if;
    select * into s from sugerir_classificacao(l.descricao, case when l.valor < 0 then 'pagar' else 'receber' end);
    if s.origem = 'regra' and s.auto_conciliar and s.categoria_id is not null then
      perform conciliar_novo(l.id, jsonb_build_object('descricao', s.descricao, 'categoria_id', s.categoria_id,
                             'centro_custo_id', s.centro_custo_id, 'fornecedor_id', s.fornecedor_id));
      v_regra := v_regra + 1;
    end if;
  end loop;
  return query select v_valor, v_regra;
end $$;

-- ============================================================================
-- VIEWS (parte 2)
-- ============================================================================
drop view if exists vw_lancamentos;
create view vw_lancamentos with (security_invoker = true) as
select l.*,
       c.nome  as categoria,
       c.tipo  as categoria_tipo,
       c.grupo as categoria_grupo,
       cc.nome as centro_custo,
       cb.nome as conta,
       cb.tipo as conta_tipo,
       f.nome  as fornecedor,
       p.nome  as projeto,
       case when l.status in ('previsto','aprovado') and l.data_vencimento < current_date
            then 'atrasado' else l.status end as situacao,
       (select n.id from notas_fiscais n where n.lancamento_id = l.id limit 1) as nota_fiscal_id,
       (r.aguarda_nf and l.status = 'previsto') as aguardando_nf,
       (select count(*) from anexos a where a.lancamento_id = l.id)::int as qtd_anexos,
       (l.extrato_linha_id is not null
        or exists (select 1 from extrato_linhas e where e.fatura_id = l.fatura_id and e.status = 'conciliado')) as conciliado
from lancamentos l
left join categorias       c  on c.id  = l.categoria_id
left join centros_custo    cc on cc.id = l.centro_custo_id
left join contas_bancarias cb on cb.id = l.conta_id
left join fornecedores     f  on f.id  = l.fornecedor_id
left join projetos         p  on p.id  = l.projeto_id
left join recorrencias     r  on r.id  = l.recorrencia_id;

drop view if exists vw_faturas;
create view vw_faturas with (security_invoker = true) as
select fa.*, cb.nome as cartao, cb.final_cartao,
       coalesce(sum(case when l.tipo = 'pagar' then l.valor else -l.valor end) filter (where l.status <> 'cancelado'), 0) as total,
       count(l.id) filter (where l.status <> 'cancelado')::int as itens,
       count(l.id) filter (where l.status <> 'cancelado' and l.categoria_id is null)::int as sem_categoria,
       (select count(*) from anexos a where a.fatura_id = fa.id)::int as qtd_anexos,
       exists (select 1 from extrato_linhas e where e.fatura_id = fa.id and e.status = 'conciliado') as conciliada
from faturas fa
join contas_bancarias cb on cb.id = fa.cartao_id
left join lancamentos l on l.fatura_id = fa.id
group by fa.id, cb.nome, cb.final_cartao;

-- Saldo por conta. Conta corrente: saldo inicial + pagos − faturas pagas por
-- ela. Cartão: o que está em aberto nas faturas (negativo = dívida).
-- saldo_extrato é o último saldo informado pelo banco: se bater com
-- saldo_atual, a conta está conciliada.
drop view if exists vw_saldo_contas;
create view vw_saldo_contas with (security_invoker = true) as
select cb.id, cb.nome, cb.tipo, cb.saldo_inicial, cb.data_saldo_inicial,
       case when cb.tipo = 'cartao' then
         -coalesce((select sum(case when l.tipo = 'pagar' then l.valor else -l.valor end)
                      from lancamentos l where l.conta_id = cb.id and l.status in ('previsto','aprovado')), 0)
       else
         cb.saldo_inicial
         + coalesce((select sum(case when l.tipo = 'receber' then l.valor else -l.valor end)
                       from lancamentos l
                      where l.conta_id = cb.id and l.status = 'pago' and l.fatura_id is null
                        and (cb.data_saldo_inicial is null or l.data_pagamento >= cb.data_saldo_inicial)), 0)
         - coalesce((select sum(f.valor_pago) from faturas f
                      where f.conta_pagamento_id = cb.id and f.status = 'paga'
                        and (cb.data_saldo_inicial is null or f.data_pagamento >= cb.data_saldo_inicial)), 0)
       end as saldo_atual,
       (select e.saldo from extrato_linhas e where e.conta_id = cb.id and e.saldo is not null
         order by e.data desc, e.created_at desc limit 1) as saldo_extrato,
       (select max(e.data) from extrato_linhas e where e.conta_id = cb.id) as data_extrato,
       (select count(*) from extrato_linhas e where e.conta_id = cb.id and e.status = 'pendente')::int as pendentes
from contas_bancarias cb
where cb.ativo;

drop view if exists vw_extrato;
create view vw_extrato with (security_invoker = true) as
select e.*,
       (select string_agg(l.descricao || ' (R$ ' || brl(l.valor) || ')', ' + ')
          from lancamentos l where l.extrato_linha_id = e.id) as conciliado_com,
       (select 'Fatura ' || cb.nome || ' · ' || to_char(fa.data_vencimento, 'DD/MM/YYYY')
          from faturas fa join contas_bancarias cb on cb.id = fa.cartao_id where fa.id = e.fatura_id) as fatura
from extrato_linhas e;

-- ============================================================================
-- RLS, AUDITORIA E STORAGE (parte 2)
-- ============================================================================
do $$
declare t text;
begin
  foreach t in array array['faturas','extrato_importacoes','extrato_linhas','regras_classificacao','anexos']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists interno_le on %I', t);
    execute format('drop policy if exists financeiro_escreve on %I', t);
    execute format('create policy interno_le on %I for select to authenticated using (is_interno())', t);
    execute format('create policy financeiro_escreve on %I for all to authenticated
                    using (is_financeiro()) with check (is_financeiro())', t);
    execute format('drop trigger if exists auditoria_%1$s on %1$s', t);
    execute format('create trigger auditoria_%1$s after insert or update or delete on %1$s
                    for each row execute function registra_auditoria()', t);
  end loop;
end $$;

-- extrato_linhas é volumoso: auditar só mudanças de status, não cada import
drop trigger if exists auditoria_extrato_linhas on extrato_linhas;
create trigger auditoria_extrato_linhas after update of status on extrato_linhas
  for each row execute function registra_auditoria();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('anexos', 'anexos', false, 15728640,
        array['application/pdf','image/png','image/jpeg','text/xml','application/xml'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
                               allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists anexos_interno_le  on storage.objects;
drop policy if exists anexos_financeiro  on storage.objects;
create policy anexos_interno_le on storage.objects for select to authenticated
  using (bucket_id = 'anexos' and is_interno());
create policy anexos_financeiro on storage.objects for all to authenticated
  using (bucket_id = 'anexos' and is_financeiro())
  with check (bucket_id = 'anexos' and is_financeiro());


-- ============================================================================
-- DEPOIS DE RODAR: promova o primeiro admin (troque o e-mail).
-- Crie o login antes, pela tela do sistema ("Criar acesso").
--
--   update perfis set papel = 'admin', nome = 'Seu nome'
--   where lower(email) = lower('voce@empresa.com.br');
-- ============================================================================

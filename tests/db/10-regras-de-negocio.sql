-- ============================================================================
-- Testes das regras de negócio e de acesso (RLS), com dados fictícios.
-- Cada bloco falha com uma mensagem clara se a regra quebrar.
-- Rodar: npm run test:db   (veja tests/db/run.sh)
-- ============================================================================
\set ON_ERROR_STOP 1
\set QUIET 1

-- ---------------------------------------------------------------- dados ----
insert into categorias (nome, tipo, grupo) values
  ('Profissionais Externos','despesa','Pessoas'), ('Hotmart','receita','Receitas'),
  ('Taxas Bancárias','despesa','Financeiro'), ('Programas','despesa','Tecnologia');
insert into contas_bancarias (nome, tipo) values ('Banco Teste','corrente');
insert into contas_bancarias (nome, tipo, dia_fechamento, dia_vencimento, conta_pagamento_id)
  select 'Cartão Teste','cartao',3,10,id from contas_bancarias where nome = 'Banco Teste';
insert into fornecedores (nome, tipo, exige_nf, valor_mensal, dia_pagamento, categoria_padrao_id)
  select n, 'pj', true, 5000, 3, (select id from categorias where nome = 'Profissionais Externos')
  from unnest(array['Ana Souza','Bruno Lima']) n;
insert into recorrencias (tipo, descricao, valor, categoria_id, conta_id, fornecedor_id, dia_vencimento, inicio, aguarda_nf)
  select 'pagar', 'PJ ' || f.nome, 5000, f.categoria_padrao_id, (select id from contas_bancarias where nome='Banco Teste'), f.id, 3, '2026-01-01', true
  from fornecedores f;
insert into recorrencias (tipo, descricao, valor, categoria_id, conta_id, dia_vencimento, inicio)
  select 'pagar', 'Assinatura software', 100, (select id from categorias where nome='Programas'),
         (select id from contas_bancarias where nome='Cartão Teste'), 10, '2026-01-01';
insert into lancamentos (tipo, descricao, valor, categoria_id, data_competencia, data_vencimento, data_pagamento, status)
  select 'receber', 'Hotmart', 1000, id, '2026-08-01', '2026-08-05', '2026-08-05', 'pago' from categorias where nome = 'Hotmart';

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000000a', 'admin@empresa.test'),
  ('00000000-0000-0000-0000-00000000000b', 'ana@pj.test'),
  ('00000000-0000-0000-0000-00000000000c', 'intruso@x.test');
update perfis set papel = 'admin' where email = 'admin@empresa.test';
-- e-mail preenchido DEPOIS do login do PJ: o vínculo tem que acontecer mesmo assim
update fornecedores set email = 'ana@pj.test' where nome = 'Ana Souza';

do $$ begin
  assert (select f.nome from perfis p join fornecedores f on f.id = p.fornecedor_id where p.email = 'ana@pj.test') = 'Ana Souza',
    'PJ deveria ser vinculado ao cadastro pelo e-mail';
  assert (select papel from perfis where email = 'intruso@x.test') = 'colaborador',
    'cadastro novo deveria nascer com o menor acesso (colaborador)';
end $$;

-- o atacante conhece o id de outro fornecedor
select id as bruno_id from fornecedores where nome = 'Bruno Lima' \gset

set role authenticated;

-- ------------------------------------------------ recorrências e cartão ----
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
do $$ declare n1 int; n2 int; begin
  n1 := gerar_recorrencias('2026-10-01'); n2 := gerar_recorrencias('2026-10-20');
  assert n1 = 3, format('esperava 3 lançamentos gerados, veio %s', n1);
  assert n2 = 0, 'gerar recorrências duas vezes não pode duplicar';
  assert (select data_competencia from lancamentos where descricao = 'PJ Ana Souza') = '2026-09-01',
    'PJ que aguarda NF: pagamento de outubro é da competência de setembro';
  assert (select status from lancamentos where descricao = 'Assinatura software') = 'aprovado'
     and (select fatura_id is not null from lancamentos where descricao = 'Assinatura software'),
    'compra no cartão deveria entrar numa fatura, como aprovado';
end $$;

-- ------------------------------------------------------ portal do PJ ----
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
do $$ begin
  assert (select count(*) from lancamentos) = 0, 'PJ não pode ver lançamentos da empresa';
  assert (select count(*) from fornecedores) = 1, 'PJ só vê o próprio cadastro';
  assert (select count(*) from perfis) = 1, 'PJ só vê o próprio perfil';
end $$;
-- tenta mandar nota em nome de outro fornecedor e já aprovada
insert into notas_fiscais (fornecedor_id, competencia, numero, valor, arquivo_path, status)
  values (:'bruno_id', '2026-09-17', '101', 5000, 'x/2026-09/nf.pdf', 'aprovada');
-- tenta trocar a própria chave PIX
update fornecedores set chave_pix = 'golpe';
do $$ begin
  assert (select f.nome || '/' || n.status || '/' || n.competencia from notas_fiscais n join fornecedores f on f.id = n.fornecedor_id) = 'Ana Souza/enviada/2026-09-01',
    'NF do PJ tem que ficar no nome dele, como enviada, com competência no dia 1';
end $$;
reset role; set role authenticated;
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
do $$ begin
  assert (select chave_pix from fornecedores where nome = 'Ana Souza') is null, 'PJ não pode alterar a própria chave PIX';
end $$;

-- intruso sem vínculo não envia nem vê nada
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000c';
do $$ begin
  begin
    insert into notas_fiscais (fornecedor_id, competencia, numero, valor, arquivo_path)
      values (gen_random_uuid(), '2026-09-01', '1', 1, 'a');
    assert false, 'usuário sem vínculo não pode enviar NF';
  exception when raise_exception then null; end;
  assert (select count(*) from notas_fiscais) = 0, 'usuário sem vínculo não vê NFs';
end $$;

-- PJ não aprova a própria nota
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000b';
do $$ begin
  begin perform aprovar_nota_fiscal((select id from notas_fiscais limit 1));
        assert false, 'PJ não pode aprovar NF';
  exception when raise_exception then null; end;
end $$;

-- ------------------------------------------------------ aprovação NF ----
set request.jwt.claim.sub = '00000000-0000-0000-0000-00000000000a';
do $$ declare v_lanc uuid; begin
  v_lanc := aprovar_nota_fiscal((select id from notas_fiscais where numero = '101'));
  assert (select count(*) from lancamentos l join fornecedores f on f.id = l.fornecedor_id where f.nome = 'Ana Souza') = 1,
    'aprovar a NF deveria reaproveitar a previsão da recorrência, não criar outra';
  assert (select status from lancamentos where id = v_lanc) = 'aprovado', 'previsão deveria virar aprovado';
end $$;

-- ------------------------------------------------------- conciliação ----
insert into extrato_linhas (conta_id, data, descricao, valor, hash)
select c.id, v.d::date, v.t, v.v, v.t || v.d from contas_bancarias c,
  (values ('2026-10-03', 'PIX ENVIADO ANA SOUZA', -5000.00),
          ('2026-10-10', 'PAGTO FATURA CARTAO', -100.00),
          ('2026-10-05', 'TAR PACOTE BANCO', -39.90),
          ('2026-11-05', 'TAR PACOTE BANCO', -39.90)) v(d, t, v)
where c.nome = 'Banco Teste';

do $$ declare r record; begin
  select * into r from conciliar_automatico((select id from contas_bancarias where nome = 'Banco Teste'));
  assert r.por_valor = 2, format('esperava 2 conciliações automáticas (PIX da Ana e fatura), veio %s', r.por_valor);
  -- Bruno também tem 5.000 no mesmo dia: quem desempata é o nome no extrato
  assert (select f.nome from lancamentos l join fornecedores f on f.id = l.fornecedor_id
           where l.extrato_linha_id = (select id from extrato_linhas where descricao like 'PIX ENVIADO ANA%')) = 'Ana Souza',
    'PIX da Ana deveria ser conciliado com o lançamento da Ana, não do Bruno';
  assert (select status from notas_fiscais where numero = '101') = 'paga', 'NF deveria aparecer como paga para o PJ';
  assert (select status from faturas limit 1) = 'paga', 'fatura deveria ficar paga';
  assert (select status from lancamentos where descricao = 'Assinatura software') = 'pago', 'compras da fatura viram pagas';
end $$;

-- tarifa: cria a partir do extrato e grava regra; a do mês seguinte concilia sozinha
do $$ declare r record; begin
  perform conciliar_novo((select id from extrato_linhas where descricao = 'TAR PACOTE BANCO' and data = '2026-10-05'),
    jsonb_build_object('descricao', 'Tarifa bancária', 'categoria_id', (select id from categorias where nome = 'Taxas Bancárias')), 'TAR PACOTE');
  select * into r from conciliar_automatico((select id from contas_bancarias where nome = 'Banco Teste'));
  assert r.por_regra = 1, 'a regra cadastrada deveria conciliar a tarifa do mês seguinte';
  assert (select count(*) from extrato_linhas where status = 'pendente') = 0, 'não deveria sobrar linha pendente';
end $$;

-- soma errada em conciliação múltipla é recusada
do $$ begin
  insert into extrato_linhas (conta_id, data, descricao, valor, hash)
    select id, '2026-10-20', 'SISPAG LOTE', -7000, 'lote' from contas_bancarias where nome = 'Banco Teste';
  begin
    perform conciliar((select id from extrato_linhas where hash = 'lote'),
                      array(select id from lancamentos where descricao in ('PJ Bruno Lima', 'Hotmart')));
    assert false, 'conciliar entrada com saída ou soma diferente deveria falhar';
  exception when raise_exception then null; end;
end $$;

-- desfazer: fatura reabre, compras voltam a aprovado; lançamento criado pela conciliação some
do $$ begin
  perform desconciliar((select id from extrato_linhas where descricao = 'PAGTO FATURA CARTAO'));
  assert (select status from faturas limit 1) = 'aberta', 'desfazer deveria reabrir a fatura';
  assert (select status from lancamentos where descricao = 'Assinatura software') = 'aprovado', 'compras voltam para aprovado';
  perform desconciliar((select id from extrato_linhas where descricao = 'TAR PACOTE BANCO' and data = '2026-10-05'));
  assert (select count(*) from lancamentos where descricao = 'Tarifa bancária') = 1, 'desfazer apaga o lançamento criado pela conciliação';
end $$;

-- ------------------------------------------------ DRE / plano de contas ----
do $$ begin
  assert (select dre_linha from categorias where nome = 'Hotmart') = 'receita_bruta', 'Hotmart deveria cair em Receita bruta';
  assert (select dre_linha from categorias where nome = 'Profissionais Externos') = 'pessoas', 'categoria do grupo Pessoas vai para a linha Pessoas';
  assert (select dre_linha from categorias where nome = 'Taxas Bancárias') = 'financeiro', 'grupo Financeiro vai para Resultado financeiro';
  assert (select dre_linha from categorias where nome = 'Distribuição de lucros') is null, 'distribuição de lucros fica fora do DRE';
  assert (select count(*) from categorias where tipo <> 'neutra' and dre_linha is null) = 0, 'toda categoria de resultado precisa de uma linha do DRE';
  -- saída entra negativa, entrada positiva; o mês de agosto tem só a venda Hotmart de 1.000
  assert (select sum(realizado) from vw_dre where mes = '2026-08-01' and dre_linha = 'receita_bruta') = 1000, 'DRE deveria mostrar a receita de agosto';
  begin
    update categorias set dre_linha = 'ebitda' where nome = 'Programas';
    assert false, 'categoria não pode ir para uma linha de total';
  exception when raise_exception then null; end;
  begin
    insert into categorias (nome, tipo, dre_linha) values ('Neutra teste', 'neutra', 'outras');
    assert false, 'categoria neutra não pode entrar no DRE';
  exception when check_violation then null; end;
end $$;

reset role;
\echo 'OK: todos os testes de banco passaram'

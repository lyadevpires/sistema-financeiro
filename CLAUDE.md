# Sistema Financeiro — contexto para o Claude Code

Sistema de contas a pagar e a receber de uma empresa de educação digital (cursos, mentorias, eventos),
feito para **substituir o Granatum**. Operado no dia a dia pela equipe do financeiro (não são devs).
Também tem um **portal para prestadores PJ** enviarem as notas fiscais deles.

Idioma: tudo em **português do Brasil** — interface, mensagens de erro, comentários, nomes de tabela e coluna.

## Stack e estrutura

- **Front:** HTML + JavaScript puro (ES modules), sem framework e sem build de bundle. `public/index.html` é o app inteiro
  (CSS + JS inline); `public/js/extrato-parser.js` é o leitor de extrato (funções puras, testadas).
  Bibliotecas por CDN: `@supabase/supabase-js@2` (jsdelivr), SheetJS e pdf.js (cdnjs, carregados só quando usados).
- **Banco:** Supabase (Postgres + Auth + Storage). Toda regra de negócio sensível está **no banco** (triggers, funções RPC, RLS),
  não no front. O front é uma casca: se alguém chamar a API direto, as regras continuam valendo.
- **Deploy:** Vercel (site estático). `npm run build` só gera `public/config.js` com `SUPABASE_URL` e `SUPABASE_ANON_KEY`.

```
public/index.html                 app (equipe interna + portal do PJ, escolhido pelo papel do usuário)
public/js/extrato-parser.js       leitura de CSV/Excel de extrato e fatura
supabase/migrations/*.sql         schema completo (tabelas, RLS, storage, triggers, funções, views)
dados-privados/                   carga inicial com dados REAIS da empresa — fora do git (.gitignore)
tests/parser.test.mjs             testes do leitor de extrato (node:test)
tests/db/                         testes de regra de negócio e RLS num Postgres descartável
scripts/gerar-config.mjs          build: gera public/config.js a partir do ambiente
docs/regras-de-negocio.md         o porquê de cada regra — leia antes de mexer em lançamentos, NF, conciliação ou cartões
```

## Comandos

```bash
npm run dev          # gera config.js a partir do .env e serve public/ em http://localhost:3000
npm run test:parser  # testes do leitor de extrato
npm run test:db      # testes de banco — exige DATABASE_URL de um Postgres DESCARTÁVEL (apaga e recria um banco)
supabase db push     # aplica migrations novas no projeto linkado (produção!) — só com o ok do usuário
```

Para `test:db` sem Supabase local: `docker run -d --name pgteste -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:16`
e `DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres`. O teste usa `tests/db/00-shim-supabase.sql`
para imitar `auth`, `storage` e os papéis `anon`/`authenticated`.

**Sempre rode `npm run test:parser` e `npm run test:db` antes de commitar mudança em SQL ou no parser.**
Mudou regra de negócio? Acrescente um bloco em `tests/db/10-regras-de-negocio.sql` que prove a regra nova.

## Regras que não podem quebrar

Detalhes e motivos em `docs/regras-de-negocio.md`. Resumo:

1. **RLS sempre ligado.** Toda tabela nova: `enable row level security` + policies usando `is_interno()` (lê),
   `is_financeiro()` (escreve), `is_admin()`. Nunca use a service_role key no front (o build recusa).
2. **Papéis:** `admin`, `financeiro`, `leitura`, `colaborador`. Cadastro novo nasce `colaborador` (menor acesso).
   O PJ (`colaborador`) só vê as próprias NFs e o próprio cadastro, e **não edita dados de pagamento** (PIX) — é proteção contra golpe.
3. **Dinheiro:** `numeric(14,2)`, valor **sempre positivo**; o sentido vem de `tipo` (`pagar`/`receber`). Nunca float para somar.
4. **Três datas por lançamento:** `data_competencia` (DRE, sempre dia 1), `data_vencimento` (fluxo previsto),
   `data_pagamento` (fluxo realizado). `status = 'pago'` exige `data_pagamento`.
5. **O extrato bancário é a fonte da verdade.** Conciliar grava no lançamento a data, a conta e o valor do banco.
6. **NF de PJ:** a recorrência do PJ (`aguarda_nf`) gera uma previsão com competência do **mês anterior** ao pagamento.
   Aprovar a NF **reaproveita** essa previsão (não duplica). Pagar o lançamento marca a NF como paga no portal.
7. **Cartão:** compra é lançamento com `conta_id` = cartão; o trigger `lancamento_cartao` põe na fatura certa (pelo dia de
   fechamento) e copia vencimento e status da fatura. Não marque compra de cartão como paga uma a uma — paga-se a fatura.
8. **Categorias `neutra`** (transferência, aporte) ficam fora do DRE e do fluxo de resultado.
9. **Idempotência:** gerar recorrências e importar extrato podem rodar de novo sem duplicar (índices únicos). Mantenha assim.
10. **Auditoria:** tabelas de negócio têm trigger `registra_auditoria`. Tabela nova de negócio entra na lista.
11. **XSS:** o front monta HTML com a tag `html\`...\`` que escapa tudo que é interpolado. Texto vindo do banco
    (principalmente o que o PJ digita) **nunca** vai para `innerHTML` sem passar por ela. `raw()` só para HTML que o próprio código gerou.

## Convenções

- **Migrations:** nunca edite uma migration já aplicada em produção. Crie `supabase/migrations/AAAAMMDDHHMMSS_descricao.sql`.
  Funções com `create or replace`; tabelas com `if not exists`; views que mudam colunas com `drop view if exists` + `create view`.
- **Funções SQL** chamadas pelo front verificam permissão no começo (`if not is_financeiro() then raise exception ...`)
  e levantam mensagens em português que podem ir direto para a tela.
- **Cores:** só pelos tokens CSS do `:root` (tema claro e escuro). Entradas = `--pos` (azul), saídas = `--neg` (vermelho),
  sucesso/pago = `--ok` (verde), atenção = `--warn`, marca = `--brand` (violeta).
- **Textos da interface:** diretos, na voz de quem usa ("Conciliar", "Registrar pagamento"). Erro diz o que houve e o que fazer.
- **Dados reais** (nomes, salários, pró-labore) só em `dados-privados/`, que não vai para o git. Em teste, use dados fictícios.
- Não faça `supabase db push`, `vercel --prod` nem nada que altere produção sem confirmação explícita do usuário.

## Estado atual e próximos passos

Pronto e testado: lançamentos a pagar/receber, recorrências, NFs com portal do PJ, conciliação bancária
(importação CSV/Excel/PDF, conciliação automática, regras), cartões e faturas, anexos, DRE, projetos, custo de pessoas,
auditoria, usuários e papéis. Ainda não rodou contra um Supabase real nem com extratos reais dos bancos.

Roadmap sugerido, em ordem — confirme a prioridade com o usuário antes de começar cada item:

1. **Primeiro deploy** (GitHub → Supabase → Vercel) e checklist de produção de `docs/deploy.md`.
2. **Validar o importador com extratos reais** do Itaú e do Santander; ajustar `extrato-parser.js` e acrescentar casos ao teste.
3. **Separar `index.html` em módulos** (`public/js/views/*.js`, `public/css/app.css`) sem mudar comportamento, e então ligar
   uma Content-Security-Policy restrita no `vercel.json` (hoje o JS inline impede).
4. **Ler o XML da NF-e/NFS-e** enviado pelo PJ para preencher número, valor, data e CNPJ e conferir o CNPJ com o cadastro.
5. **E-mails automáticos** (Edge Function + Resend): NF aprovada/devolvida/paga para o PJ; lembrete de envio no prazo.
6. **Integração com o Fluxer** (painel de métricas da mentoria) — pausada a pedido do usuário; não comece sem ele pedir.

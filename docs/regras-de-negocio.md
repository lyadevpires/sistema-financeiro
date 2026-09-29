# Regras de negócio — o porquê

Referência para quem for mexer no sistema. Cada regra está implementada no banco
(`supabase/migrations/`) e coberta por `tests/db/10-regras-de-negocio.sql`.

## Modelo: um lançamento para tudo

Igual ao Granatum: todo dinheiro que entra ou sai é uma linha de `lancamentos`, classificada por categoria,
centro de custo, conta, fornecedor/cliente, projeto e tags. Contas a pagar e a receber são a mesma tabela filtrada
por `tipo`. Isso faz o fluxo de caixa e o DRE saírem de uma consulta só, e é o que o time já sabe operar.

- `valor` é sempre positivo. O sinal vem do `tipo`. Evita o erro clássico de somar despesa negativa com negativa.
- Status: `previsto` (vai acontecer), `aprovado` (confirmado, esperando pagamento), `pago`, `cancelado`.
  "Atrasado" não é status gravado: a view `vw_lancamentos` calcula (`situacao`) quando vence e não foi pago.
- Três datas:
  - `data_competencia` — a que mês pertence (DRE). Ex.: o serviço de setembro do PJ.
  - `data_vencimento` — quando deve ser pago (fluxo previsto).
  - `data_pagamento` — quando saiu do banco (fluxo realizado).

## Recorrências

Modelos em `recorrencias` que viram lançamentos `previsto` com `gerar_recorrencias(mes)`. Rodar duas vezes no
mesmo mês não duplica (índice único `recorrencia_id + data_competencia`). Mudar a recorrência não altera o que já foi gerado.

## Notas fiscais dos PJs

- O PJ cria login com o e-mail que está no cadastro dele (`fornecedores.email`); o trigger `handle_new_user` vincula.
  Se o e-mail for cadastrado depois, `vincular_perfil_por_email` vincula. "Confirm email" do Supabase precisa estar ligado,
  senão qualquer um cria login com o e-mail de um PJ.
- Recorrência de PJ tem `aguarda_nf = true`: a previsão do pagamento de outubro nasce com competência de **setembro**
  (serviço de setembro, pago em outubro).
- `aprovar_nota_fiscal` procura a previsão do mesmo PJ na mesma competência e a confirma com o valor da nota.
  Sem previsão, cria um lançamento novo. Assim o fluxo de caixa enxerga o custo antes da nota e ninguém paga sem nota.
- O trigger `nf_protege_campos` impede o PJ de: enviar em nome de outro fornecedor, marcar a própria nota como
  aprovada, ou mexer numa nota já aprovada. As RLS limitam leitura e escrita às notas do próprio fornecedor.
- Quando o lançamento ligado à NF é pago, `lancamento_sincroniza_nf` marca a NF como paga (o PJ vê no portal).
- O PJ **não** edita o próprio cadastro: troca de chave PIX é o golpe mais comum em contas a pagar
  (invadem o e-mail do prestador e redirecionam o pagamento). Troca passa pelo financeiro.
- Arquivos no bucket privado `notas-fiscais`, caminho `<fornecedor_id>/<AAAA-MM>/<arquivo>`. A primeira pasta
  é o que a policy de storage usa para isolar cada PJ.

## Conciliação bancária

- O extrato importado vai para `extrato_linhas` (valor negativo = saída). `hash` único por conta impede duplicar
  ao reimportar um período que se sobrepõe.
- **O extrato é a fonte da verdade:** `conciliar()` grava no lançamento a data, a conta e — se for um só lançamento — o valor do banco.
  Com vários lançamentos (PIX em lote), a soma precisa bater.
- `sugerir_conciliacao(linha)`: candidatos do mesmo sentido, até 15 dias, com valor igual ou texto parecido
  (pg_trgm), mais faturas de cartão com o mesmo total.
- `conciliar_automatico(conta)`: concilia sozinho quando há candidato de valor exato a até 3 dias **sem ambiguidade**
  (único, ou com nota claramente maior que o segundo — ex.: dois PJs de R$ 5.000 no mesmo dia, o nome no extrato desempata).
  Depois aplica as regras marcadas `auto_conciliar`.
- `sugerir_classificacao(texto, tipo)`: 1º regra cadastrada, 2º nome de fornecedor contido no texto, 3º histórico parecido.
- `conciliar_novo(linha, dados, regra)`: cria o lançamento a partir da linha e concilia; com `regra`, grava para as próximas.
- `desconciliar`: lançamento criado pela conciliação é apagado; os que já existiam voltam a `aprovado`; fatura reabre.
- A tela compara `saldo_atual` (sistema) com o último `saldo` informado pelo banco. Para bater, a conta precisa de
  `saldo_inicial` + `data_saldo_inicial`.

## Cartões de crédito

- Cartão é uma `contas_bancarias` com `tipo = 'cartao'`, `dia_fechamento`, `dia_vencimento` e `conta_pagamento_id`.
- Compra = lançamento com `conta_id` do cartão. O trigger `lancamento_cartao`:
  escolhe a fatura pela data da compra (`data_documento`, ou a competência) — comprou no dia do fechamento ou depois,
  vai para a fatura seguinte —, copia o vencimento da fatura e força o status (`aprovado`, ou `pago` se a fatura já foi paga).
- `pagar_fatura` (ou conciliar a linha do extrato com a fatura) marca todas as compras como pagas na data do pagamento.
  Resultado: o DRE mostra cada gasto na sua categoria e o fluxo de caixa mostra uma saída só, no dia certo.
- Saldo de conta corrente desconta as faturas pagas por ela; saldo de cartão é o que está em aberto (negativo).

## Categorias neutras

`categorias.tipo = 'neutra'` (Transferência, Aporte): entram e saem do caixa mas não são receita nem despesa.
Ficam fora do DRE e de `vw_fluxo_mensal`.

## Custo de pessoas

CLT = salário × (1 + encargos%) × (1 + 1/12 de 13º + 1,333/12 de férias com 1/3). Encargos incidem também sobre
13º e férias. O % padrão (35,8%) é de Lucro Real/Presumido; Simples Nacional é outra conta — ajustável em Parâmetros.

## Importação do Granatum

`dados-privados/` foi gerado a partir do export do Granatum (jan–ago/2026):
- Fornecedor vazio no export → nome tirado da descrição ("PJ - Fulano").
- Recorrência = mesma despesa (fornecedor/descrição + categoria) paga em jun, jul **e** ago; IOF, juros, tarifas e mídia paga ficaram de fora.
- Cartões deduzidos de "Fatura cartão final XXXX"; fechamento estimado em 7 dias antes do vencimento (conferir).
- Linhas sem data de pagamento (projeções do Granatum) não foram importadas.

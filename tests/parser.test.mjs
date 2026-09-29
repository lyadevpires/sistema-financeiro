// Testes do leitor de extrato. Rodar: npm run test:parser
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseNum, parseData, parseCSV, tabelaParaExtrato, chavesExtrato } from '../public/js/extrato-parser.js';

test('números em formato brasileiro, americano e com sinal do banco', () => {
  assert.equal(parseNum('1.234,56'), 1234.56);
  assert.equal(parseNum('1.234,56-'), -1234.56);
  assert.equal(parseNum('(89,90)'), -89.9);
  assert.equal(parseNum('1.234,56 D'), -1234.56);
  assert.equal(parseNum('1,234.56'), 1234.56);
  assert.equal(parseNum(1234.5), 1234.5);
  assert.ok(Number.isNaN(parseNum('')));
});

test('datas: dd/mm/aaaa, dd/mm sem ano, "05 OUT", serial do Excel', () => {
  assert.equal(parseData('01/10/2026', 2026), '2026-10-01');
  assert.equal(parseData('03/09', 2026), '2026-09-03');
  assert.equal(parseData('05 OUT', 2026), '2026-10-05');
  assert.equal(parseData(46300, 2026), '2026-10-05');
  assert.equal(parseData('SALDO', 2026), null);
});

test('extrato no layout do Itaú: descarta linhas de saldo e mantém o sinal', () => {
  const csv = `EXTRATO CONTA CORRENTE
data;lançamento;ag./origem;valor (R$);saldos (R$)
30/09/2026;SALDO ANTERIOR;;;1.200.000,00
01/10/2026;PIX TRANSF ERICA G01/10;;-9.500,00;
01/10/2026;SALDO DO DIA;;;1.190.500,00
02/10/2026;TED HOTMART COMPANY;;250.000,00;1.440.500,00`;
  const { linhas } = tabelaParaExtrato(parseCSV(csv), 2026);
  assert.deepEqual(linhas.map(l => [l.data, l.valor]), [['2026-10-01', -9500], ['2026-10-02', 250000]]);
  assert.equal(linhas[1].saldo, 1440500);
});

test('extrato no layout do Santander: colunas de crédito e débito', () => {
  const csv = `Data,Descrição,Docto,Situação,Crédito (R$),Débito (R$),Saldo (R$)
"05/10/2026","PAGAMENTO CARTAO CREDITO","000123","","","1.234,56","98.765,44"
"06/10/2026","PIX RECEBIDO","","","500,00","","99.265,44"`;
  const { linhas } = tabelaParaExtrato(parseCSV(csv), 2026);
  assert.deepEqual(linhas.map(l => l.valor), [-1234.56, 500]);
  assert.equal(linhas[0].documento, '000123');
});

test('linhas idênticas no mesmo dia geram chaves diferentes (não se perdem nem duplicam)', () => {
  const l = { data: '2026-10-02', valor: -45000, descricao: 'SISPAG FORNECEDORES', documento: null };
  const [a, b] = chavesExtrato([l, { ...l }]);
  assert.notEqual(a, b);
  assert.deepEqual(chavesExtrato([l, { ...l }]), [a, b]); // reimportar gera as mesmas chaves
});

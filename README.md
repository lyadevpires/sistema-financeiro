# Sistema Financeiro

Contas a pagar e a receber, conciliação bancária, cartões de crédito e portal de notas fiscais para prestadores PJ.
Substitui o Granatum. HTML + JavaScript puro, Supabase e Vercel.

- **Instalar e publicar:** [`docs/deploy.md`](docs/deploy.md)
- **Regras de negócio:** [`docs/regras-de-negocio.md`](docs/regras-de-negocio.md)
- **Contexto para o Claude Code:** [`CLAUDE.md`](CLAUDE.md)

```bash
cp .env.example .env   # preencher SUPABASE_URL e SUPABASE_ANON_KEY
npm run dev            # http://localhost:3000
npm run test:parser
DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres npm run test:db   # Postgres descartável
```

`dados-privados/` tem a carga inicial com dados reais da empresa (nomes, salários, pró-labore) e **não vai para o git**.

# Primeiro prompt para o Claude Code

Abra o terminal na pasta `sistema-financeiro`, rode `claude` e cole:

---

Leia CLAUDE.md, docs/regras-de-negocio.md e docs/deploy.md antes de qualquer coisa.

Objetivo desta sessão: o primeiro deploy do sistema — repositório privado no meu GitHub, projeto novo no Supabase
(região São Paulo) e site na Vercel —, seguindo docs/deploy.md.

1. Confira se gh, supabase, vercel e psql estão instalados e logados; me diga o que falta instalar ou logar.
2. Rode `npm run test:parser`. Se houver Docker, suba um Postgres descartável e rode `npm run test:db`.
3. Faça o `git init` e, antes do primeiro commit, me mostre o `git status`: dados-privados/, .env e public/config.js não podem entrar.
4. Siga o deploy. Pare e me pergunte antes de cada ação que cria ou altera algo de verdade:
   criar o repositório, criar o projeto no Supabase, `supabase db push`, carregar os dados de dados-privados/ e publicar na Vercel.
   Quando precisar de senha, organização ou login, me peça — não invente valores e não grave senha em arquivo.
5. No fim, me entregue: a URL de produção, o project ref do Supabase e a lista do checklist da seção 5 do deploy.md
   com o que ainda depende de mim no painel.

Não mude código nesta sessão, só se algo impedir o deploy — e nesse caso me explique antes.

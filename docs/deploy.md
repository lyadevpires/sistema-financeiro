# Deploy: GitHub → Supabase → Vercel

Passo a passo para o primeiro deploy. O Claude Code consegue fazer a maior parte pelo terminal
(`gh`, `supabase`, `vercel`); os pontos marcados com 👤 dependem do usuário (login, senha, clique no painel).

## 0. Ferramentas

```bash
gh --version        # GitHub CLI       → https://cli.github.com
supabase --version  # Supabase CLI     → npm i -g supabase  (ou brew install supabase/tap/supabase)
vercel --version    # Vercel CLI       → npm i -g vercel
psql --version      # cliente Postgres → para carregar os dados reais
```
👤 `gh auth login`, `supabase login`, `vercel login` (abrem o navegador).

## 1. GitHub

```bash
git init -b main
git add . && git status          # conferir: dados-privados/, .env e public/config.js NÃO podem aparecer
git commit -m "Sistema financeiro: versão inicial"
gh repo create sistema-financeiro --private --source . --push
```
O repositório deve ser **privado**. Mesmo sem os dados reais, ele descreve a estrutura financeira da empresa.

## 2. Supabase (projeto novo)

Use um projeto novo, não o do protótipo antigo: o modelo mudou e alguns nomes de tabela se repetem.

```bash
supabase orgs list
supabase projects create sistema-financeiro --org-id <ORG_ID> --region sa-east-1 --db-password '<SENHA_FORTE>'
supabase link --project-ref <PROJECT_REF>
supabase db push                 # aplica supabase/migrations/
supabase projects api-keys --project-ref <PROJECT_REF>   # pegar a anon key (NUNCA a service_role)
```
- `sa-east-1` = São Paulo: menor latência e dados no Brasil.
- 👤 guarde a senha do banco num gerenciador de senhas; ela não fica em nenhum arquivo do projeto.

Carregar os dados reais (a partir da pasta local `dados-privados/`, que não está no git):
```bash
# connection string: painel do Supabase → Connect → Session pooler (porta 5432)
psql "<CONNECTION_STRING>" -v ON_ERROR_STOP=1 -f dados-privados/01-cadastros.sql
psql "<CONNECTION_STRING>" -v ON_ERROR_STOP=1 -f dados-privados/02-historico-2026.sql   # opcional
```

### Autenticação (👤 painel do Supabase)
1. **Authentication → Sign In / Providers → Email:** "Confirm email" **ligado**.
2. **Authentication → URL Configuration:** *Site URL* = domínio de produção da Vercel;
   *Redirect URLs* = o mesmo domínio + `https://*-<time>.vercel.app/**` para os previews.
3. **Authentication → SMTP Settings:** SMTP próprio (Resend, SES, SendGrid). O e-mail padrão do Supabase tem limite
   baixo por hora; com os PJs criando acesso no mesmo dia, os links de confirmação param de chegar.

## 3. Vercel

Recomendado: ligar pelo painel, para cada push na `main` publicar sozinho e cada PR ganhar um preview.

👤 vercel.com → Add New → Project → importar o repositório `sistema-financeiro` → Framework: **Other**
(build e pasta de saída já vêm do `vercel.json`) → Environment Variables:
- `SUPABASE_URL` = `https://<PROJECT_REF>.supabase.co`
- `SUPABASE_ANON_KEY` = anon key do passo 2

Pelo terminal, o equivalente:
```bash
vercel link
vercel env add SUPABASE_URL production      # repetir para preview
vercel env add SUPABASE_ANON_KEY production
vercel --prod
```
O build falha de propósito se as variáveis faltarem ou se alguém colar a service_role key.

## 4. Primeiro acesso

1. Abrir o site → **Criar acesso** com o e-mail do responsável → confirmar pelo link.
2. Promover a admin (SQL Editor do Supabase ou psql):
   ```sql
   update perfis set papel = 'admin', nome = 'Nome' where lower(email) = lower('email@empresa.com.br');
   ```
3. A equipe cria acesso do mesmo jeito; o admin promove em **Usuários**.

## 5. Checklist antes de usar de verdade

- [ ] "Confirm email" ligado e SMTP próprio configurado
- [ ] Site URL e Redirect URLs com o domínio da Vercel
- [ ] Primeiro admin promovido
- [ ] Saldo inicial + data em cada conta corrente (Cadastros → Contas e cartões)
- [ ] Dia de fechamento de cada cartão conferido (veio estimado)
- [ ] E-mail de cada PJ no cadastro (sem isso ele não entra no portal)
- [ ] Um extrato real de cada banco importado e conferido
- [ ] Backups: dado financeiro merece o plano Pro do Supabase (backup diário) ou rotina própria de `pg_dump`

## Mudanças depois do primeiro deploy

- **Front:** commit na `main` → Vercel publica.
- **Banco:** nova migration em `supabase/migrations/`, `npm run test:db` passando, depois `supabase db push`
  (com o ok do usuário — é produção).

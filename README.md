# Agente News

Agente semanal em R para curadoria editorial de notícias reais, com coleta pública, validação de datas, deduplicação, ranking por IA, resumo analítico em português do Brasil, envio por Gmail e auditoria mínima da execução.

## Objetivo

O sistema funciona como um radar semanal de inteligência informacional, não como um agregador genérico de manchetes. Ele prioriza fatos com impacto público em saúde, ciência, epidemiologia, políticas públicas, gestão pública e em saúde, SUS, economia, política fiscal, infraestrutura, meio ambiente, mudanças climáticas, poluição atmosférica, tecnologia de impacto público, inteligência artificial, Rio de Janeiro, Campos dos Goytacazes e Norte Fluminense.

Conteúdos de fofoca, celebridades, realities, astrologia, promoção, esporte rotineiro e caça-cliques são penalizados, salvo impacto público extraordinário.

## Fontes

- J3News: API pública WordPress `https://j3news.com/wp-json/wp/v2/posts`, com paginação e parada temporal.
- Folha1: HTML público do site, lido por bytes e convertido conforme `charset=iso-8859-1`; datas vêm de metadados públicos da página.
- BBC News: feeds RSS oficiais `feeds.bbci.co.uk`, com `pubDate` validado.
- CNN Brasil: `https://admin.cnnbrasil.com.br/sitemap-news.xml`, permitido no robots do subdomínio, complementado por páginas públicas de últimas notícias com validação via `article:published_time`.

Cada fonte tem coletor independente. Falha em uma fonte é registrada e não impede as demais, exceto quando nenhuma fonte é coletada.

## Arquitetura

- `agent_news.R`: entrada principal.
- `R/config.R`: variáveis de ambiente, janela temporal e destinatários.
- `R/http.R`: HTTP, charset, HTML e datas.
- `R/collect_*.R`: coletores por fonte.
- `R/deduplicate.R`: normalização e deduplicação exata/fuzzy.
- `R/openai.R`, `R/rank.R`, `R/summarize.R`: Responses API, ranking e resumo.
- `R/render_email.R`: HTML compatível com Gmail.
- `R/send_email.R`: autenticação e envio Gmail.
- `R/audit.R`: CSV/JSON de auditoria.
- `tests/testthat/`: testes unitários.

## Ranking e resumo

O ranking usa a OpenAI Responses API com Structured Outputs. O modelo padrão de ranking é `gpt-5.4-mini`, configurável por `OPENAI_RANK_MODEL`. O resumo final usa `gpt-5.5`, configurável por `OPENAI_SUMMARY_MODEL`.

O ranking recebe `id`, fonte, data, título e trecho. Retorna `id`, `score`, `topic` e `justification`. O resumo é gerado somente para notícias selecionadas depois do ranking e da deduplicação.

## Deduplicação

Há duas etapas:

- deduplicação exata por URL e título normalizado dentro da fonte;
- deduplicação fuzzy entre fontes por similaridade textual de título e trecho, preservando a matéria com maior escore.

Coberturas substantivamente distintas podem permanecer quando a similaridade fica abaixo do limiar.

## E-mail

O e-mail é HTML, sem JavaScript e com CSS inline. O topo contém a seção `Ryan, leia estas 3`, com as três notícias mais relevantes da semana. Depois, as notícias aparecem agrupadas por:

1. J3News
2. Folha1
3. BBC News
4. CNN Brasil

Destinatários padrão:

- `ryandpaulosantos@gmail.com`
- `leticiamariadiasfreitas@gmail.com`

`EMAIL_TO` aceita endereços separados por vírgula ou ponto e vírgula. O envio é individual por destinatário e o status de cada envio é registrado.

## Configuração local no Windows

Use o R instalado em:

```powershell
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" --version
```

Instale dependências:

```powershell
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" -e "install.packages(c('dplyr','purrr','stringr','stringi','tibble','tidyr','lubridate','jsonlite','rvest','xml2','httr2','gmailr','glue','htmltools','openssl','yaml','testthat'), repos='https://cloud.r-project.org')"
```

Copie `.Renviron.example` para `.Renviron` e preencha apenas localmente. `.Renviron` não deve ser versionado.

## OpenAI

Configure:

```text
OPENAI_API_KEY=...
OPENAI_RANK_MODEL=gpt-5.4-mini
OPENAI_SUMMARY_MODEL=gpt-5.5
```

Sem `OPENAI_API_KEY`, o modo `DRY_RUN=true` usa ranking e resumo heurísticos apenas para validar coleta, HTML e auditoria. Fora de dry run, a chave é obrigatória.

## Gmail

1. Crie ou baixe o OAuth client do Google e salve como `oauth_client.json` na raiz local.
2. Defina uma chave forte em `GMAILR_KEY`.
3. Execute:

```powershell
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" setup_gmail_token.R
```

O script gera `secrets/gmailr-token.rds` para uso local e, quando `GMAILR_KEY` está definida, `secrets/gmailr-token.rds.enc` para execução não interativa. Nunca commite `oauth_client.json` nem o `.rds` descriptografado.

## GitHub Secrets

Cadastre no repositório:

- `OPENAI_API_KEY`
- `GMAILR_KEY`

Se a execução real for usada no GitHub Actions, inclua também o token criptografado `secrets/gmailr-token.rds.enc` no repositório, gerado com a mesma `GMAILR_KEY`. Não crie valores falsos.

## Execução local

Dry run, sem envio:

```powershell
$env:DRY_RUN="true"
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" agent_news.R
```

Envio real:

```powershell
$env:DRY_RUN="false"
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" agent_news.R
```

## Testes

```powershell
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" tests/testthat.R
```

Os testes cobrem normalização, deduplicação, datas, janela de sete dias, encoding, destinatários, top 3, falhas de fonte e renderização HTML. Eles não enviam e-mail.

## GitHub Actions

O workflow está em `.github/workflows/weekly-news.yml`.

- Agendamento: sábado às 08:00 em `America/Sao_Paulo`.
- `workflow_dispatch`: execução manual com opção `dry_run`.
- Valida sintaxe R, workflow YAML e testes antes do agente.
- Publica HTML, CSV e JSON em artifacts da execução.
- Não faz commit automático dos resultados semanais.

Falhas críticas derrubam o workflow: nenhuma fonte coletada, OpenAI indisponível fora de dry run, schema inválido sem recuperação, Gmail inválido em envio real ou nenhum destinatário com envio bem-sucedido.

## Artifacts e auditoria

A cada execução são gerados em `outputs/`:

- `weekly-news-*.html`
- `news-audit-*.csv`
- `news-audit-*.json`

A auditoria guarda metadados, escore, tema, seleção e motivo básico de descarte. O conteúdo integral dos artigos não é persistido.

## Limitações

- O agente usa apenas conteúdo público e não contorna paywalls, login ou bloqueios deliberados.
- Sites podem alterar estrutura, feeds, charset ou políticas de robots.
- Feeds e sitemaps podem não expor todo o histórico semanal quando o volume é alto; coletores registram quantidades e falhas.
- O resumo depende do conteúdo público disponível no momento da execução.

## Solução de problemas

- `Folha1` com acentos quebrados: confirme se a resposta declara `charset=iso-8859-1`; o coletor converte a partir do charset HTTP/HTML.
- `BBC News` sem itens: verifique status dos feeds `feeds.bbci.co.uk` e redirects.
- `CNN Brasil` sem itens antigos: reduza ou aumente `CNN_MAX_PUBLIC_PAGES`; o coletor para quando encontra páginas fora da janela.
- Gmail falha em Actions: confirme `GMAILR_KEY` e a presença de `secrets/gmailr-token.rds.enc`.
- Envio ausente em execução manual: confirme se `dry_run` está desmarcado.

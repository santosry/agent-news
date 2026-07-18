# Agente News

Agente semanal em R para curadoria editorial de notícias reais, com coleta pública, validação de datas, deduplicação, ranking por IA, resumo analítico em português do Brasil, envio por Gmail, auditoria da execução e benchmark operacional.

## Objetivo

O sistema funciona como um radar semanal de inteligência informacional, não como um agregador genérico de manchetes. Ele prioriza fatos com impacto público em saúde, ciência, epidemiologia, políticas públicas, gestão pública e em saúde, SUS, economia, política fiscal, infraestrutura, meio ambiente, mudanças climáticas, poluição atmosférica, tecnologia de impacto público, inteligência artificial, educação pública, pesquisa acadêmica, inovação, extensão universitária, Rio de Janeiro, Campos dos Goytacazes e Norte Fluminense.

Conteúdos de fofoca, celebridades, realities, astrologia, promoção, esporte rotineiro e caça-cliques são penalizados, salvo impacto público extraordinário.

## Fontes

- J3News: API pública WordPress `https://j3news.com/wp-json/wp/v2/posts`, com paginação e parada temporal.
- Folha1: HTML público do site, lido por bytes e convertido conforme `charset=iso-8859-1`; datas vêm de metadados públicos da página.
- IFF: HTML público paginado de `https://portal1.iff.edu.br/noticias`, com datas do bloco editorial `publicado`.
- UENF: RSS oficial da categoria Notícias `https://uenf.br/portal/categoria/noticias/feed/`, complementado por páginas públicas de notícias quando necessário.
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
- `R/send_email.R`: autenticação e envio por Gmail ou Outlook local.
- `R/audit.R`: CSV/JSON de auditoria e relatório de execução.
- `R/validate.R`: invariantes de produção antes do envio.
- `scripts/validate_no_secrets.R`: bloqueio de secrets rastreados ou padrões sensíveis.
- `scripts/benchmark_agent.R`: benchmark de coleta, ranking heurístico, deduplicação, resumo dry run e renderização.
- `tests/testthat/`: testes unitários.
- `renv.lock`: versões travadas das dependências R.

## Ranking e resumo

O ranking usa a OpenAI Responses API com Structured Outputs. O modelo padrão de ranking é `gpt-5.4-mini`, configurável por `OPENAI_RANK_MODEL`. O resumo final usa `gpt-5.5`, configurável por `OPENAI_SUMMARY_MODEL`.

O ranking recebe `id`, fonte, data, título e trecho. Retorna `id`, `score`, `topic` e `justification`. O resumo é gerado somente para notícias selecionadas depois do ranking e da deduplicação.

A seleção final evita concentração em um único veículo. Quando uma fonte tem notícia válida acima de `NEWS_SOURCE_MIN_SCORE`, o agente protege pelo menos `NEWS_MIN_NEWS_PER_SOURCE` item por fonte antes de preencher as demais posições com as maiores pontuações globais. O corte principal continua em `NEWS_MIN_SCORE`.

## Deduplicação

Há duas etapas:

- deduplicação exata por URL e título normalizado dentro da fonte;
- deduplicação fuzzy entre fontes por similaridade textual de título e trecho, preservando a matéria com maior escore.

Coberturas substantivamente distintas podem permanecer quando a similaridade fica abaixo do limiar.

## E-mail

O e-mail é HTML, sem JavaScript e com CSS inline. O período é apresentado em Horário de Brasília, implementado tecnicamente como `America/Sao_Paulo`. O topo contém a seção `Leia estas 3 primeiro`, com as três notícias mais relevantes da semana. Depois, as notícias aparecem agrupadas por:

1. J3News
2. Folha1
3. IFF
4. UENF
5. BBC News
6. CNN Brasil

Destinatários padrão:

- `ryandpaulosantos@gmail.com`
- `leticiamariadiasfreitas@gmail.com`

`EMAIL_TO` aceita endereços separados por vírgula ou ponto e vírgula. O envio é individual por destinatário e o status de cada envio é registrado.

O e-mail semanal não envia anexos. HTML, CSV, JSON, auditoria e benchmark ficam preservados como artifacts da execução no GitHub Actions ou como arquivos locais em `outputs/`.

## Configuração local no Windows

Use o R instalado em:

```powershell
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" --version
```

Restaure dependências travadas:

```powershell
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" -e "install.packages('renv', repos='https://cloud.r-project.org'); renv::restore(prompt=FALSE)"
```

Se precisar reconstruir o ambiente sem `renv`, instale dependências manualmente:

```powershell
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" -e "install.packages(c('dplyr','purrr','stringr','stringi','tibble','tidyr','lubridate','jsonlite','rvest','xml2','httr2','gmailr','glue','htmltools','openssl','yaml','testthat','withr'), repos='https://cloud.r-project.org')"
```

Copie `.Renviron.example` para `.Renviron` e preencha apenas localmente. `.Renviron` não deve ser versionado.

## OpenAI

Configure:

```text
OPENAI_API_KEY=...
OPENAI_RANK_MODEL=gpt-5.4-mini
OPENAI_SUMMARY_MODEL=gpt-5.5
```

Sem `OPENAI_API_KEY`, o modo `DRY_RUN=true` usa ranking e resumo determinísticos para validar coleta, HTML e auditoria. Para executar de verdade sem OpenAI, defina `ALLOW_NO_OPENAI=true`; nesse caso o agente busca o texto público das notícias selecionadas, gera resumo baseado no conteúdo disponível e escreve uma justificativa editorial sem expor detalhes técnicos no e-mail.

## Gmail

1. Crie ou baixe o OAuth client do Google e salve como `oauth_client.json` na raiz local.
2. Defina uma chave forte em `GMAILR_KEY`.
3. Execute:

```powershell
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" setup_gmail_token.R
```

O script gera `secrets/gmailr-token.rds` para uso local e, quando `GMAILR_KEY` está definida, `secrets/gmailr-token.rds.enc` e `secrets/gmailr-token.rds.enc.b64.txt`. Nunca commite `oauth_client.json`, tokens ou qualquer arquivo dentro de `secrets/`.

Para GitHub Actions, copie o conteúdo de `secrets/gmailr-token.rds.enc.b64.txt` para o secret `GMAILR_TOKEN_ENC_B64`.

## Envio Sem Gmail Key

No Windows, é possível enviar sem `GMAILR_KEY` usando o Outlook local já instalado e autenticado:

```powershell
$env:DRY_RUN="false"
$env:ALLOW_NO_OPENAI="true"
$env:EMAIL_TRANSPORT="outlook"
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" agent_news.R
```

Esse modo não usa OpenAI nem Gmail API. Ele depende de uma conta já configurada no Outlook do Windows. Se o Outlook não existir, não estiver autenticado, ou bloquear automação COM, o agente registra a falha por destinatário e não oculta o erro.

## GitHub Secrets

Cadastre no repositório:

- `OPENAI_API_KEY`: opcional quando `ALLOW_NO_OPENAI=true`; recomendado para ranking e resumo por IA.
- `GMAILR_KEY`: obrigatório para envio real pelo GitHub Actions.
- `GMAILR_TOKEN_ENC_B64`: obrigatório para envio real pelo GitHub Actions.

O workflow publicado define `ALLOW_NO_OPENAI=true` por padrão, então a execução agendada consegue coletar, selecionar, resumir de forma determinística e gerar artifacts sem chave da OpenAI. Para envio real pelo Gmail no GitHub Actions, o token Gmail criptografado continua obrigatório.

Não publique `oauth_client.json`, `.Renviron`, tokens ou arquivos em `secrets/`. Não crie valores falsos.

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

Envio real sem keys, via Outlook local:

```powershell
$env:DRY_RUN="false"
$env:ALLOW_NO_OPENAI="true"
$env:EMAIL_TRANSPORT="outlook"
Remove-Item Env:OPENAI_API_KEY -ErrorAction SilentlyContinue
Remove-Item Env:GMAILR_KEY -ErrorAction SilentlyContinue
Remove-Item Env:GMAILR_TOKEN_ENC_B64 -ErrorAction SilentlyContinue
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" agent_news.R
```

## Testes

```powershell
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" tests/testthat.R
```

Os testes cobrem normalização, deduplicação, datas, janela de sete dias, encoding, destinatários, top 3, falhas de fonte e renderização HTML. Eles não enviam e-mail.

Valide ausência de secrets rastreados:

```powershell
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" scripts/validate_no_secrets.R
```

## Benchmark

O benchmark mede coleta, deduplicação, ranking heurístico, seleção, resumo dry run e renderização sem enviar e-mail e sem chamar a OpenAI. Ele não salva conteúdo integral de artigos.

```powershell
$env:DRY_RUN="true"
& "C:\Program Files\R\R-4.6.0\bin\Rscript.exe" scripts/benchmark_agent.R
```

Artifacts gerados:

- `benchmark-*.csv`
- `benchmark-*.json`
- HTML dry run de referência

## GitHub Actions

O workflow está em `.github/workflows/weekly-news.yml`.

- Agendamento: sábado às 08:00 no Horário de Brasília (`America/Sao_Paulo`), implementado no GitHub Actions como `cron: '0 11 * * 6'` porque o agendamento do GitHub usa UTC.
- Agendamento adicional: quarta-feira às 17:00 no Horário de Brasília (`America/Sao_Paulo`), implementado como `cron: '0 20 * * 3'`.
- `workflow_dispatch`: execução manual com opção `dry_run`.
- Restaura dependências pelo `renv.lock`.
- Usa GitHub Actions fixadas por SHA de commit.
- Valida sintaxe R, workflow YAML, ausência de secrets, secrets de envio real, testes e benchmark antes do agente.
- Publica HTML, CSV, JSON, auditoria, relatório de execução e benchmark em artifacts da execução.
- Não faz commit automático dos resultados semanais.

Falhas críticas derrubam o workflow: nenhuma fonte coletada, OpenAI indisponível fora de dry run, schema inválido sem recuperação, Gmail inválido em envio real ou nenhum destinatário com envio bem-sucedido.

## Artifacts e auditoria

A cada execução são gerados em `outputs/`:

- `weekly-news-*.html`
- `news-audit-*.csv`
- `news-audit-*.json`
- `news-run-report-*.json`
- `benchmark-*.csv`
- `benchmark-*.json`

A auditoria guarda metadados, escore, tema, seleção e motivo básico de descarte. O conteúdo integral dos artigos não é persistido.

## Limitações

- O agente usa apenas conteúdo público e não contorna paywalls, login ou bloqueios deliberados.
- Sites podem alterar estrutura, feeds, charset ou políticas de robots.
- Feeds e sitemaps podem não expor todo o histórico semanal quando o volume é alto; coletores registram quantidades e falhas.
- O resumo depende do conteúdo público disponível no momento da execução.

## Solução de problemas

- `Folha1` com acentos quebrados: confirme se a resposta declara `charset=iso-8859-1`; o coletor converte a partir do charset HTTP/HTML.
- `IFF` sem itens: verifique se `https://portal1.iff.edu.br/noticias?b_start:int=0` segue acessível e se os blocos `tileItem` ainda contêm dia e hora.
- `UENF` sem itens: verifique o feed `https://uenf.br/portal/categoria/noticias/feed/` e as páginas `https://uenf.br/portal/noticias/`.
- `BBC News` sem itens: verifique status dos feeds `feeds.bbci.co.uk` e redirects.
- `CNN Brasil` sem itens antigos: reduza ou aumente `CNN_MAX_PUBLIC_PAGES`; o coletor para quando encontra páginas fora da janela.
- Gmail falha em Actions ou e-mail não chega no horário esperado: confirme que Actions está habilitado no repositório e que os secrets `GMAILR_KEY` e `GMAILR_TOKEN_ENC_B64` existem. Sem esses dois secrets, a execução agendada não consegue enviar e-mail real.
- Envio ausente em execução manual: confirme se `dry_run` está desmarcado.

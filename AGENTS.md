# AGENTS.md

Este projeto é prioritariamente R. Futuras sessões do Codex devem preservar a arquitetura modular em `R/` e manter os coletores independentes por fonte.

- Execute testes antes de publicar alterações.
- Nunca commite `.Renviron`, `oauth_client.json`, chaves OpenAI, tokens Gmail descriptografados ou qualquer outro secret.
- Falhas de fonte devem ser registradas de forma explícita e não podem ser apresentadas como ausência de notícia relevante.
- O agente não pode inventar conteúdo jornalístico, completar fatos ausentes nem atribuir notícia a veículo diferente da fonte original.
- Datas de publicação precisam ser validadas; notícia sem data confiável deve ser descartada ou registrada como data não validada.
- Alterações de comportamento exigem atualização do `README.md`.
- O workflow agendado deve permanecer aos sábados às 07:00 e às quartas-feiras às 07:00 no Horário de Brasília (`America/Sao_Paulo`), implementado como `cron: '0 10 * * 6'` e `cron: '0 10 * * 3'` porque GitHub Actions agenda em UTC, salvo instrução expressa do proprietário.
- Os destinatários são definidos via `EMAIL_TO` no `.Renviron` (nunca versionado). Consulte `.Renviron.example` para o formato.
- Não publique outputs, tokens, `.Renviron`, `oauth_client.json` ou qualquer arquivo real em `secrets/`.
- Rode `scripts/validate_no_secrets.R`, testes e, quando alterar coleta/performance, `scripts/benchmark_agent.R`.
- O modo sem keys usa `ALLOW_NO_DEEPSEEK=true` (legado: `ALLOW_NO_OPENAI=true`) e, para envio local, `EMAIL_TRANSPORT=outlook`; não trate isso como equivalente ao envio via GitHub Actions.
- O e-mail semanal deve ir sem anexos; auditoria, HTML e benchmark ficam em `outputs/` e nos artifacts do GitHub Actions.
- IFF e UENF são fontes acadêmicas/institucionais prioritárias; mantenha coletores independentes e preserve a ordem local-regional antes de BBC/CNN.
- Cada coletor deve ter fallback: se o método primário falhar (RSS/API), tentar HTML scraping. Se tudo falhar, registrar falha explícita sem quebrar o pipeline.
- Máximo de 10 notícias por fonte (config: `NEWS_PER_SOURCE`).

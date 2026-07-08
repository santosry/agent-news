# AGENTS.md

Este projeto é prioritariamente R. Futuras sessões do Codex devem preservar a arquitetura modular em `R/` e manter os coletores independentes por fonte.

- Execute testes antes de publicar alterações.
- Nunca commite `.Renviron`, `oauth_client.json`, chaves OpenAI, tokens Gmail descriptografados ou qualquer outro secret.
- Falhas de fonte devem ser registradas de forma explícita e não podem ser apresentadas como ausência de notícia relevante.
- O agente não pode inventar conteúdo jornalístico, completar fatos ausentes nem atribuir notícia a veículo diferente da fonte original.
- Datas de publicação precisam ser validadas; notícia sem data confiável deve ser descartada ou registrada como data não validada.
- Alterações de comportamento exigem atualização do `README.md`.
- O workflow semanal deve permanecer aos sábados às 08:00 no Horário de Brasília (`America/Sao_Paulo`), salvo instrução expressa do proprietário.
- Os destinatários padrão são Ryan (`ryandpaulosantos@gmail.com`) e Letícia (`leticiamariadiasfreitas@gmail.com`).
- Não publique outputs, tokens, `.Renviron`, `oauth_client.json` ou qualquer arquivo real em `secrets/`.
- Rode `scripts/validate_no_secrets.R`, testes e, quando alterar coleta/performance, `scripts/benchmark_agent.R`.
- O modo sem keys usa `ALLOW_NO_OPENAI=true` e, para envio local, `EMAIL_TRANSPORT=outlook`; não trate isso como equivalente ao envio via GitHub Actions.
- O e-mail semanal deve ir sem anexos; auditoria, HTML e benchmark ficam em `outputs/` e nos artifacts do GitHub Actions.
- IFF e UENF são fontes acadêmicas/institucionais prioritárias; mantenha coletores independentes e preserve a ordem local-regional antes de BBC/CNN.

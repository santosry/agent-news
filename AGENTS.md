# AGENTS.md

Este projeto é prioritariamente R. Futuras sessões do Codex devem preservar a arquitetura modular em `R/` e manter os coletores independentes por fonte.

- Execute testes antes de publicar alterações.
- Nunca commite `.Renviron`, `oauth_client.json`, chaves OpenAI, tokens Gmail descriptografados ou qualquer outro secret.
- Falhas de fonte devem ser registradas de forma explícita e não podem ser apresentadas como ausência de notícia relevante.
- O agente não pode inventar conteúdo jornalístico, completar fatos ausentes nem atribuir notícia a veículo diferente da fonte original.
- Datas de publicação precisam ser validadas; notícia sem data confiável deve ser descartada ou registrada como data não validada.
- Alterações de comportamento exigem atualização do `README.md`.
- O workflow semanal deve permanecer aos sábados às 08:00 em `America/Sao_Paulo`, salvo instrução expressa do proprietário.
- Os destinatários padrão são Ryan (`ryandpaulosantos@gmail.com`) e Letícia (`leticiamariadiasfreitas@gmail.com`).

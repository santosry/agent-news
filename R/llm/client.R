# Cliente LLM (planner) --------------------------------------------------------
#
# Camada fina sobre o cliente DeepSeek já existente (R/openai.R). Reusa
# `deepseek_chat_completions` e apenas adiciona recuperação controlada: em caso
# de falha, devolve NULL para que o planner caia no plano determinístico.

llm_complete <- function(config, system_prompt, user_prompt, schema, max_tries = 3) {
  tryCatch(
    deepseek_chat_completions(
      config = config,
      model = config$planner_model,
      system_prompt = system_prompt,
      user_prompt = user_prompt,
      schema_name = "agent_decision",
      schema = schema,
      max_tries = max_tries
    ),
    error = function(e) NULL
  )
}

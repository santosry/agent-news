#!/usr/bin/env Rscript

# Suíte de avaliação comportamental do agente.
#
# Executa cenários controlados e determinísticos (sem internet e sem DeepSeek)
# para verificar se o agente realmente se adapta, replaneja, abandona
# estratégias e sabe parar — não apenas se executa ferramentas em sequência.
#
# Uso:
#   Rscript tests/agent_eval.R

library(testthat)

for (file in sort(list.files("R", pattern = "[.]R$", full.names = TRUE, recursive = TRUE))) {
  source(file, local = FALSE)
}

test_dir("tests/agent_eval", reporter = "summary")

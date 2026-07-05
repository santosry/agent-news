library(testthat)

for (file in sort(list.files("R", pattern = "[.]R$", full.names = TRUE))) {
  source(file, local = FALSE)
}

test_dir("tests/testthat")

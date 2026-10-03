# microdatasus (R) — uma medição: Rscript benchmark/bench_r.R ARQUIVO TAREFA [REPETICOES]
# Lê como o fetch_datasus do microdatasus 3: o leitor interno read_dbc
# (descompacta, foreign::read.dbf com as.is = TRUE, tudo como texto, tibble).
suppressPackageStartupMessages(library(microdatasus))
le <- function(arq) microdatasus:::read_dbc(arq, as_character = TRUE)

rss <- function(campo) {
  l <- grep(paste0("^", campo, ":"), readLines("/proc/self/status"), value = TRUE)
  as.numeric(gsub("[^0-9]", "", l)) / 1024
}
# o mesmo recorte de eh_agressao: X85–Y09 e Y87.1
cvli <- function(cid) grepl("^(X8[5-9]|X9|Y0[0-9]|Y871)", cid)

tarefa <- function(arq, t) {
  if (t == "tudo") return(le(arq))
  if (t == "cvli") {
    d <- le(arq)
    return(d[cvli(as.character(d$CAUSABAS)), c("DTOBITO", "CAUSABAS", "CODMUNRES")])
  }
  if (t == "padronizar") return(suppressMessages(suppressWarnings(process_sim(le(arq)))))
  stop("tarefa desconhecida: ", t)
}

a <- commandArgs(trailingOnly = TRUE)
arq <- a[1]; t <- a[2]; reps <- if (length(a) >= 3) as.integer(a[3]) else 3L
invisible(gc()); base <- rss("VmRSS")
t0 <- proc.time()[["elapsed"]]; df <- tarefa(arq, t); frio <- proc.time()[["elapsed"]] - t0
pico <- rss("VmHWM")
dims <- dim(df); rm(df)
quentes <- numeric(0)
for (i in seq_len(reps)) {
  invisible(gc())
  t0 <- proc.time()[["elapsed"]]; invisible(tarefa(arq, t)); quentes <- c(quentes, proc.time()[["elapsed"]] - t0)
}
cat(sprintf('{"ferramenta":"microdatasus %s (R %s)","arquivo":"%s","tarefa":"%s","linhas":%d,"colunas":%d,"t_frio":%.3f,"t_quente":%.3f,"rss_base_mb":%.1f,"rss_pico_mb":%.1f}\n',
            packageVersion("microdatasus"), getRversion(), basename(arq), t,
            dims[1], dims[2], frio, median(quentes), base, pico))

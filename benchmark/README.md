# MicroSUS.jl, microdatasus e PySUS lendo os mesmos arquivos

Tempo, memória e igualdade dos valores das três ferramentas, lendo os
mesmos `.dbc` do DATASUS (os do cache do MicroSUS: mesmos bytes para as
três).

## Resumo

- **Os valores são idênticos.** Em 2,55 milhões de registros de quatro
  arquivos (SIM, SINASC, SINAN), as três leem as mesmas datas, códigos,
  idades e textos, célula a célula (`confere.py`, outubro de 2026, com a
  0.4.1). As otimizações seguintes foram conferidas célula a célula contra
  a 0.5.0 nos mesmos quatro arquivos, inclusive a ordem do pool das colunas
  categóricas.
- **Ler um arquivo inteiro**: em SIM e SINASC, o MicroSUS é 2,0–2,4× mais
  rápido que o microdatasus com uma thread (0,92 s contra 1,92 s no
  DOSP2023) e 3,8–5,2× com 16. No SINAN nacional (1,65 milhão de registros
  × 121 colunas), 13× mais rápido com uma thread e 36× com 16. A pilha de
  leitura do PySUS é cerca de 11× mais lenta que o microdatasus e 22–26× que
  o MicroSUS com uma thread, e não coube em 9 GB no arquivo do SINAN.
- **Memória ao ler tudo**: aqui o microdatasus ganha em SIM e SINASC — o
  MicroSUS usa 1,7–3,1× mais (904 MB contra 292 MB no DOSP2023). O R guarda
  cada texto repetido uma vez só e devolve tudo como texto; o MicroSUS
  tipa as colunas (datas, idade em anos, categóricas) e guarda cada texto
  livre na própria célula. No SINAN, o MicroSUS usa 42% menos.
- **Filtrar na leitura** é onde o streaming aparece: os óbitos por
  agressão de SP em 2023 saem em 0,29 s com 53 MB, contra 2,0 s e 292 MB
  — o microdatasus lê o arquivo inteiro antes de filtrar.
- **Padronizar** (`process_sim`): 10× mais rápido que o do microdatasus
  (1,3 s contra 13,3 s no DOSP2023), com 20% mais memória.
- **A primeira execução**: `ler` vem precompilado, e a primeira leitura
  paga só 0,4–0,7 s a mais que as seguintes — no DOPE2023 (0,61 s), empata
  com o R (0,59 s). A primeira chamada de `process_sim` ainda compila:
  3,6–3,8 s a mais.

## Máquina e versões

AMD Ryzen 7 5700G (8 núcleos, 16 threads), 14 GB de RAM, Linux 7.2.

- MicroSUS.jl `73ca76a` (0.5.0 + as otimizações de leitura do
  [Unreleased](../CHANGELOG.md)) no Julia 1.13.0. Novembro de 2026.
- microdatasus 3.0.0 no R 4.5.3; pyreaddbc 2.0.4 + dbfread 2.0.7 + pandas
  3.0.6 no Python 3.14.7. Outubro de 2026, na mesma máquina e com os
  mesmos arquivos (as linhas de R e Python não foram remedidas; nada nelas
  mudou).

## O que cada ferramenta faz

- **MicroSUS.jl**: `DataFrame(ler(arquivo))` — descompacta e lê em
  streaming, já tipado pelo schema do sistema (datas como `Date`, `IDADE`
  em anos, categóricas como `PooledArray`, texto como `InlineString`). No
  filtro, `ler(arquivo; colunas, filtro)`: só as colunas pedidas são
  convertidas, e a condição roda antes. Medido com 1 e com 16 threads.
- **microdatasus**: o leitor interno que o `fetch_datasus` dele usa
  (`microdatasus:::read_dbc`: descompacta, `foreign::read.dbf` e tudo como
  texto), e o `process_sim` dele.
- **Pilha do PySUS**: `pyreaddbc.dbc2dbf` + `dbfread` + `pandas`, a
  mesma do PySUS. O PySUS não tem padronização equivalente.

Cada medição é um processo novo: a 1ª execução (com compilação, no Julia),
depois a mediana de 3 (1 no SINAN). **Memória** é o pico do processo
(`VmHWM`) menos a memória dele antes da leitura, já com os pacotes
carregados — o custo da leitura, não o do runtime (Julia parte de ~370 MB,
R e Python de ~75 MB). Arquivos já descompactados no cache do sistema
operacional; sem rede.

### Ler o arquivo inteiro

| arquivo | ferramenta | 1ª execução (s) | seguintes (s) | memória (MB) |
|---|---|--:|--:|--:|
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (1 thread) | 0,61 | 0,19 | 188 |
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (16 threads) | 0,51 | 0,10 | 250 |
| DOPE2023 (SIM, 68 mil × 87) | microdatasus (R) | 0,59 | 0,38 | 96 |
| DOPE2023 (SIM, 68 mil × 87) | pilha do PySUS (Python) | 4,25 | 4,18 | 896 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (1 thread) | 1,59 | 0,92 | 904 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (16 threads) | 0,93 | 0,41 | 1272 |
| DOSP2023 (SIM, 334 mil × 87) | microdatasus (R) | 2,77 | 1,92 | 292 |
| DOSP2023 (SIM, 334 mil × 87) | pilha do PySUS (Python) | 21,70 | 21,14 | 4372 |
| DNSP2023 (SINASC, 504 mil × 61) | MicroSUS (1 thread) | 1,33 | 0,85 | 532 |
| DNSP2023 (SINASC, 504 mil × 61) | MicroSUS (16 threads) | 0,83 | 0,40 | 779 |
| DNSP2023 (SINASC, 504 mil × 61) | microdatasus (R) | 2,99 | 2,06 | 322 |
| DNSP2023 (SINASC, 504 mil × 61) | pilha do PySUS (Python) | 22,50 | 22,45 | 4036 |
| DENGBR23 (SINAN, 1,65 milhão × 121) | MicroSUS (1 thread) | 3,82 | 3,12 | 1549 |
| DENGBR23 (SINAN, 1,65 milhão × 121) | MicroSUS (16 threads) | 1,73 | 1,10 | 1781 |
| DENGBR23 (SINAN, 1,65 milhão × 121) | microdatasus (R) | 42,39 | 39,89 | 2683 |
| DENGBR23 (SINAN, 1,65 milhão × 121) | pilha do PySUS (Python) | — | — | não coube em 9 GB |

### Óbitos por agressão: 3 colunas, filtrados

| arquivo | ferramenta | 1ª execução (s) | seguintes (s) | memória (MB) |
|---|---|--:|--:|--:|
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (1 thread) | 0,44 | 0,07 | 40 |
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (16 threads) | 0,41 | 0,06 | 59 |
| DOPE2023 (SIM, 68 mil × 87) | microdatasus (R) | 0,61 | 0,38 | 95 |
| DOPE2023 (SIM, 68 mil × 87) | pilha do PySUS (Python) | 4,32 | 4,11 | 895 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (1 thread) | 0,68 | 0,29 | 53 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (16 threads) | 0,65 | 0,27 | 75 |
| DOSP2023 (SIM, 334 mil × 87) | microdatasus (R) | 3,02 | 2,02 | 292 |
| DOSP2023 (SIM, 334 mil × 87) | pilha do PySUS (Python) | 22,01 | 21,12 | 4372 |

### Ler e padronizar (`process_sim`)

| arquivo | ferramenta | 1ª execução (s) | seguintes (s) | memória (MB) |
|---|---|--:|--:|--:|
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (1 thread) | 3,88 | 0,26 | 440 |
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (16 threads) | 3,68 | 0,20 | 467 |
| DOPE2023 (SIM, 68 mil × 87) | microdatasus (R) | 3,48 | 2,94 | 275 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (1 thread) | 5,13 | 1,31 | 1471 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (16 threads) | 4,38 | 0,82 | 1714 |
| DOSP2023 (SIM, 334 mil × 87) | microdatasus (R) | 15,97 | 13,28 | 1230 |

## Reproduzir

```bash
# os .dbc no cache do MicroSUS (fetch_datasus/baixar os põe lá)
export DBC=~/.julia/scratchspaces/cf66faa3-c0ab-41b5-b901-e1d7c735fa13/dbc
RSCRIPT=Rscript PYTHON=python3 benchmark/roda.sh   # → benchmark/resultados.jsonl
FERRAMENTAS="julia1 juliaN" benchmark/roda.sh      # só o MicroSUS
python3 benchmark/tabela.py                       # as tabelas acima
python3 benchmark/confere.py                      # a igualdade dos valores
```

R: `remotes::install_github("rfsaldanha/microdatasus")`. Python:
`pip install pyreaddbc dbfread pandas`.

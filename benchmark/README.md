# MicroSUS.jl, microdatasus e PySUS lendo os mesmos arquivos

Tempo, memória e igualdade dos valores das três ferramentas, lendo os
mesmos `.dbc` do DATASUS (os do cache do MicroSUS: mesmos bytes para as
três).

## Resumo

- **Os valores são idênticos.** Em 2,55 milhões de registros de quatro
  arquivos (SIM, SINASC, SINAN), as três leem as mesmas datas, códigos,
  idades e textos, célula a célula (`confere.py`).
- **Ler um arquivo inteiro**: em SIM e SINASC, o MicroSUS com uma thread
  empata com o microdatasus (0,38 s contra 0,38 s; 2,0 s contra 1,9 s) e,
  com 16 threads, é 1,4–1,7× mais rápido. No SINAN nacional (1,65 milhão de
  registros × 121 colunas) é 6× mais rápido com uma thread e 13× com 16.
  A pilha de leitura do PySUS é cerca de 10× mais lenta que as outras duas e não
  coube em 9 GB no arquivo do SINAN.
- **Memória ao ler tudo**: aqui o microdatasus ganha em SIM e SINASC — o
  MicroSUS usa 2–3× mais (947 MB contra 292 MB no DOSP2023). O R guarda
  cada texto repetido uma vez só e devolve tudo como texto; o MicroSUS
  tipa as colunas (datas, idade em anos, categóricas) e guarda cada texto
  livre na própria célula. No SINAN, o MicroSUS usa 44% menos.
- **Filtrar na leitura** é onde o streaming aparece: os óbitos por
  agressão de SP em 2023 saem em 1,1 s com 112 MB, contra 2,0 s e 292 MB
  — o microdatasus lê o arquivo inteiro antes de filtrar.
- **Padronizar** (`process_sim`): 5,4× mais rápido que o do microdatasus
  (2,5 s contra 13,3 s no DOSP2023), com 22% mais memória.
- **A primeira execução** do Julia inclui compilar: 2–6 s a mais. Num
  arquivo pequeno, lido uma vez, o R termina antes.

## Máquina e versões

AMD Ryzen 7 5700G (8 núcleos, 16 threads), 14 GB de RAM, Linux 7.2.
MicroSUS.jl `c771a1c` (0.4.1) no Julia 1.13.0; microdatasus 3.0.0 no R
4.5.3; pyreaddbc 2.0.4 + dbfread 2.0.7 + pandas 3.0.6 no Python 3.14.7.
Outubro de 2026.

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
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (1 thread) | 3,50 | 0,38 | 216 |
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (16 threads) | 2,73 | 0,28 | 284 |
| DOPE2023 (SIM, 68 mil × 87) | microdatasus (R) | 0,59 | 0,38 | 96 |
| DOPE2023 (SIM, 68 mil × 87) | pilha do PySUS (Python) | 4,25 | 4,18 | 896 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (1 thread) | 5,63 | 2,04 | 947 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (16 threads) | 3,56 | 1,21 | 1363 |
| DOSP2023 (SIM, 334 mil × 87) | microdatasus (R) | 2,77 | 1,92 | 292 |
| DOSP2023 (SIM, 334 mil × 87) | pilha do PySUS (Python) | 21,70 | 21,14 | 4372 |
| DNSP2023 (SINASC, 504 mil × 61) | MicroSUS (1 thread) | 4,41 | 1,61 | 617 |
| DNSP2023 (SINASC, 504 mil × 61) | MicroSUS (16 threads) | 3,10 | 1,18 | 856 |
| DNSP2023 (SINASC, 504 mil × 61) | microdatasus (R) | 2,99 | 2,06 | 322 |
| DNSP2023 (SINASC, 504 mil × 61) | pilha do PySUS (Python) | 22,50 | 22,45 | 4036 |
| DENGBR23 (SINAN, 1,65 milhão × 121) | MicroSUS (1 thread) | 9,84 | 6,82 | 1501 |
| DENGBR23 (SINAN, 1,65 milhão × 121) | MicroSUS (16 threads) | 5,27 | 3,04 | 1624 |
| DENGBR23 (SINAN, 1,65 milhão × 121) | microdatasus (R) | 42,39 | 39,89 | 2683 |
| DENGBR23 (SINAN, 1,65 milhão × 121) | pilha do PySUS (Python) | — | — | não coube em 9 GB |

### Óbitos por agressão: 3 colunas, filtrados

| arquivo | ferramenta | 1ª execução (s) | seguintes (s) | memória (MB) |
|---|---|--:|--:|--:|
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (1 thread) | 2,14 | 0,23 | 106 |
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (16 threads) | 1,86 | 0,20 | 118 |
| DOPE2023 (SIM, 68 mil × 87) | microdatasus (R) | 0,61 | 0,38 | 95 |
| DOPE2023 (SIM, 68 mil × 87) | pilha do PySUS (Python) | 4,32 | 4,11 | 895 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (1 thread) | 3,02 | 1,15 | 112 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (16 threads) | 2,79 | 1,01 | 119 |
| DOSP2023 (SIM, 334 mil × 87) | microdatasus (R) | 3,02 | 2,02 | 292 |
| DOSP2023 (SIM, 334 mil × 87) | pilha do PySUS (Python) | 22,01 | 21,12 | 4372 |

### Ler e padronizar (`process_sim`)

| arquivo | ferramenta | 1ª execução (s) | seguintes (s) | memória (MB) |
|---|---|--:|--:|--:|
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (1 thread) | 6,54 | 0,41 | 442 |
| DOPE2023 (SIM, 68 mil × 87) | MicroSUS (16 threads) | 5,88 | 0,38 | 560 |
| DOPE2023 (SIM, 68 mil × 87) | microdatasus (R) | 3,48 | 2,94 | 275 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (1 thread) | 8,68 | 2,47 | 1498 |
| DOSP2023 (SIM, 334 mil × 87) | MicroSUS (16 threads) | 7,24 | 1,60 | 1788 |
| DOSP2023 (SIM, 334 mil × 87) | microdatasus (R) | 15,97 | 13,28 | 1230 |

## Reproduzir

```bash
# os .dbc no cache do MicroSUS (fetch_datasus/baixar os põe lá)
export DBC=~/.julia/scratchspaces/cf66faa3-c0ab-41b5-b901-e1d7c735fa13/dbc
RSCRIPT=Rscript PYTHON=python3 benchmark/roda.sh   # → benchmark/resultados.jsonl
python3 benchmark/tabela.py                       # as tabelas acima
python3 benchmark/confere.py                      # a igualdade dos valores
```

R: `remotes::install_github("rfsaldanha/microdatasus")`. Python:
`pip install pyreaddbc dbfread pandas`.

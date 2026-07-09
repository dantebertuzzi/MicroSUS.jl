# MicroSUS.jl

<div align="center">
  <img src="[https://raw.githubusercontent.com/dantebertuzzi/MissingPatterns.jl/main/logo.png](https://raw.githubusercontent.com/dantebertuzzi/MicroSUS.jl/refs/heads/main/logo_microsus.png)" alt="Logo.jl" width="200">
</div>

Microdados do DATASUS em Julia — leitura **streaming** de `.dbc`/`.dbf`
com memória constante, schemas tipados por sistema (SIM, SINASC, SIH,
SIA, CNES), transcodificação CP850 → UTF-8, download com cache e
interface Tables.jl com partições.

## Por que streaming

O `.dbc` do DATASUS é um DBF com os registros comprimidos em PKWare DCL
("implode"). Descomprimido, o arquivo expande 4–8×; materializado como
`Vector{String}` coluna a coluna, mais algumas vezes isso. O leitor
daqui nunca faz nada disso: o descompressor é um porte puro Julia do
`blast.c` de Mark Adler em versão streaming — a janela de 4 KiB é
emitida em chunks — e o pipeline inteiro (descompressão → montagem de
registros → filtro → parse → lote) é encadeado por `Channel`s. A
memória é **O(tamanho_lote)**, nunca O(arquivo): um SINASC nacional
multi-ano passa pelo leitor sem precisar caber na RAM.

```
.dbc ──DCL 4KiB/chunk──▶ registros ──filtro──▶ parse tipado ──▶ lotes
                          (brutos)   (sob      (só colunas      (NamedTuple,
                                     demanda)   pedidas)         Tables.jl)
```

## Instalação

```julia
] dev caminho/para/MicroSUS.jl
] test MicroSUS          # suíte completa, sem depender de rede
```

Documentação completa (Documenter.jl):

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl     # saída em docs/build/index.html
```

Julia ≥ 1.9 (extensões condicionais). Dependências: Tables,
InlineStrings, PooledArrays, Scratch, Downloads, Dates. Arrow é
opcional (weak dep).

## Início rápido

```julia
using MicroSUS, DataFrames

# download com cache local (Scratch.jl) — não rebaixa o que já tem
caminho = baixar(:sim, "PE"; ano = 2023)

# tudo tipado: datas → Date, IDADE do SIM → anos, categóricas →
# PooledArray, texto → InlineStrings, CP850 → UTF-8
df = DataFrame(ler(caminho))

# seleção de colunas + filtro de linhas NO LEITOR: campos não pedidos
# nem viram String; o filtro parseia só o campo consultado
t = ler(caminho;
        colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO],
        filtro  = r -> eh_agressao(r[:CAUSABAS]))   # CVLI: X85–Y09 + Y87.1
cvli = DataFrame(t)

# processamento em lotes, memória constante
using Tables
for lote in Tables.partitions(ler(caminho; tamanho_lote = 50_000))
    # `lote` é um NamedTuple de vetores — tabela Tables.jl válida
end

# .dbc → Arrow em streaming (um record batch por lote)
using Arrow
converter(caminho, "do_pe_2023.arrow";
          colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES])
```

## `ler` — referência

```julia
ler(caminho; colunas = nothing, filtro = nothing, tamanho_lote = 100_000,
    schema = :auto, encoding = :auto, pool = true) -> TabelaDBC
```

| kwarg | default | efeito |
|---|---|---|
| `colunas` | `nothing` (todas) | `Vector{Symbol}`; as demais nem são materializadas |
| `filtro` | `nothing` | `RegistroDBF -> Bool`, roda **antes** do parse; `r[:CAMPO]` decodifica só o campo consultado |
| `tamanho_lote` | `100_000` | linhas por partição — é o teto de memória do pipeline |
| `schema` | `:auto` | deduz pelo prefixo do arquivo; ou `:sim`/`:sinasc`/`:sih`/`:sia`/`:cnes`, um `Dict{Symbol,Symbol}` próprio, ou `nothing` (só a tipagem do DBF) |
| `encoding` | `:auto` | language driver do cabeçalho (DATASUS ⇒ `:cp850`); ou `:cp850`, `:latin1`, `:cp1252`, `:utf8` |
| `pool` | `true` | `PooledArray` nas categóricas do schema (análogo ao factor do R) |

`TabelaDBC` é preguiçosa: nada é lido até a iteração. Ela implementa
`Tables.partitions` (lotes) e `Tables.columns` (materialização via
[`materializar`](#utilidades)), então funciona direto em
`DataFrame(t)`, `Arrow.write(saida, t)`, etc.

## Schemas

`schema = :auto` deduz o sistema pelo prefixo do nome do arquivo:

| prefixo | sistema | exemplo |
|---|---|---|
| `DO` | `:sim` | `DOPE2023.dbc` |
| `DN` | `:sinasc` | `DNBA2022.dbc` |
| `RD`, `SP` | `:sih` | `RDPE2301.dbc` |
| `PA` | `:sia` | `PAPE2301.dbc` |
| `ST`, `LT`, `PF` | `:cnes` | `STPE2301.dbc` |

Tipos lógicos disponíveis (para schemas próprios via `Dict`):
`:texto`, `:pool`, `:inteiro`, `:float`, `:data_ddmmyyyy` (SIM/SINASC),
`:data_yyyymmdd` (SIH e tipo `D` do DBF), `:idade_sim`.

A `IDADE` do SIM (1º dígito = unidade, 2º–3º = valor) vira **anos**:

```julia
decodifica_idade_sim("425")   # 25.0
decodifica_idade_sim("501")   # 101.0  (5 ⇒ 100 + valor)
decodifica_idade_sim("310")   # 0.833… (10 meses)
decodifica_idade_sim("999")   # missing
```

Unidades: 0 = minutos, 1 = horas, 2 = dias, 3 = meses, 4 = anos,
5 = 100 + valor, 9 = ignorada.

## Download e FTP

```julia
baixar(:sim, "PE"; ano = 2023)                     # um arquivo, com cache
baixar(:sim, "PE"; anos = 2013:2023)               # vários, em paralelo
baixar(:sih, "PE"; anos = [2023], meses = 1:12)    # mensais
url_arquivo(:sinasc, "BA"; ano = 2022)             # só a URL
MicroSUS.limpar_cache()                            # zera o cache local
```

Caminhos atuais do FTP (conferidos contra o `microdatasus`, jul/2026):

| sistema | pasta | arquivo |
|---|---|---|
| `:sim` | `SIM/CID10/DORES/` | `DO{UF}{aaaa}.dbc` |
| `:sinasc` | `SINASC/1996_/Dados/DNRES/` | `DN{UF}{aaaa}.dbc` |
| `:sih` | `SIHSUS/200801_/Dados/` | `RD{UF}{aamm}.dbc` |
| `:sia` | `SIASUS/200801_/Dados/` | `PA{UF}{aamm}.dbc` |
| `:cnes` | `CNES/200508_/Dados/ST/` | `ST{UF}{aamm}.dbc` |
| SINAN | `SINAN/DADOS/FINAIS/` | `{AGRAVO}BR{aa}.dbc` (nacional — use `baixar_sinan`) |

**Dados preliminares**: se o consolidado não existir (anos recentes do
SIM/SINASC), `baixar` tenta automaticamente a pasta `PRELIM/`
correspondente, com um `@warn` — indicador calculado sobre preliminar
merece asterisco. `url_arquivo(...; prelim = true)` monta a URL
preliminar diretamente.

**Limites de cobertura**: SINASC via helper cobre 1996+ (1994–1995
vivem em `SINASC/1994_1995/` com outro padrão de nome — monte a URL
manualmente); SIH/SIA cobrem a estrutura pós-2008.

## Dimensões auxiliares

```julia
dv_ibge(261110)               # 1 — dígito verificador (Petrolina)
codigo7_ibge(261110)          # 2611101 (SIM/SINASC usam 6 dígitos; IBGE, 7)
codigo6_ibge(2611101)         # 261110, validando o DV
capitulo_cid10("X954")        # (numeral = "XX", nome = "Causas externas …")
eh_agressao("X954")           # true — X85–Y09 + Y87.1 (recorte CVLI)
```

## Utilidades

```julia
materializar(t)                                  # todas as partições → NamedTuple
MicroSUS.cabecalho("DOPE2023.dbc")               # só o cabeçalho (campos, larguras, n)
descomprime_dbc_para_dbf("a.dbc", "a.dbf")       # dbc → dbf em streaming
dcl_descomprime(io, chunk -> ...)                # descompressor com sink genérico
dcl_descomprime(io)                              # ... ou materializado (testes)
```

## Notas de projeto

- **Encoding**: o language driver do cabeçalho DBF decide; `0x00`
  (não especificado) cai em CP850, que é a prática do DATASUS. Há fast
  path ASCII — a transcodificação só paga quando existe byte ≥ 0x80.
- **Texto**: colunas `C` viram `InlineStrings` dimensionadas pela
  largura do campo (sem ponteiro, sem pressão de GC); categóricas do
  schema viram `PooledArray`. `pool = false` desliga.
- **Registros deletados** (flag `0x2A`) são pulados; o marcador de EOF
  do dBase (`0x1A`) é ignorado.
- **Arrow**: `converter` é uma extensão condicional (Julia ≥ 1.9);
  sem `using Arrow`, chamar dá `MethodError` com hint explicando.
- **Testes sem rede**: o `runtests.jl` inclui um *compressor* DCL
  mínimo (literais, matches e código de fim, com os códigos canônicos
  emitidos na ordem invertida do formato), o que permite round-trip
  real do descompressor e DBC ≡ DBF sintéticos, incluindo CP850 e
  travessia de janelas de 4 KiB.

## Limitações conhecidas

- Sem paralelismo intra-arquivo (o DCL é sequencial por natureza);
  paralelize por arquivo (`baixar(...; anos = ...)` + tasks).
- Schemas cobrem os campos mais usados de cada sistema; campos fora do
  schema caem na tipagem do DBF (`N` → inteiro/float, `D` → data,
  `C` → texto). PRs de schema são bem-vindos.
- Tabelas de dimensão com *nomes* (municípios, CID-10 4 dígitos, CBO)
  ficam fora do pacote — junte com a DTB do IBGE.

## Licença

MIT

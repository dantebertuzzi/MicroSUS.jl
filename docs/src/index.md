```@meta
CurrentModule = MicroSUS
```

# MicroSUS.jl

Microdados do DATASUS em Julia — leitura **streaming** de arquivos
`.dbc` (PKWare DCL) e `.dbf` com memória constante, schemas tipados por
sistema (SIM, SINASC, SIH, SIA, CNES, SINAN), transcodificação
CP850/Latin-1 → UTF-8, download com cache local (Scratch.jl) e
interface [Tables.jl](https://github.com/JuliaData/Tables.jl) com
partições.

## Installation

```julia
using Pkg
Pkg.add("MicroSUS")
```

Julia ≥ 1.9. Dependencies: Tables, InlineStrings, PooledArrays, Scratch,
Downloads, Dates. Arrow is optional (conditional extension).

## Quick Start

```julia
using MicroSUS, DataFrames

# download with local cache — won't re-download
caminho = baixar(:sim, "PE"; ano = 2023)

# fully typed: dates → Date, SIM's IDADE → years, categoricals →
# PooledArray, text → InlineStrings, CP850 → UTF-8
df = DataFrame(ler(caminho))

# column selection + row filtering IN THE READER
t = ler(caminho;
        colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO],
        filtro  = r -> eh_agressao(r[:CAUSABAS]))   # CVLI: X85–Y09 + Y87.1
cvli = DataFrame(t)

# batch processing, constant memory
using Tables
for lote in Tables.partitions(ler(caminho; tamanho_lote = 50_000))
    # `lote` is a NamedTuple of vectors — a valid Tables.jl table
end

# .dbc → Arrow in streaming
using Arrow
converter(caminho, "do_pe_2023.arrow";
          colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES])
```

## Functions

### `ler` — Streaming table reader

Opens a `.dbc` or `.dbf` as a lazy `TabelaDBC`. Nothing is read until
iteration. Column selection and row filtering happen in the reader —
unrequested columns are never materialized, and the filter parses only
the queried field before deciding whether to keep the row.

```julia
ler(caminho)
ler(caminho; colunas = [:DTOBITO, :IDADE, :SEXO])
ler(caminho; filtro = r -> eh_agressao(r[:CAUSABAS]))
ler(caminho; schema = :auto, encoding = :cp850, pool = false)
ler(caminho; tamanho_lote = 50_000)
```

| Kwarg | Default | Description |
|---|---|---|
| `colunas` | `nothing` (all) | `Vector{Symbol}`; unlisted columns are never materialized |
| `filtro` | `nothing` | `RegistroDBF -> Bool`, runs **before** column parsing |
| `tamanho_lote` | `100_000` | Rows per partition — the pipeline's memory ceiling |
| `schema` | `:auto` | Inferred from the file prefix; or `:sim`, `:sinasc`, `:sih`, `:sia`, `:cnes`, `:sinan`, your own `Dict{Symbol,Symbol}`, or `nothing` (DBF typing only) |
| `encoding` | `:auto` | Header's language driver (DATASUS ⇒ `:cp850`); or `:cp850`, `:latin1`, `:cp1252`, `:utf8` |
| `pool` | `true` | `PooledArray` for the schema's categoricals |

Returns a [`TabelaDBC`](@ref) — a lazy table implementing `Tables.partitions`
(batches) and `Tables.columns` (full materialization). Works directly with
`DataFrame(t)`, `Arrow.write(out, t)`, etc.

### `baixar` / `baixar_sinan` — Download with cache

Downloads `.dbc` files from DATASUS's FTP server with local caching
(Scratch.jl). Duplicate calls return the cached path without re-downloading.

```julia
# SIM, SINASC, SIH, SIA, CNES — by UF
baixar(:sim, "PE"; ano = 2023)                     # single file
baixar(:sim, "PE"; anos = 2013:2023)               # multiple, parallel
baixar(:sih, "PE"; anos = [2023], meses = 1:12)    # monthly

# SINAN — national files (no UF: filter by residence in ler)
baixar_sinan(:dengue; ano = 2024)                  # DENGBR24.dbc
baixar_sinan(:zika; anos = 2016:2020)              # multiple years, parallel
```

| Function | System | Periodicity |
|---|---|---|
| `baixar(:sim, uf)` | SIM (Mortality) | Annual |
| `baixar(:sinasc, uf)` | SINASC (Live Births) | Annual |
| `baixar(:sih, uf)` | SIH (Hospital) | Monthly |
| `baixar(:sia, uf)` | SIA (Outpatient) | Monthly |
| `baixar(:cnes, uf)` | CNES (Facilities) | Monthly |
| `baixar_sinan(agravo)` | SINAN (Notifiable Diseases) | Annual (national) |

Both functions automatically fall back to preliminary data folders
(`PRELIM/`) when consolidated files don't exist yet, with a `@warn`.

#### SINAN diseases

`:dengue`, `:chikungunya`, `:zika`, `:meningite`, `:tuberculose`,
`:hanseniase`, `:hepatites`, `:violencia`, `:leishmaniose_visceral`,
`:leishmaniose_tegumentar`, `:esquistossomose`, `:febre_tifoide`,
`:intoxicacao_exogena`, `:acidente_animais`

#### URL functions

```julia
url_arquivo(:sinasc, "BA"; ano = 2022)      # URL only
url_arquivo(:sim, "PE"; ano = 2025, prelim = true)
url_sinan(:meningite; ano = 2023)
```

### `converter` — Streaming `.dbc` → Arrow

Converts `.dbc`/`.dbf` to Arrow in streaming (one record batch per
batch). Memory is O(`tamanho_lote`). Requires `using Arrow`.

```julia
using Arrow
converter(caminho, "output.arrow")
converter(caminho, "output.arrow";
          colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES],
          filtro  = r -> eh_agressao(r[:CAUSABAS]))
```

### `materializar` — Materialize partitions

Consumes all partitions and concatenates columns into a `NamedTuple` of
vectors. Equivalent to what `DataFrame(t)` calls internally.

```julia
nt = materializar(ler(caminho))
```

### `descomprime_dbc_para_dbf` — Raw DBC → DBF

Converts `.dbc` → `.dbf` in streaming (constant memory, equivalent to
`dbc2dbf` in the R package `read.dbc`).

```julia
descomprime_dbc_para_dbf("input.dbc", "output.dbf")
```

### Schema decoding

#### `decodifica_idade_sim` / `decodifica_idade_sinan`

Converts SIM's 3-digit or SINAN's 4-digit age encoding to **years**:

```julia
decodifica_idade_sim("425")   # 25.0
decodifica_idade_sim("501")   # 101.0
decodifica_idade_sim("310")   # 0.833… (10 months)
decodifica_idade_sim("999")   # missing

decodifica_idade_sinan("4025")  # 25.0
decodifica_idade_sinan("5010")  # 110.0
```

| Digit 1 | Unit | Example (SIM) | Years |
|---|---|---|---|
| 0 | Minutes | `"030"` | 30 / 525960 |
| 1 | Hours | `"112"` | 12 / 8766 |
| 2 | Days | `"230"` | 30 / 365.25 |
| 3 | Months | `"310"` | 10 / 12 |
| 4 | Years | `"425"` | 25.0 |
| 5 | 100 + value | `"501"` | 101.0 |
| 9 | Ignored | `"999"` | `missing` |

### IBGE municipality codes

```julia
dv_ibge(261110)               # 1 (check digit)
codigo7_ibge(261110)          # 2611101 (SIM/SINASC use 6; IBGE uses 7)
codigo6_ibge(2611101)         # 261110, validating the check digit
```

### CID-10 chapters

```julia
capitulo_cid10("X954")        # (numeral="XX", nome="Causas externas …")
capitulo_cid10("I219")        # (numeral="IX", nome="Doenças do aparelho circulatório")
eh_agressao("X954")           # true — X85–Y09 + Y87.1 (CVLI subset)
eh_agressao("Y10")            # false — indeterminate intent
```

### Low-level

```julia
dcl_descomprime(io, chunk -> processar(chunk))   # streaming decompressor
MicroSUS.cabecalho("file.dbc")                    # header only (fields, widths)
MicroSUS.limpar_cache()                           # clear download cache
```

## Tables.jl Compatibility

All reading functions produce [`TabelaDBC`](@ref) objects that implement the
[Tables.jl](https://github.com/JuliaData/Tables.jl) interface. This means
they work directly with DataFrames, Arrow, CSV, and any other Tables.jl
consumer:

```julia
using DataFrames, Arrow

# DataFrame
df = DataFrame(ler(caminho))

# Arrow
Arrow.write("output.arrow", ler(caminho))

# Iterate in batches
for batch in Tables.partitions(ler(caminho))
    # batch is a NamedTuple of vectors
end
```

## Streaming architecture

```
.dbc ──DCL 4KiB/chunk──▶ records ──filter──▶ typed parse ──▶ batches
                         (raw)     (on        (only          (NamedTuple,
                                   demand)     requested       Tables.jl)
                                               columns)
```

The `.dbc` format is a DBF header in clear + 4 bytes CRC + PKWare DCL
compressed records. The decompressor is a pure-Julia port of Mark Adler's
`blast.c`, with the 4 KiB window emitted via a `sink` callback — this is
what enables constant-memory reading regardless of file size.

Every stage is chained through `Channel`s with small buffers:
back-pressure is automatic. If the consumer (your `for` loop or
`Arrow.write`) slows down, decompression waits. The memory ceiling is
`O(tamanho_lote)` — the batch being built plus one in transit —
regardless of the original file size.

## API Reference

See the [API Reference](api.md) page for the complete list of exported
functions and types with their full signatures and docstrings. For
internal implementation details, see the [Internals](internos.md) page.
```@meta
CurrentModule = MicroSUS
```

# Leitura: `ler`, filtro, partições

## Signature

```julia
ler(caminho; colunas = nothing, filtro = nothing, tamanho_lote = 100_000,
    schema = :auto, encoding = :auto, pool = true) -> TabelaDBC
```

Works with `.dbc` and `.dbf`. Returns a **lazy** [`TabelaDBC`](@ref) —
nothing is read until iteration.

| Kwarg | Default | Effect |
|---|---|---|
| `colunas` | `nothing` (all) | `Vector{Symbol}`; unlisted columns aren't even materialized |
| `filtro` | `nothing` | `RegistroDBF -> Bool`, runs before column parsing |
| `tamanho_lote` | `100_000` | Rows per partition — the pipeline's memory ceiling |
| `schema` | `:auto` | See [Schemas and typing](schemas.md) |
| `encoding` | `:auto` | Header's language driver; DATASUS ⇒ `:cp850` |
| `pool` | `true` | `PooledArray` for the schema's categoricals |

## Materialize everything

```julia
using DataFrames
df = DataFrame(ler(caminho))          # via Tables.columns
nt = materializar(ler(caminho))       # NamedTuple of vectors, no DataFrames
```

## Selecting columns

```julia
t = ler(caminho; colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES])
```

The requested order becomes the output column order. Non-existent names
throw `ArgumentError` listing the available ones (useful because layouts
vary between years).

## Filtering rows in the reader

The `filtro` receives a [`MicroSUS.RegistroDBF`](@ref): a view over the
record bytes where `r[:CAMPO]` decodes the field text (trim +
transcoding) **on demand** — only the queried field is decoded, and
rejected rows don't materialize any column.

```julia
# only homicides (CVLI)
t = ler(caminho; filtro = r -> eh_agressao(r[:CAUSABAS]))

# only residents of Petrolina
t = ler(caminho; filtro = r -> r[:CODMUNRES] == "261110")

# combinations — each field access costs one parse
t = ler(caminho; filtro = r -> r[:CODMUNRES] == "261110" &&
                               r[:SEXO] == "2")
```

The value returned by `r[:CAMPO]` is always the **text** of the field
(the schema typing happens later, only on the selected columns of
approved rows) — compare with strings.

## Batch processing

```julia
using Tables
for lote in Tables.partitions(ler(caminho; tamanho_lote = 50_000))
    # `lote` is a NamedTuple of vectors — a valid Tables.jl table.
    # Aggregate here and discard; memory stays O(tamanho_lote).
end
```

Each batch is independent: you can build incremental aggregations
(counts by group, histograms, sums) without ever holding the entire
file in memory.

## Inspect without reading

```julia
cab = MicroSUS.cabecalho(caminho)     # header only
cab.n_registros, cab.tamanho_registro
[c.nome for c in cab.campos]
```

And the `show` of `TabelaDBC` summarizes fields, resolved types,
encoding, and filter status:

```
julia> ler(caminho; colunas = [:DTOBITO, :IDADE])
TabelaDBC — DOPE2023.dbc
  registros (cabeçalho): 68437   encoding: cp850   lote: 100000
  colunas (2):
    DTOBITO     C(8)     → data_ddmmyyyy
    IDADE       C(3)     → idade_sim
```

## Notes

- Deleted records (flag `0x2A`) are skipped automatically.
- The header count (`cab.n_registros`) may differ from the total
  read if there are deletions or filtering.
- `pool = false` replaces `PooledArray` with flat `InlineStrings`
  vectors — useful if the column goes directly to a DuckDB
  `groupby`, for example.</think>

<｜DSML｜tool_calls>
<｜DSML｜invoke name="write">
<｜DSML｜parameter name="content" string="true">```@meta
CurrentModule = MicroSUS
```

# Download and FTP

## `baixar`

```julia
caminho  = baixar(:sim, "PE"; ano = 2023)              # single file
caminhos = baixar(:sim, "PE"; anos = 2013:2023)        # multiple, parallel
caminhos = baixar(:sih, "PE"; anos = [2023], meses = 1:12)
```

- **Local cache** via Scratch.jl: duplicate calls return the already
  downloaded path without touching the network. `forcar = true` ignores
  the cache; `quieto = true` silences `@info`.
- The plural form downloads in parallel (`asyncmap`, 4 connections) and
  returns paths in period order.
- Interrupted downloads don't pollute the cache (write to `.part` +
  atomic `mv`).
- `MicroSUS.limpar_cache()` clears everything.

## FTP paths

Checked against `microdatasus` (Jul 2026) — DATASUS's FTP has changed
structure before, and it's the first thing to check when a download
fails with `550`:

| System | Folder | File |
|---|---|---|
| `:sim` | `SIM/CID10/DORES/` | `DO{UF}{yyyy}.dbc` |
| `:sinasc` | `SINASC/1996_/Dados/DNRES/` | `DN{UF}{yyyy}.dbc` |
| `:sih` | `SIHSUS/200801_/Dados/` | `RD{UF}{yymm}.dbc` |
| `:sia` | `SIASUS/200801_/Dados/` | `PA{UF}{yymm}.dbc` |
| `:cnes` | `CNES/200508_/Dados/ST/` | `ST{UF}{yymm}.dbc` |

[`url_arquivo`](@ref) builds the URL without downloading:

```julia
url_arquivo(:sinasc, "BA"; ano = 2022)
# "ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/1996_/Dados/DNRES/DNBA2022.dbc"
```

## SINAN (notifiable diseases)

Dengue, chikungunya, zika, tuberculosis, hanseníase and other diseases come
from SINAN, whose files are **national** (one `.dbc` covers all of Brazil)
— that's why the API is by *disease*, not by UF. Filter by residence state
in the reader.

```julia
caminho = baixar_sinan(:dengue; ano = 2020)           # DENGBR20.dbc, national
caminhos = baixar_sinan(:zika; anos = 2016:2020)      # multiple years, parallel

# only Pernambuco, filtering in the reader (SG_UF = residence)
pe = DataFrame(ler(caminho; filtro = r -> strip(r[:SG_UF]) == "26"))
```

Available diseases: `:dengue`, `:chikungunya`, `:zika`,
`:leishmaniose_visceral`, `:leishmaniose_tegumentar`, `:esquistossomose`,
`:febre_tifoide`, `:meningite`, `:tuberculose`, `:hanseniase`,
`:hepatites`, `:violencia`, `:intoxicacao_exogena`, `:acidente_animais`
(the full list is in `MicroSUS._SINAN_AGRAVO`). The `:sinan` schema
types the common core of the notification forms (dates, location,
`NU_IDADE_N` → years, `CLASSI_FIN`, `CRITERIO`, `EVOLUCAO`);
disease-specific fields fall back to DBF typing.

Since SINAN finalizes with a delay, `baixar_sinan` tries `FINAIS/` and
falls back to `PRELIM/` automatically when the consolidated file
doesn't exist.

## Preliminary data

SIM and SINASC for recent years live in `PRELIM/` until consolidation
(historically ~18 months). If the consolidated file doesn't exist,
`baixar` **automatically tries the preliminary folder**, with a
`@warn` — an indicator computed over preliminary data deserves an
asterisk.

```julia
baixar(:sinasc, "PE"; ano = 2025)
# ┌ Warning: não achei o consolidado; tentando dados PRELIMINARES
# └   url = ".../SINASC/PRELIM/DNRES/DNPE2025.dbc"

url_arquivo(:sim, "PE"; ano = 2025, prelim = true)   # direct URL
```

If both fail, the error re-thrown is from the main (consolidated) URL.

## Coverage limits

- **SINASC**: the helper covers 1996+ (structure `1996_/Dados`);
  1994–1995 live in `SINASC/1994_1995/` with a different naming
  pattern — build the URL manually and use [`ler`](@ref) on the
  downloaded file.
- **SIH/SIA**: post-2008 structure (`200801_`); files from
  1992–2007/1994–2007 have their own folders and layouts.
- **CNES**: only `ST` (facilities) has a helper; other types
  (`LT`, `PF`, `EQ`, ...) follow the same URL pattern — adapt from
  `url_arquivo(:cnes, ...)`.

## Parallelizing reads across files

DCL is sequential by nature (each byte depends on history), so there's
no parallelism *within* a file. The pattern is to parallelize *across*
files:

```julia
caminhos = baixar(:sinasc, "PE"; anos = 2019:2023, quieto = true)
partes = asyncmap(caminhos; ntasks = Threads.nthreads()) do c
    materializar(ler(c; colunas = [:DTNASC, :CODMUNRES]))
end
```
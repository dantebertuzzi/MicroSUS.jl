# MicroSUS.jl

<div align="center">
  <img src="https://raw.githubusercontent.com/dantebertuzzi/MicroSUS.jl/refs/heads/main/logo_microsus.png" alt="Logo" width="200">
</div>

DATASUS microdata in Julia — **streaming** reads of `.dbc`/`.dbf` with constant memory, per-system typed schemas (SIM, SINASC, SIH, SIA, CNES), CP850 → UTF-8 transcoding, cached downloads, and a Tables.jl interface with partitions.

## Why streaming

DATASUS's `.dbc` is a DBF whose records are compressed with PKWare DCL ("implode"). Once decompressed, the file expands 4–8×; materialized as a `Vector{String}` column by column, several times more than that. This reader never does any of that: the decompressor is a pure-Julia port of Mark Adler's `blast.c` in a streaming version — the 4 KiB window is emitted in chunks — and the entire pipeline (decompression → record assembly → filter → parse → batch) is chained through `Channel`s. Memory is **O(batch_size)**, never O(file): a national multi-year SINASC passes through the reader without having to fit in RAM.

```
.dbc ──DCL 4KiB/chunk──▶ records ──filter──▶ typed parse ──▶ batches
                         (raw)     (on        (only          (NamedTuple,
                                   demand)     requested       Tables.jl)
                                               columns)
```

## Installation

```julia
] add https://github.com/dantebertuzzi/MicroSUS.jl
] test MicroSUS          # full suite, no network required
```

Full documentation (Documenter.jl):

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl     # output at docs/build/index.html
```

Julia ≥ 1.9 (conditional extensions). Dependencies: Tables, InlineStrings, PooledArrays, Scratch, Downloads, Dates. Arrow is optional (weak dep).

## Quick start

```julia
using MicroSUS, DataFrames

# download with a local cache (Scratch.jl) — won't re-fetch what you already have
path = baixar(:sim, "PE"; ano = 2023)

# fully typed: dates → Date, SIM's IDADE → years, categoricals →
# PooledArray, text → InlineStrings, CP850 → UTF-8
df = DataFrame(ler(path))

# column selection + row filtering IN THE READER: unrequested fields
# never even become Strings; the filter parses only the queried field
t = ler(path;
        colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO],
        filtro  = r -> eh_agressao(r[:CAUSABAS]))   # CVLI: X85–Y09 + Y87.1
cvli = DataFrame(t)

# batch processing, constant memory
using Tables
for batch in Tables.partitions(ler(path; tamanho_lote = 50_000))
    # `batch` is a NamedTuple of vectors — a valid Tables.jl table
end

# .dbc → Arrow in streaming (one record batch per batch)
using Arrow
converter(path, "do_pe_2023.arrow";
          colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES])
```

## `ler` — reference

```julia
ler(caminho; colunas = nothing, filtro = nothing, tamanho_lote = 100_000,
    schema = :auto, encoding = :auto, pool = true) -> TabelaDBC
```

| kwarg | default | effect |
|---|---|---|
| `colunas` | `nothing` (all) | `Vector{Symbol}`; the rest aren't even materialized |
| `filtro` | `nothing` | `RegistroDBF -> Bool`, runs **before** parsing; `r[:FIELD]` decodes only the queried field |
| `tamanho_lote` | `100_000` | rows per partition — the pipeline's memory ceiling |
| `schema` | `:auto` | inferred from the file prefix; or `:sim`/`:sinasc`/`:sih`/`:sia`/`:cnes`, your own `Dict{Symbol,Symbol}`, or `nothing` (DBF typing only) |
| `encoding` | `:auto` | header's language driver (DATASUS ⇒ `:cp850`); or `:cp850`, `:latin1`, `:cp1252`, `:utf8` |
| `pool` | `true` | `PooledArray` for the schema's categoricals (analogous to R's factor) |

`TabelaDBC` is lazy: nothing is read until iteration. It implements `Tables.partitions` (batches) and `Tables.columns` (materialization via [`materializar`](#utilities)), so it works directly in `DataFrame(t)`, `Arrow.write(out, t)`, etc.

## Schemas

`schema = :auto` infers the system from the filename prefix:

| prefix | system | example |
|---|---|---|
| `DO` | `:sim` | `DOPE2023.dbc` |
| `DN` | `:sinasc` | `DNBA2022.dbc` |
| `RD`, `SP` | `:sih` | `RDPE2301.dbc` |
| `PA` | `:sia` | `PAPE2301.dbc` |
| `ST`, `LT`, `PF` | `:cnes` | `STPE2301.dbc` |

Available logical types (for custom schemas via `Dict`): `:texto`, `:pool`, `:inteiro`, `:float`, `:data_ddmmyyyy` (SIM/SINASC), `:data_yyyymmdd` (SIH and DBF type `D`), `:idade_sim`.

SIM's `IDADE` (1st digit = unit, 2nd–3rd = value) becomes **years**:

```julia
decodifica_idade_sim("425")   # 25.0
decodifica_idade_sim("501")   # 101.0  (5 ⇒ 100 + value)
decodifica_idade_sim("310")   # 0.833… (10 months)
decodifica_idade_sim("999")   # missing
```

Units: 0 = minutes, 1 = hours, 2 = days, 3 = months, 4 = years, 5 = 100 + value, 9 = ignored.

## Download and FTP

```julia
baixar(:sim, "PE"; ano = 2023)                     # one file, cached
baixar(:sim, "PE"; anos = 2013:2023)               # several, in parallel
baixar(:sih, "PE"; anos = [2023], meses = 1:12)    # monthly
url_arquivo(:sinasc, "BA"; ano = 2022)             # URL only
MicroSUS.limpar_cache()                            # wipes the local cache
```

Current FTP paths (checked against `microdatasus`, Jul 2026):

| system | folder | file |
|---|---|---|
| `:sim` | `SIM/CID10/DORES/` | `DO{UF}{yyyy}.dbc` |
| `:sinasc` | `SINASC/1996_/Dados/DNRES/` | `DN{UF}{yyyy}.dbc` |
| `:sih` | `SIHSUS/200801_/Dados/` | `RD{UF}{yymm}.dbc` |
| `:sia` | `SIASUS/200801_/Dados/` | `PA{UF}{yymm}.dbc` |
| `:cnes` | `CNES/200508_/Dados/ST/` | `ST{UF}{yymm}.dbc` |
| SINAN | `SINAN/DADOS/FINAIS/` | `{DISEASE}BR{yy}.dbc` (national — use `baixar_sinan`) |

**Preliminary data**: if the consolidated file doesn't exist (recent SIM/SINASC years), `baixar` automatically tries the corresponding `PRELIM/` folder, with a `@warn` — an indicator computed over preliminary data deserves an asterisk. `url_arquivo(...; prelim = true)` builds the preliminary URL directly.

**Coverage limits**: SINASC via the helper covers 1996+ (1994–1995 live in `SINASC/1994_1995/` with a different naming pattern — build the URL manually); SIH/SIA cover the post-2008 structure.

## Auxiliary dimensions

```julia
dv_ibge(261110)               # 1 — check digit (Petrolina)
codigo7_ibge(261110)          # 2611101 (SIM/SINASC use 6 digits; IBGE, 7)
codigo6_ibge(2611101)         # 261110, validating the check digit
capitulo_cid10("X954")        # (numeral = "XX", nome = "Causas externas …")
eh_agressao("X954")           # true — X85–Y09 + Y87.1 (CVLI subset)
```

## Utilities

```julia
materializar(t)                                  # all partitions → NamedTuple
MicroSUS.cabecalho("DOPE2023.dbc")               # header only (fields, widths, n)
descomprime_dbc_para_dbf("a.dbc", "a.dbf")       # dbc → dbf in streaming
dcl_descomprime(io, chunk -> ...)                # decompressor with a generic sink
dcl_descomprime(io)                              # ... or materialized (tests)
```

## Design notes

- **Encoding**: the DBF header's language driver decides; `0x00` (unspecified) falls back to CP850, which is DATASUS practice. There's an ASCII fast path — transcoding only costs when a byte ≥ 0x80 is present.
- **Text**: `C` columns become `InlineStrings` sized by the field width (no pointer, no GC pressure); the schema's categoricals become `PooledArray`. `pool = false` turns it off.
- **Deleted records** (flag `0x2A`) are skipped; the dBase EOF marker (`0x1A`) is ignored.
- **Arrow**: `converter` is a conditional extension (Julia ≥ 1.9); without `using Arrow`, calling it raises a `MethodError` with a hint explaining why.
- **Network-free tests**: `runtests.jl` includes a minimal DCL *compressor* (literals, matches, and an end code, with the canonical codes emitted in the format's reversed bit order), which enables a real round-trip of the decompressor and synthetic DBC ≡ DBF, including CP850 and 4 KiB window crossings.

## Known limitations

- No intra-file parallelism (DCL is sequential by nature); parallelize across files (`baixar(...; anos = ...)` + tasks).
- Schemas cover the most-used fields of each system; fields outside the schema fall back to DBF typing (`N` → integer/float, `D` → date, `C` → text). Schema PRs are welcome.
- Dimension tables with *names* (municipalities, 4-digit CID-10, CBO) are out of scope for the package — join with IBGE's DTB.

## License

MIT

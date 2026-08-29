# MicroSUS.jl

<div align="center">
  <img src="https://raw.githubusercontent.com/dantebertuzzi/MicroSUS.jl/refs/heads/main/logo_microsus.png" alt="Logo" width="200">
  <br>
  <em>Microdados do DATASUS em Julia — 🇧🇷</em>
  <br>
  <em>Ver <a href="README.pt.md">README.pt.md</a> para a versão em português.</em>
</div>

DATASUS microdata in Julia — **streaming** reads of `.dbc`/`.dbf` with constant memory, per-system typed schemas (SIM, SINASC, SIH, SIA, CNES, SINAN), CP850 → UTF-8 transcoding, cached downloads, and a Tables.jl interface with partitions.

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
] add MicroSUS
] test MicroSUS          # full suite, no network required
```

```bash
# optional: also exercises every registered source (fontes()) against
# the real DATASUS FTP
MicroSUS_TEST_NETWORK=true julia --project -e 'using Pkg; Pkg.test()'
```

Full documentation (Documenter.jl):

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl     # output at docs/build/index.html
```

Documentation: **[dantebertuzzi.github.io/MicroSUS.jl](https://dantebertuzzi.github.io/MicroSUS.jl/)** (in Portuguese). Version history in [CHANGELOG.md](CHANGELOG.md).

Julia ≥ 1.9 (conditional extensions). Dependencies: DataFrames, Tables, InlineStrings, PooledArrays, Scratch, Downloads, Dates. Arrow is optional (weak dep).

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

# SINAN: national files by disease (no UF — filter by residence in the reader)
sinan_path = baixar_sinan(:dengue; ano = 2024)
dengue = DataFrame(ler(sinan_path;
    colunas = [:DT_NOTIFIC, :SG_UF, :ID_MN_RESI, :CLASSI_FIN, :NU_IDADE_N],
    filtro = r -> r[:SG_UF] == "26"))   # Pernambuco

# multi-year download in parallel
caminhos = baixar(:sim, "PE"; anos = 2019:2023)
for c in caminhos
    converter(c, replace(basename(c), ".dbc" => ".arrow");
              colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO])
end
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
| `schema` | `:auto` | inferred from the file prefix; or `:sim`/`:sinasc`/`:sih`/`:sia`/`:cnes`/`:sinan`, your own `Dict{Symbol,Symbol}`, or `nothing` (DBF typing only) |
| `encoding` | `:auto` | header's language driver (DATASUS ⇒ `:cp850`); or `:cp850`, `:latin1`, `:cp1252`, `:utf8` |
| `pool` | `true` | `PooledArray` for the schema's categoricals (analogous to R's factor) |

`TabelaDBC` is lazy: nothing is read until iteration. It implements `Tables.partitions` (batches) and `Tables.columns` (materialization via [`materializar`](#utilities)), so it works directly in `DataFrame(t)`, `Arrow.write(out, t)`, etc.

```
julia> ler(caminho; colunas = [:DTOBITO, :IDADE, :SEXO])
TabelaDBC — DOPE2023.dbc
  registros (cabeçalho): 68437   encoding: cp850   lote: 100000
  colunas (3):
    DTOBITO     C(8)     → data_ddmmyyyy
    IDADE       C(3)     → idade_sim
    SEXO        C(1)     → pool
```

## Schemas

`schema = :auto` infers the system from the filename prefix:

| prefix | system | example |
|---|---|---|
| `DO` | `:sim` | `DOPE2023.dbc` |
| `DN` | `:sinasc` | `DNBA2022.dbc` |
| `RD`, `SP` | `:sih` | `RDPE2301.dbc` |
| `PA` | `:sia` | `PAPE2301.dbc` |
| `ST`, `LT`, `PF` | `:cnes` | `STPE2301.dbc` |
| `DENG`, `CHIK`, `ZIKA`, … | `:sinan` | `DENGBR20.dbc` |

Available logical types (for custom schemas via `Dict`): `:texto`, `:pool`, `:inteiro`, `:float`, `:data_ddmmyyyy` (SIM/SINASC), `:data_yyyymmdd` (SIH and DBF type `D`), `:idade_sim`, `:idade_sinan`.

SIM's `IDADE` (1st digit = unit, 2nd–3rd = value) becomes **years**:

```julia
decodifica_idade_sim("425")   # 25.0
decodifica_idade_sim("501")   # 101.0  (5 ⇒ 100 + value)
decodifica_idade_sim("310")   # 0.833… (10 months)
decodifica_idade_sim("999")   # missing
```

Units: 0 = minutes, 1 = hours, 2 = days, 3 = months, 4 = years, 5 = 100 + value, 9 = ignored.

SINAN's `NU_IDADE_N` uses 4 digits (`decodifica_idade_sinan`): `"4025"` → 25.0, `"3006"` → 0.5, `"5010"` → 110.0.

Extend schemas at runtime:

```julia
MicroSUS.SCHEMAS[:sim][:LINHAA] = :texto    # field now typed as text
MicroSUS.SCHEMAS[:sim][:OCUP] = :pool       # change to categorical
```

## Download and FTP

### `baixar` / `url_arquivo` — SIM, SINASC, SIH, SIA, CNES (by UF)

```julia
baixar(:sim, "PE"; ano = 2023)                     # one file, cached
baixar(:sim, "PE"; anos = 2013:2023)               # several, in parallel
baixar(:sih, "PE"; anos = [2023], meses = 1:12)    # monthly
url_arquivo(:sinasc, "BA"; ano = 2022)             # URL only
MicroSUS.limpar_cache()                            # wipes the local cache
```

### `baixar_sinan` / `url_sinan` — SINAN (national, by disease)

SINAN files are **national** (one `.dbc` per year covers all of Brazil) — filter by residence state/municipality in `ler`:

```julia
baixar_sinan(:dengue; ano = 2024)              # DENGBR24.dbc
baixar_sinan(:zika; anos = 2016:2020)          # multiple years, parallel
url_sinan(:meningite; ano = 2023)              # URL only

# filter to a single municipality in the reader
pe_dengue = DataFrame(ler(baixar_sinan(:dengue; ano = 2024);
    colunas = [:DT_NOTIFIC, :ID_MN_RESI, :CLASSI_FIN, :NU_IDADE_N],
    filtro = r -> r[:ID_MN_RESI] == "261110"))   # Petrolina/PE
```

Available SINAN diseases: `:dengue`, `:chikungunya`, `:zika`, `:malaria`, `:tuberculose`, `:hanseniase`, `:meningite`, `:violencia`, `:leishmaniose_visceral`, `:leishmaniose_tegumentar`, `:esquistossomose`, `:febre_tifoide`, `:hepatites`, `:intoxicacao_exogena`, `:acidente_animais`.

> **Malaria**: the SINAN file only covers **extra-Amazonian** notification. Cases in the Amazon region — the large majority — are reported through SIVEP-Malária, which is not part of SINAN and is not served by this FTP. A `MALABR{yy}.dbc` of a few hundred KB is expected, not a truncated download.

SINAN files finalize with delay; `baixar_sinan` automatically falls back from `FINAIS/` to `PRELIM/` if the consolidated file doesn't exist.

### `fetch_datasus` — all-in-one: download + read + concatenate

```julia
# SIM: deaths in Pernambuco, 2019–2023 — already processed
do_pe = fetch_datasus(:SIM_DO; uf = "PE", anos = 2019:2023)

# SINASC: births in PE and BA, raw codes (no processing)
dn = fetch_datasus(:SINASC; uf = ["PE", "BA"], anos = 2022, processar = false)

# SIH: hospital admissions in PE, first half of 2024
rd = fetch_datasus(:SIH_RD; uf = "PE", anos = 2024, meses = 1:6)

# SINAN: dengue in all of Brazil (national source: uf is ignored)
dengue = fetch_datasus(:SINAN_DENGUE; anos = 2024)

# all sources available, including dates of reported/symptom onset
do_pe.DT_NOTIFIC = coalesce.(do_pe.DT_SIN_PRI, do_pe.DT_NOTIFIC)
```

`fetch_datasus` concatenates by column name (`cols = :union`), adds `UF_ARQUIVO`, `ANO_ARQUIVO`, and `MES_ARQUIVO` origin columns, and skips missing files with a `@warn`. Use `fontes()` to list all available sources with their IDs, descriptions, periodicity, and year ranges, or `fonte(:SIM_DO)` to inspect a single one.

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

## Standardization: `process_sim` / `process_sinasc`

`fetch_datasus` calls the source's standardization routine by default
(`processar = true`). It replaces codes with readable labels, converts text
dates to `Date` and text-stored numerics to numbers:

```julia
df = fetch_datasus(:SIM_DO; uf = "PE", anos = 2023)          # already standardized
raw = fetch_datasus(:SIM_DO; uf = "PE", anos = 2023, processar = false)
process_sim(raw)                                              # equivalent
```

For SIM it labels `SEXO`, `RACACOR`, `ESTCIV`, `ESC`, `LOCOCOR`, `CIRCOBITO`
and friends, and derives `IDADE_ANOS` in whole years. For SINASC: `PARTO`,
`GRAVIDEZ`, `ESCMAE`, `ESTCIVMAE`, `CONSULTAS`, `LOCNASC`, `RACACOR`.

Columns absent from a given year's layout are silently skipped — DATASUS
layouts change between years, and the routine is written to survive that. The
remaining sources (SIH, SIA, CNES, SINAN) have no routine yet: they return raw
codes with an `@info`.

## Auxiliary dimensions

```julia
dv_ibge(261110)               # 1 — check digit (Petrolina)
codigo7_ibge(261110)          # 2611101 (SIM/SINASC use 6 digits; IBGE, 7)
codigo6_ibge(2611101)         # 261110, validating the check digit

# CID-10 chapters
capitulo_cid10("X954")        # (numeral = "XX", nome = "Causas externas …")
capitulo_cid10("I219")        # (numeral = "IX", nome = "Doenças do aparelho circulatório")

eh_agressao("X954")           # true — X85–Y09 + Y87.1 (CVLI subset)
eh_agressao("Y10")            # false — indeterminate intent
eh_agressao(missing)          # false

# IBGE → microdata join (common pattern)
df.cod7 = codigo7_ibge.(String.(df.CODMUNRES))
leftjoin!(df, tabela_ibge; on = :cod7 => :codigo_municipio)
```

## Utilities

```julia
materializar(t)                                  # all partitions → NamedTuple
MicroSUS.cabecalho("DOPE2023.dbc")               # header only (fields, widths, n)
descomprime_dbc_para_dbf("a.dbc", "a.dbf")       # dbc → dbf in streaming
dcl_descomprime(io, chunk -> ...)                # decompressor with a generic sink
dcl_descomprime(io)                              # ... or materialized (tests)

# list all available data sources
fontes() |> DataFrame
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

## How to cite

If MicroSUS.jl was part of your analysis pipeline, cite **two things
separately**: the software and the data. They are distinct objects with
distinct responsibilities — the package answers for reading and typing, DATASUS
answers for the content.

### 1. The software

The repository ships a [`CITATION.cff`](CITATION.cff), which GitHub reads
natively: the **"Cite this repository"** button in the sidebar generates ready
APA and BibTeX. A [`CITATION.bib`](CITATION.bib) is also provided:

```bibtex
@software{bertuzzi_microsus_2026,
  author  = {Bertuzzi, Dante},
  title   = {{MicroSUS.jl}: streaming reader for {DATASUS} public health microdata in {Julia}},
  year    = {2026},
  version = {0.2.1},
  url     = {https://github.com/dantebertuzzi/MicroSUS.jl},
  note    = {Julia package}
}
```

**Cite the version you used**, not "the latest". Results depend on it: 0.2.1,
for instance, fixed a defect that returned empty date columns for SIM. Run
`pkg> status MicroSUS` and use the number it prints.

### 2. The DATASUS data

DATASUS is the primary source and must be cited as such, **with the extraction
date** — the databases are republished retroactively, and the same query run on
different dates can return different numbers:

> BRASIL. Ministério da Saúde. DATASUS. *Sistema de Informações sobre
> Mortalidade (SIM)*: microdata. Brasília: Ministério da Saúde, 2023.
> Available at: https://datasus.saude.gov.br. Accessed: 29 Aug. 2026.

Swap the system for the one you used (SIM, SINASC, SIH/SUS, SIA/SUS, CNES,
SINAN) and the access date for yours.

### 3. Reproducibility

So that someone else reaches your number, record in the paper or supplementary
material: the **MicroSUS.jl and Julia versions**; the `Project.toml` and
`Manifest.toml` of the environment (the `Manifest.toml` pins the whole
dependency tree and is what makes the environment reconstructible with
`Pkg.instantiate()`); the **extraction date** of the DATASUS files; and whether
you used **preliminary** data (`PRELIM/`) — `baixar` warns with `@warn` when it
falls back to that folder.

### The standards behind this

| Standard | What it establishes |
|---|---|
| [FORCE11 — Software Citation Principles](https://force11.org/info/software-citation-principles-published-2016/) | Software is a citable research product. Six principles: importance, credit, unique identification, persistence, accessibility and **specificity** (cite the exact version). |
| [Citation File Format (CFF) 1.2.0](https://citation-file-format.github.io/) | Machine-readable citation metadata. What GitHub and Zenodo consume. |
| ABNT NBR 6023:2018 | References in Brazilian publications; requires `Disponível em` + `Acesso em` for electronic documents. |
| [Zenodo + GitHub](https://docs.github.com/en/repositories/archiving-a-github-repository/referencing-and-citing-content) | Mints a persistent DOI per release, plus a *concept DOI* always pointing at the newest version. |

**Still missing here**: a **DOI**. The citation currently points at a GitHub
URL, which is not a persistent identifier — if the repository is renamed or
transferred, the reference breaks. Connecting the repository to
[Zenodo](https://zenodo.org) fixes that. Once the first DOI is minted, add a
`doi:` field to `CITATION.cff` and a `doi = {...}` to the BibTeX.

## License

MIT
# Changelog

All notable changes to MicroSUS.jl are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the package is in `0.x`, breaking changes bump the minor version and
fixes bump the patch version, following Julia's `^0.x.y` compatibility rules.

## [Unreleased]

### Added

- `ler(...; ignorar_ausentes = true)` — drops requested columns that do not
  exist in this file's layout instead of raising. The SIH layout gained fields
  in 2011, 2013 and 2014, so asking for `:DIAGSEC1` used to abort the read of
  2010 and force a defensive `cabecalho` call before every file. Dropped
  columns are reported through `@debug`; if *none* of the requested columns
  exists it is still an error, since that means a wrong file or a typo.
- `cabecalho` is now exported and documented in the public API reference. It
  reads the header without decompressing, which is the first thing any
  multi-year analysis does, and it required the `MicroSUS.` prefix.
- `process_sih` and `idade_sih` — standardization for SIH/SUS. Labels `SEXO`,
  `RACA_COR`, `IDENT` and `CAR_INT`, and derives `IDADE_ANOS` from the
  `IDADE` + `COD_IDADE` pair. Applied automatically by
  `fetch_datasus(:SIH_RD; ...)`.

  SIH codes differ from SIM's: `SEXO` is 1/3 (not 1/2) and `RACA_COR` is
  `01`–`05` + `99` (not `1`–`5`, where "Parda" is `4`). Reusing a dictionary
  across the two systems produces wrong labels with no error.

  `COBRANCA` and `ESPEC` are deliberately left raw: their domains are large and
  version-dependent, and `rotular!` turns an unmapped code into `missing`, so a
  partial dictionary would silently erase valid data.

### Changed

- **Breaking:** the `:sih` schema now types `MORTE`, `COD_IDADE`, `ANO_CMPT`
  and `MES_CMPT` as integers. `MORTE` is DBF type `N`, so the previous `:pool`
  actively downgraded a numeric field to pooled text and `sum(df.MORTE)` did
  not do what it appeared to; the other three were absent from the schema and
  fell back to text. Code comparing these columns to strings
  (`df.MORTE .== "1"`) must be updated to compare to integers.

### Documentation

- New "Exemplos intermediários" page: end-to-end analyses of AMI
  hospitalisations in the Northeast, centred on the traps — layout drift across
  years, the dead `DIAG_SECUN` field, the 6-vs-7-digit IBGE municipality join,
  cross-system comparison without a shared identifier, age standardisation, and
  the data-entry lag that truncates the last three months of any
  competence-based extract. The full pipeline is runnable at
  `docs/exemplo_intermediario.jl`; every number on the page came from one run
  of it.
- Shared plotting theme extracted to `docs/tema.jl`.
- The schemas guide documents two layout traps that break long SIH series: the
  field count changes (86 → 93 → 95 → 113 between 2010 and 2014), and the
  secondary-diagnosis field moves — `DIAG_SECUN` is the live field through
  2014, the `DIAGSEC1`–`DIAGSEC9` block appears empty in the 2014 layout and
  takes over in January 2015, when the old one goes to zero. Counting only one
  of them zeroes out half of any series that crosses the boundary.
- The standardization helpers (`rotular!`, `para_data!`, `para_int!`,
  `processar_fonte`) are now documented under Internals, with a note that an
  unmapped code becomes `missing` — so a partial dictionary erases valid data.

## [0.2.1] - 2026-08-29

### Fixed

- `process_sim` returned `DTOBITO` and `IDADE_ANOS` entirely `missing`,
  which affected the default path of `fetch_datasus(:SIM_DO; ...)`
  (`processar = true`). `ler` already types `DTOBITO` as `Date` (schema
  `:data_ddmmyyyy`) and `IDADE` as `Float64` (schema `:idade_sim`), but
  `para_data!` and `idade_sim` only handled text: given an already-typed
  value, they tried to parse its string representation and fell through
  to the failure branch. Both are now idempotent, following the pattern
  `_para_num!` already used — `para_data!` passes a `Date` through
  unchanged, and `idade_sim` passes a `Real` through truncated to whole
  years. Verified against SIM/AC/2023: 0/4189 valid dates before,
  4189/4189 after.

  The same fix applies to every date column `process_sim` and
  `process_sinasc` touch (`DTNASC`, `DTATESTADO`, `DTINVESTIG`,
  `DTCADASTRO`, `DTNASCMAE`, `DTULTMENST`, `DTDECLARAC`).

  This changes results for callers who were receiving empty columns.
  No signature changed and nothing was added or removed, so code that
  produced correct results still does.

### Documentation

- New "Exemplos práticos (iniciantes)" page: a step-by-step walkthrough
  for readers with no programming background, from installation to a
  first chart, with every line explained. Covers three worked examples
  against real DATASUS data (deaths by month, deaths by age group and
  sex, and a cesarean-section time series).
- Documentation is now entirely in Portuguese, matching the audience of
  a Brazilian public-health data package. `index.md` was rewritten and
  now also covers `fetch_datasus`, `fontes` and source standardization.
- Restored `docs/src/guia/download.md`, whose first 111 lines were a
  duplicated English copy of the reading guide followed by leaked
  tool-call markup.

## [0.2.0] - 2026-07-27

### Added

- `fetch_datasus`, `fontes` and `fonte` — the high-level interface that
  resolves the FTP URL, downloads with caching, reads, concatenates by
  column name (`cols = :union`) and adds the `UF_ARQUIVO`, `ANO_ARQUIVO`
  and `MES_ARQUIVO` origin columns. Missing files are skipped with a
  `@warn`.
- `process_sim` and `process_sinasc` — source standardization: coded
  categoricals become readable labels, text dates become `Date`, and
  numerics stored as text become numbers. `process_sim` also derives
  `IDADE_ANOS` in whole years.
- Source catalog covering SIM, SINASC, SIH-RD, SIA-PA, CNES-ST, CNES-PF
  and six SINAN notifiable diseases, with automatic fallback from
  `FINAIS/` to `PRELIM/`.
- Full Documenter.jl documentation with a deploy job in CI.

### Fixed

- `fetch_datasus`, `fontes`, `fonte`, `process_sim` and `process_sinasc`
  were implemented but never wired into the module — the `include` calls
  and exports were missing, so the functions did not exist at runtime.

### Changed

- DataFrames is now a direct dependency (it was already required in
  practice by the fetch and processing layers).

## [0.1.0] - 2026-07-09

### Added

- Streaming reader for DATASUS `.dbc` (PKWare DCL) and `.dbf` files with
  constant memory: a pure-Julia port of Mark Adler's `blast.c` emitting
  the 4 KiB window through a `sink` callback, with every stage chained
  through `Channel`s. Memory is `O(tamanho_lote)` regardless of file
  size.
- `ler` with in-reader column selection and row filtering — unrequested
  columns are never materialized, and the filter decodes only the field
  it queries before deciding whether to keep the row.
- Per-system typed schemas (SIM, SINASC, SIH, SIA, CNES, SINAN) with
  automatic detection from the filename prefix.
- CP850 / Latin-1 / CP1252 → UTF-8 transcoding driven by the DBF header's
  language driver, with an ASCII fast path.
- `baixar`, `baixar_sinan`, `url_arquivo` and `url_sinan` — downloads
  with a local cache (Scratch.jl) and parallel multi-period fetches.
- Tables.jl interface (`Tables.partitions`, `Tables.columns`) and
  `materializar`.
- `converter` — streaming `.dbc` → Arrow, one record batch per batch,
  as a conditional extension on Arrow.
- `descomprime_dbc_para_dbf` and `dcl_descomprime` for raw access to the
  decompressor.
- Auxiliary dimensions: `dv_ibge`, `codigo7_ibge`, `codigo6_ibge`,
  `capitulo_cid10`, `eh_agressao`, `decodifica_idade_sim` and
  `decodifica_idade_sinan`.

[Unreleased]: https://github.com/dantebertuzzi/MicroSUS.jl/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/dantebertuzzi/MicroSUS.jl/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/dantebertuzzi/MicroSUS.jl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/dantebertuzzi/MicroSUS.jl/releases/tag/v0.1.0

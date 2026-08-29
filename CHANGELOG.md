# Changelog

All notable changes to MicroSUS.jl are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the package is in `0.x`, breaking changes bump the minor version and
fixes bump the patch version, following Julia's `^0.x.y` compatibility rules.

## [Unreleased]

### Added

- `CITATION.cff` and `CITATION.bib`, so GitHub's "Cite this repository" button
  works and a BibTeX entry is available. Both READMEs gained a "How to cite"
  section covering the software, the DATASUS data (with extraction date, since
  the databases are republished retroactively) and reproducibility, plus the
  standards behind those recommendations (FORCE11, CFF 1.2.0, ABNT NBR 6023).
- `baixar_sinan(:malaria)` / `url_sinan(:malaria)` — the agravo was registered
  for `fetch_datasus` as `:SINAN_MALARIA` but missing from `_SINAN_AGRAVO`, so
  the `baixar_sinan` path raised `ArgumentError` for a disease both READMEs
  listed as available.

### Documentation

- Both READMEs document `process_sim` / `process_sinasc`, exported since 0.2.0
  but never mentioned.
- Noted that SINAN's malaria file only covers extra-Amazonian notification —
  Amazon cases go through SIVEP-Malária, which is not in this FTP. A file of a
  few hundred KB is expected, not a truncated download.

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

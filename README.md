# MicroSUS.jl

# MissingPatterns
<div align="center">
  <img src="https://raw.githubusercontent.com/dantebertuzzi/MicroSUS.jl/main/logo_microsus.png" alt="Logo do MicroSUS.jl" width="200">
</div>

[![CI](https://github.com/SEU_USUARIO/MicroSUS.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/SEU_USUARIO/MicroSUS.jl/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Interface moderna em Julia para **download, descompressão, leitura e padronização dos microdados públicos do DATASUS** — SIM, SINASC, SIH, SIA, CNES e SINAN.

Inspirado no pacote [`microdatasus`](https://github.com/rfsaldanha/microdatasus) do R (Saldanha, Bastos & Barcellos, 2019), mas com **implementação totalmente independente**, escrita do zero em Julia — incluindo o descompressor do formato `.dbc`, que dispensa qualquer dependência de C ou do R.

## Instalação

```julia
] add https://github.com/dantebertuzzi/MicroSUS.jl
```

Dependências: `DBFTables`, `DataFrames`, `Scratch`, `Tables` (mais stdlib).

## Uso rápido

```julia
using MicroSUS

# Óbitos de Pernambuco, 2019–2023, já padronizados
do_pe = fetch_datasus(:SIM_DO; uf = "PE", anos = 2019:2023)

# Nascidos vivos de PE e BA em 2022, códigos brutos
dn = fetch_datasus(:SINASC; uf = ["PE", "BA"], anos = 2022, processar = false)

# Internações hospitalares, primeiro semestre de 2024
rd = fetch_datasus(:SIH_RD; uf = "PE", anos = 2024, meses = 1:6)

# Dengue no Brasil (fonte de abrangência nacional)
dengue = fetch_datasus(:SINAN_DENGUE; anos = 2024)

# Catálogo de fontes
using DataFrames
DataFrame(fontes())
```

As colunas `UF_ARQUIVO`, `ANO_ARQUIVO` e `MES_ARQUIVO` identificam a origem de cada linha quando vários arquivos são concatenados. A concatenação usa `cols = :union`, acomodando mudanças de layout entre anos.

### Leitura direta de arquivos `.dbc`

```julia
df = read_dbc("DOPE2023.dbc")          # → DataFrame
tbl = read_dbc_table("DOPE2023.dbc")   # → DBFTables.Table (fonte Tables.jl preguiçosa)
dbc2dbf("DOPE2023.dbc", "DOPE2023.dbf")  # conversão em disco
```

`read_dbc_table` devolve um objeto que implementa a interface Tables.jl — funciona com qualquer sink do ecossistema (`CSV.write`, `Arrow.write`, `SQLite.load!`, ...).

### Padronização

`fetch_datasus(...; processar = true)` (padrão) aplica a rotina da fonte, quando implementada:

- **`process_sim`** — datas `ddmmaaaa` → `Date`; rótulos para sexo, raça/cor, estado civil, escolaridade, local de ocorrência, circunstância do óbito e demais categóricas; `IDADE_ANOS` decodificada do campo `IDADE` (unidade + valor).
- **`process_sinasc`** — datas; rótulos para sexo, tipo de parto, gravidez, escolaridade/estado civil da mãe, raça/cor, consultas de pré-natal; numéricos (`PESO`, `APGAR1/5`, `SEMAGESTAC`, ...).

As rotinas são idempotentes quanto ao layout: colunas ausentes num ano específico são ignoradas em silêncio, e as funções aceitam qualquer `DataFrame` — você pode aplicá-las a arquivos lidos manualmente com `read_dbc`.

Códigos "ignorado" (`9`, `0`) e fora do dicionário viram `missing`.

### Cache

Arquivos baixados ficam num diretório gerenciado pelo [Scratch.jl](https://github.com/JuliaPackaging/Scratch.jl) (removido junto com o pacote):

```julia
cache_dir()      # onde os .dbc estão
limpar_cache()   # apaga tudo
fetch_datasus(:SIM_DO; uf = "PE", anos = 2023, cache = false)  # ignora cache
```

## Fontes disponíveis

| id | Sistema | Periodicidade | Abrangência | Desde | Padronização |
|---|---|---|---|---|---|
| `:SIM_DO` | SIM — Declarações de Óbito (CID-10) | anual | UF | 1996 | ✅ |
| `:SINASC` | SINASC — Nascidos Vivos | anual | UF | 1996 | ✅ |
| `:SIH_RD` | SIH — Internações (AIH reduzida) | mensal | UF | 1992 | — |
| `:SIA_PA` | SIA — Produção Ambulatorial | mensal | UF | 1994 | — |
| `:CNES_ST` | CNES — Estabelecimentos | mensal | UF | 2005 | — |
| `:CNES_PF` | CNES — Profissionais | mensal | UF | 2005 | — |
| `:SINAN_DENGUE` | SINAN — Dengue | anual | BR | 2000 | — |
| `:SINAN_CHIKUNGUNYA` | SINAN — Chikungunya | anual | BR | 2015 | — |
| `:SINAN_ZIKA` | SINAN — Zika | anual | BR | 2016 | — |
| `:SINAN_MALARIA` | SINAN — Malária | anual | BR | 2004 | — |
| `:SINAN_TUBERCULOSE` | SINAN — Tuberculose | anual | BR | 2001 | — |
| `:SINAN_VIOLENCIA` | SINAN — Violências | anual | BR | 2009 | — |

O SIA-PA trata automaticamente o particionamento de meses volumosos (`PAxxaamma.dbc`, `...b.dbc`, ...). Fontes anuais recentes tentam também os diretórios `PRELIM` (dados preliminares).

Adicionar uma fonte nova é registrar um `FonteDATASUS` em `src/sources.jl` — nenhuma outra parte do código precisa mudar.

## Arquitetura

```
fetch_datasus(:SIM_DO; uf = "PE", anos = 2023)
     │
     ├── sources.jl   catálogo: FTP + convenção de nomes por fonte
     ├── download.jl  Downloads.jl (libcurl fala FTP) + cache Scratch.jl
     ├── dbc.jl       header DBF intacto + CRC32 pulado + corpo p/ blast
     ├── blast.jl     descompressor PKWare DCL "implode" em Julia puro
     ├── DBFTables.jl leitura do DBF resultante (interface Tables.jl)
     └── process/     padronização data-driven por fonte
```

### O formato `.dbc`

Um `.dbc` do DATASUS é um `.dbf` (dBase) cujo bloco de registros foi comprimido com o algoritmo *implode* da PKWare Data Compression Library:

```
[0 .. hsize-1]      header DBF intacto (hsize nos bytes 8–9, little-endian)
[hsize .. hsize+3]  CRC32 (ignorado na leitura)
[hsize+4 .. fim]    registros comprimidos (PKWare DCL)
```

`src/blast.jl` implementa o *explode* correspondente em ~200 linhas de Julia puro: códigos de Huffman canônicos fixos (com bits invertidos, particularidade do formato), leitura de bits LSB-first e cópias LZ77 com dicionário de até 4 KiB. A implementação foi validada byte a byte contra arquivos `.dbc` reais, com verificação estrutural do DBF resultante (nº de registros × tamanho de registro + EOF `0x1a`).

## Comparação com o `microdatasus` (R)

| | `microdatasus` | `MicroSUS.jl` |
|---|---|---|
| Descompressão `.dbc` | `read.dbc` (C, blast.c) | Julia puro |
| Leitura DBF | `foreign::read.dbf` | `DBFTables.jl` |
| Retorno | `data.frame` | `DataFrame` (+ fonte Tables.jl) |
| Cache de downloads | não | sim (Scratch.jl) |
| Particionamento SIA-PA | sim | sim |
| Fontes padronizadas | SIM, SINASC, SIH, CNES, SIA... | SIM, SINASC (demais no roadmap) |

## Roadmap

- [ ] `process_sih`, `process_cnes`, `process_sia`, `process_sinan_*`
- [ ] Junção opcional com tabelas auxiliares (municípios, CID-10, CBO, CNAE)
- [ ] SIM CID-9 (1979–1995) e SINASC anterior a 1996
- [ ] Grupos adicionais do CNES (LT, EQ, SR, EP, ...) e do SIH (SP, ER)
- [ ] Download paralelo (`Threads.@spawn` por arquivo)
- [ ] Espelho HTTP como fallback do FTP
- [ ] Registro no General

> **Nota** — o DATASUS reorganiza diretórios do FTP periodicamente. Se um download falhar com "arquivos não encontrados", verifique os caminhos em `src/sources.jl`; toda a informação de localização está concentrada ali.

## Citação dos dados

Os microdados são do Ministério da Saúde/DATASUS. Ao usar, cite a fonte original dos dados e, se fizer sentido metodologicamente, o artigo do `microdatasus` que inspirou a interface: Saldanha, R. F., Bastos, R. R., & Barcellos, C. (2019). *Microdatasus: pacote para download e pré-processamento de microdados do DATASUS*. Cadernos de Saúde Pública, 35(9).

## Licença

MIT.

# MicroSUS.jl

<div align="center">
  <img src="https://raw.githubusercontent.com/dantebertuzzi/MicroSUS.jl/refs/heads/main/logo_microsus.png" alt="Logo" width="200">
  <br>
  <em>Microdados do DATASUS em Julia — 🇧🇷</em>
  <br>
  <em>See <a href="README.md">README.md</a> for the English version.</em>
</div>

Microdados do DATASUS em Julia — leitura **streaming** de `.dbc`/`.dbf` com memória constante, schemas tipados por sistema (SIM, SINASC, SIH, SIA, CNES, SINAN), transcodificação CP850 → UTF-8, download com cache local e interface Tables.jl com partições.

## Por que streaming

O `.dbc` do DATASUS é um DBF cujos registros são comprimidos com PKWare DCL ("implode"). Ao descomprimir, o arquivo expande 4–8×; materializado como `Vector{String}` coluna por coluna, várias vezes mais que isso. Este leitor nunca faz nada disso: o descompressor é um porte puro Julia do `blast.c` de Mark Adler em versão streaming — a janela de 4 KiB é emitida em chunks — e todo o pipeline (descompressão → montagem de registros → filtro → parse → lote) é encadeado por `Channel`s. A memória é **O(tamanho_lote)**, nunca O(arquivo): um SINASC nacional multi-ano passa pelo leitor sem precisar caber na RAM.

```
.dbc ──DCL chunks──▶ registros ──filtro──▶ parse tipado ──▶ lotes
       de 4 KiB      (brutos)    (sob        (só as         (NamedTuple,
                                  demanda)    colunas         Tables.jl)
                                              pedidas)
```

## Instalação

```julia
] add MicroSUS
] test MicroSUS          # suíte completa, sem depender de rede
```

Documentação completa (Documenter.jl):

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl     # saída em docs/build/index.html
```

Julia ≥ 1.9 (extensões condicionais). Dependências: Tables, InlineStrings, PooledArrays, Scratch, Downloads, Dates. Arrow é opcional (weak dep).

## Início rápido

```julia
using MicroSUS, DataFrames

# download com cache local (Scratch.jl) — não rebaixa o que já tem
caminho = baixar(:sim, "PE"; ano = 2023)

# tudo tipado: datas → Date, IDADE do SIM → anos, categóricas →
# PooledArray, texto → InlineStrings, CP850 → UTF-8
df = DataFrame(ler(caminho))

# seleção de colunas + filtro de linhas NO LEITOR: campos não pedidos
# nem viram String; o filtro faz parse só do campo consultado
t = ler(caminho;
        colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO],
        filtro  = r -> eh_agressao(r[:CAUSABAS]))   # CVLI: X85–Y09 + Y87.1
cvli = DataFrame(t)

# processamento em lotes, memória constante
using Tables
for lote in Tables.partitions(ler(caminho; tamanho_lote = 50_000))
    # `lote` é um NamedTuple de vetores — uma tabela Tables.jl válida
end

# .dbc → Arrow em streaming (um record batch por lote)
using Arrow
converter(caminho, "do_pe_2023.arrow";
          colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES])

# SINAN: arquivos nacionais por agravo (sem UF — filtre residência no leitor)
sinan_caminho = baixar_sinan(:dengue; ano = 2024)
dengue = DataFrame(ler(sinan_caminho;
    colunas = [:DT_NOTIFIC, :SG_UF, :ID_MN_RESI, :CLASSI_FIN, :NU_IDADE_N],
    filtro = r -> r[:SG_UF] == "26"))   # Pernambuco

# download multi-ano em paralelo
caminhos = baixar(:sim, "PE"; anos = 2019:2023)
for c in caminhos
    converter(c, replace(basename(c), ".dbc" => ".arrow");
              colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO])
end
```

## `ler` — referência

```julia
ler(caminho; colunas = nothing, filtro = nothing, tamanho_lote = 100_000,
    schema = :auto, encoding = :auto, pool = true) -> TabelaDBC
```

| kwarg | padrão | efeito |
|---|---|---|
| `colunas` | `nothing` (todas) | `Vector{Symbol}`; as demais nem são materializadas |
| `filtro` | `nothing` | `RegistroDBF -> Bool`, executa **antes** do parse; `r[:CAMPO]` decodifica só o campo consultado |
| `tamanho_lote` | `100_000` | linhas por partição — o teto de memória do pipeline |
| `schema` | `:auto` | deduzido do prefixo do arquivo; ou `:sim`/`:sinasc`/`:sih`/`:sia`/`:cnes`/`:sinan`, um `Dict{Symbol,Symbol}` próprio, ou `nothing` (só tipagem do DBF) |
| `encoding` | `:auto` | language driver do cabeçalho (DATASUS ⇒ `:cp850`); ou `:cp850`, `:latin1`, `:cp1252`, `:utf8` |
| `pool` | `true` | `PooledArray` nas categóricas do schema (equivalente ao factor do R) |

`TabelaDBC` é preguiçosa: nada é lido até a iteração. Implementa `Tables.partitions` (lotes) e `Tables.columns` (materialização via [`materializar`](#utilitários)), então funciona direto em `DataFrame(t)`, `Arrow.write(io, t)` etc.

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

`schema = :auto` deduz o sistema pelo prefixo do nome do arquivo:

| prefixo | sistema | exemplo |
|---|---|---|
| `DO` | `:sim` | `DOPE2023.dbc` |
| `DN` | `:sinasc` | `DNBA2022.dbc` |
| `RD`, `SP` | `:sih` | `RDPE2301.dbc` |
| `PA` | `:sia` | `PAPE2301.dbc` |
| `ST`, `LT`, `PF` | `:cnes` | `STPE2301.dbc` |
| `DENG`, `CHIK`, `ZIKA`, … | `:sinan` | `DENGBR20.dbc` |

Tipos lógicos disponíveis (para schemas próprios via `Dict`): `:texto`, `:pool`, `:inteiro`, `:float`, `:data_ddmmyyyy` (SIM/SINASC), `:data_yyyymmdd` (SIH e campos `D` do DBF), `:idade_sim`, `:idade_sinan`.

A `IDADE` do SIM (1º dígito = unidade, 2º–3º = valor) vira **anos**:

```julia
decodifica_idade_sim("425")   # 25.0
decodifica_idade_sim("501")   # 101.0  (5 ⇒ 100 + valor)
decodifica_idade_sim("310")   # 0.833… (10 meses)
decodifica_idade_sim("999")   # missing
```

Unidades: 0 = minutos, 1 = horas, 2 = dias, 3 = meses, 4 = anos, 5 = 100 + valor, 9 = ignorada.

O `NU_IDADE_N` do SINAN usa 4 dígitos (`decodifica_idade_sinan`): `"4025"` → 25.0, `"3006"` → 0.5, `"5010"` → 110.0.

Estenda schemas em tempo de execução:

```julia
MicroSUS.SCHEMAS[:sim][:LINHAA] = :texto    # campo agora tipado como texto
MicroSUS.SCHEMAS[:sim][:OCUP] = :pool       # muda para categórica
```

## Download e FTP

### `baixar` / `url_arquivo` — SIM, SINASC, SIH, SIA, CNES (por UF)

```julia
baixar(:sim, "PE"; ano = 2023)                     # um arquivo, com cache
baixar(:sim, "PE"; anos = 2013:2023)               # vários, em paralelo
baixar(:sih, "PE"; anos = [2023], meses = 1:12)    # mensal
url_arquivo(:sinasc, "BA"; ano = 2022)             # só a URL
MicroSUS.limpar_cache()                            # limpa o cache local
```

### `baixar_sinan` / `url_sinan` — SINAN (nacional, por agravo)

Arquivos do SINAN são **nacionais** (um `.dbc` por ano cobre o Brasil inteiro) — filtre UF/município de residência no `ler`:

```julia
baixar_sinan(:dengue; ano = 2024)              # DENGBR24.dbc
baixar_sinan(:zika; anos = 2016:2020)          # vários anos, paralelo
url_sinan(:meningite; ano = 2023)              # só a URL

# filtra um município específico no leitor
pe_dengue = DataFrame(ler(baixar_sinan(:dengue; ano = 2024);
    colunas = [:DT_NOTIFIC, :ID_MN_RESI, :CLASSI_FIN, :NU_IDADE_N],
    filtro = r -> r[:ID_MN_RESI] == "261110"))   # Petrolina/PE
```

Agravos disponíveis: `:dengue`, `:chikungunya`, `:zika`, `:malaria`, `:tuberculose`, `:hanseniase`, `:meningite`, `:violencia`, `:leishmaniose_visceral`, `:leishmaniose_tegumentar`, `:esquistossomose`, `:febre_tifoide`, `:hepatites`, `:intoxicacao_exogena`, `:acidente_animais`.

O SINAN finaliza com atraso; `baixar_sinan` tenta `FINAIS/` e cai automaticamente para `PRELIM/` se o consolidado não existir.

### `fetch_datasus` — tudo-em-um: download + leitura + concatenação

```julia
# SIM: óbitos em Pernambuco, 2019–2023 — já processados
do_pe = fetch_datasus(:SIM_DO; uf = "PE", anos = 2019:2023)

# SINASC: nascidos vivos em PE e BA, códigos brutos (sem processamento)
dn = fetch_datasus(:SINASC; uf = ["PE", "BA"], anos = 2022, processar = false)

# SIH: internações em PE, primeiro semestre de 2024
rd = fetch_datasus(:SIH_RD; uf = "PE", anos = 2024, meses = 1:6)

# SINAN: dengue no Brasil inteiro (fonte nacional: uf é ignorada)
dengue = fetch_datasus(:SINAN_DENGUE; anos = 2024)

# SIA: produção ambulatorial em SP, 2023
pa = fetch_datasus(:SIA_PA; uf = "SP", anos = 2023, meses = 1:12)
```

`fetch_datasus` concatena por nome de coluna (`cols = :union`), adiciona colunas de origem (`UF_ARQUIVO`, `ANO_ARQUIVO`, `MES_ARQUIVO`) e pula arquivos inexistentes com `@warn`. Use `fontes()` para listar todas as fontes disponíveis com seus identificadores, descrições, periodicidade e faixa de anos.

Caminhos atuais do FTP (conferidos contra o `microdatasus`, jul/2026):

| sistema | pasta | arquivo |
|---|---|---|
| `:sim` | `SIM/CID10/DORES/` | `DO{UF}{aaaa}.dbc` |
| `:sinasc` | `SINASC/1996_/Dados/DNRES/` | `DN{UF}{aaaa}.dbc` |
| `:sih` | `SIHSUS/200801_/Dados/` | `RD{UF}{aamm}.dbc` |
| `:sia` | `SIASUS/200801_/Dados/` | `PA{UF}{aamm}.dbc` |
| `:cnes` | `CNES/200508_/Dados/ST/` | `ST{UF}{aamm}.dbc` |
| SINAN | `SINAN/DADOS/FINAIS/` | `{AGRAVO}BR{aa}.dbc` (nacional — use `baixar_sinan`) |

**Dados preliminares**: se o arquivo consolidado não existir (anos recentes do SIM/SINASC), o `baixar` tenta automaticamente a pasta `PRELIM/` correspondente, com um `@warn` — indicador calculado sobre dado preliminar merece asterisco. `url_arquivo(...; prelim = true)` monta a URL preliminar diretamente.

**Limites de cobertura**: SINASC via helper cobre 1996+ (1994–1995 estão em `SINASC/1994_1995/` com outro padrão de nome — monte a URL manualmente); SIH/SIA cobrem a estrutura pós-2008.

## Dimensões auxiliares

```julia
dv_ibge(261110)               # 1 — dígito verificador (Petrolina)
codigo7_ibge(261110)          # 2611101 (SIM/SINASC usam 6 dígitos; IBGE, 7)
codigo6_ibge(2611101)         # 261110, validando o DV

# Capítulos da CID-10
capitulo_cid10("X954")        # (numeral = "XX", nome = "Causas externas …")
capitulo_cid10("I219")        # (numeral = "IX", nome = "Doenças do aparelho circulatório")

eh_agressao("X954")           # true — X85–Y09 + Y87.1 (recorte CVLI)
eh_agressao("Y10")            # false — intenção indeterminada
eh_agressao(missing)          # false

# Join típico IBGE → microdados
df.cod7 = codigo7_ibge.(String.(df.CODMUNRES))
leftjoin!(df, tabela_ibge; on = :cod7 => :codigo_municipio)
```

## Utilitários

```julia
materializar(t)                                  # todas as partições → NamedTuple
MicroSUS.cabecalho("DOPE2023.dbc")               # só o cabeçalho (campos, larguras, n)
descomprime_dbc_para_dbf("a.dbc", "a.dbf")       # dbc → dbf em streaming
dcl_descomprime(io, chunk -> ...)                # descompressor com sink genérico
dcl_descomprime(io)                              # ... ou materializado (testes)

# lista todas as fontes de dados disponíveis
fontes() |> DataFrame
```

## Notas de design

- **Encoding**: o language driver do cabeçalho DBF decide; `0x00` (não especificado) cai em CP850, que é a prática do DATASUS. Há um fast path ASCII — a transcodificação só custa quando há byte ≥ 0x80.
- **Texto**: colunas `C` viram `InlineStrings` dimensionadas pela largura do campo (sem ponteiro, sem pressão no GC); as categóricas do schema viram `PooledArray`. `pool = false` desliga.
- **Registros deletados** (flag `0x2A`) são pulados; o marcador de EOF do dBase (`0x1A`) é ignorado.
- **Arrow**: `converter` é uma extensão condicional (Julia ≥ 1.9); sem `using Arrow`, chamar `converter` lança `MethodError` com dica explicando o motivo.
- **Testes sem rede**: `runtests.jl` inclui um compressor DCL mínimo (literais, matches e código de fim, com os códigos canônicos emitidos na ordem de bits invertida do formato), que permite round-trip real do descompressor e DBC ≡ DBF sintéticos, incluindo travessias de janela de 4 KiB e CP850.

## Limitações conhecidas

- Sem paralelismo intra-arquivo (DCL é sequencial por natureza); paralelize entre arquivos (`baixar(...; anos = ...)` + tasks).
- Schemas cobrem os campos mais usados de cada sistema; campos fora do schema caem na tipagem do DBF (`N` → inteiro/float, `D` → data, `C` → texto). PRs de schema são bem-vindos.
- Tabelas de dimensão com *nomes* (municípios, CID-10 4-dígitos, CBO) estão fora do escopo do pacote — faça join com a DTB do IBGE.

## Licença

MIT
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

!!! tip "Nunca programou antes?"
    Comece pela página [Exemplos práticos (iniciantes)](exemplos.md):
    um passo a passo do zero, da instalação ao primeiro gráfico, com
    cada linha de código explicada.

## Instalação

```julia
using Pkg
Pkg.add("MicroSUS")
```

Julia ≥ 1.9. Dependências: DataFrames, Tables, InlineStrings,
PooledArrays, Scratch, Downloads, Dates. Arrow é opcional (extensão
condicional).

## Começo rápido

```julia
using MicroSUS, DataFrames

# download com cache local — não rebaixa o que já está no disco
caminho = baixar(:sim, "PE"; ano = 2023)

# totalmente tipado: datas → Date, a IDADE do SIM → anos, categóricas →
# PooledArray, texto → InlineStrings, CP850 → UTF-8
df = DataFrame(ler(caminho))

# seleção de colunas + filtro de linhas DENTRO DO LEITOR
t = ler(caminho;
        colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO],
        filtro  = r -> eh_agressao(r[:CAUSABAS]))   # CVLI: X85–Y09 + Y87.1
cvli = DataFrame(t)

# processamento em lotes, memória constante
using Tables
for lote in Tables.partitions(ler(caminho; tamanho_lote = 50_000))
    # `lote` é um NamedTuple de vetores — uma tabela Tables.jl válida
end

# .dbc → Arrow em streaming
using Arrow
converter(caminho, "do_pe_2023.arrow";
          colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES])
```

## Funções

### `fetch_datasus` — tudo em um: baixa, lê e concatena

A interface de mais alto nível: resolve a URL, baixa (com cache), lê,
concatena as partes e opcionalmente padroniza os códigos em rótulos
legíveis.

```julia
# óbitos de Pernambuco, 2019–2023, já padronizados
do_pe = fetch_datasus(:SIM_DO; uf = "PE", anos = 2019:2023)

# nascidos vivos de PE e BA, com os códigos brutos
dn = fetch_datasus(:SINASC; uf = ["PE", "BA"], anos = 2022, processar = false)

# internações hospitalares de PE no primeiro semestre de 2024
rd = fetch_datasus(:SIH_RD; uf = "PE", anos = 2024, meses = 1:6)

# dengue no Brasil inteiro (fonte nacional: uf é ignorada)
dengue = fetch_datasus(:SINAN_DENGUE; anos = 2024)
```

O resultado concatena por nome de coluna (`cols = :union`) e acrescenta
as colunas de origem `UF_ARQUIVO`, `ANO_ARQUIVO` e, nas fontes mensais,
`MES_ARQUIVO`. Arquivos ausentes no FTP geram `@warn` e são pulados.

Use [`fontes`](@ref) para listar todas as fontes disponíveis com seus
identificadores, descrições, periodicidade e faixa de anos, ou
[`fonte`](@ref) para inspecionar uma só:

```julia
fontes() |> DataFrame
fonte(:SIM_DO)
```

### `ler` — leitor de tabelas em streaming

Abre um `.dbc` ou `.dbf` como uma `TabelaDBC` preguiçosa. Nada é lido
até a iteração. A seleção de colunas e o filtro de linhas acontecem
**dentro do leitor**: colunas não pedidas nunca são materializadas, e o
filtro decodifica só o campo consultado antes de decidir se guarda a
linha.

```julia
ler(caminho)
ler(caminho; colunas = [:DTOBITO, :IDADE, :SEXO])
ler(caminho; filtro = r -> eh_agressao(r[:CAUSABAS]))
ler(caminho; schema = :auto, encoding = :cp850, pool = false)
ler(caminho; tamanho_lote = 50_000)
```

| kwarg | default | descrição |
|---|---|---|
| `colunas` | `nothing` (todas) | `Vector{Symbol}`; colunas fora da lista nunca são materializadas |
| `filtro` | `nothing` | `RegistroDBF -> Bool`, roda **antes** do parse das colunas |
| `tamanho_lote` | `100_000` | linhas por partição — o teto de memória do pipeline |
| `schema` | `:auto` | deduzido do prefixo do arquivo; ou `:sim`, `:sinasc`, `:sih`, `:sia`, `:cnes`, `:sinan`, um `Dict{Symbol,Symbol}` seu, ou `nothing` (só a tipagem do DBF) |
| `encoding` | `:auto` | language driver do cabeçalho (DATASUS ⇒ `:cp850`); ou `:cp850`, `:latin1`, `:cp1252`, `:utf8` |
| `pool` | `true` | `PooledArray` nas categóricas do schema |

Devolve uma [`TabelaDBC`](@ref) — uma tabela preguiçosa que implementa
`Tables.partitions` (lotes) e `Tables.columns` (materialização
completa). Funciona direto em `DataFrame(t)`, `Arrow.write(saida, t)` etc.

### `baixar` / `baixar_sinan` — download com cache

Baixam arquivos `.dbc` do servidor FTP do DATASUS com cache local
(Scratch.jl). Chamadas repetidas devolvem o caminho em cache, sem
rebaixar.

```julia
# SIM, SINASC, SIH, SIA, CNES — por UF
baixar(:sim, "PE"; ano = 2023)                     # um arquivo
baixar(:sim, "PE"; anos = 2013:2023)               # vários, em paralelo
baixar(:sih, "PE"; anos = [2023], meses = 1:12)    # mensal

# SINAN — arquivos nacionais (sem UF: filtre pela residência no `ler`)
baixar_sinan(:dengue; ano = 2024)                  # DENGBR24.dbc
baixar_sinan(:zika; anos = 2016:2020)              # vários anos, em paralelo
```

| Função | Sistema | Periodicidade |
|---|---|---|
| `baixar(:sim, uf)` | SIM (Mortalidade) | anual |
| `baixar(:sinasc, uf)` | SINASC (Nascidos Vivos) | anual |
| `baixar(:sih, uf)` | SIH (Hospitalar) | mensal |
| `baixar(:sia, uf)` | SIA (Ambulatorial) | mensal |
| `baixar(:cnes, uf)` | CNES (Estabelecimentos) | mensal |
| `baixar_sinan(agravo)` | SINAN (Agravos de notificação) | anual (nacional) |

As duas funções caem automaticamente nas pastas de dados preliminares
(`PRELIM/`) quando o arquivo consolidado ainda não existe, com um
`@warn`.

#### Agravos do SINAN

`:dengue`, `:chikungunya`, `:zika`, `:meningite`, `:tuberculose`,
`:hanseniase`, `:hepatites`, `:violencia`, `:leishmaniose_visceral`,
`:leishmaniose_tegumentar`, `:esquistossomose`, `:febre_tifoide`,
`:intoxicacao_exogena`, `:acidente_animais`

#### Funções de URL

```julia
url_arquivo(:sinasc, "BA"; ano = 2022)      # só a URL
url_arquivo(:sim, "PE"; ano = 2025, prelim = true)
url_sinan(:meningite; ano = 2023)
```

### `converter` — `.dbc` → Arrow em streaming

Converte `.dbc`/`.dbf` para Arrow em streaming (um *record batch* por
lote). Memória O(`tamanho_lote`). Requer `using Arrow`.

```julia
using Arrow
converter(caminho, "saida.arrow")
converter(caminho, "saida.arrow";
          colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES],
          filtro  = r -> eh_agressao(r[:CAUSABAS]))
```

### `materializar` — materializar as partições

Consome todas as partições e concatena as colunas num `NamedTuple` de
vetores. Equivale ao que `DataFrame(t)` chama internamente.

```julia
nt = materializar(ler(caminho))
```

### `descomprime_dbc_para_dbf` — DBC → DBF cru

Converte `.dbc` → `.dbf` em streaming (memória constante, equivalente
ao `dbc2dbf` do pacote R `read.dbc`).

```julia
descomprime_dbc_para_dbf("entrada.dbc", "saida.dbf")
```

### Padronização das fontes

[`process_sim`](@ref) e [`process_sinasc`](@ref) convertem os códigos
crus em rótulos legíveis, datas em texto em `Date` e numéricos
armazenados como texto em números. São chamados automaticamente por
[`fetch_datasus`](@ref) quando `processar = true` (o default).

```julia
df = fetch_datasus(:SIM_DO; uf = "PE", anos = 2023)   # já padronizado
bruto = fetch_datasus(:SIM_DO; uf = "PE", anos = 2023, processar = false)
padronizado = process_sim(bruto)                       # equivalente
```

No SIM isso rotula sexo, raça/cor, estado civil, escolaridade, local de
ocorrência e circunstância do óbito, e cria a coluna `IDADE_ANOS` em
anos completos. No SINASC, rotula tipo de parto, gravidez, escolaridade
e estado civil da mãe, consultas de pré-natal e local de nascimento.

### Decodificação de idade

#### `decodifica_idade_sim` / `decodifica_idade_sinan`

Convertem a codificação de idade do SIM (3 dígitos) ou do SINAN
(4 dígitos) para **anos**:

```julia
decodifica_idade_sim("425")   # 25.0
decodifica_idade_sim("501")   # 101.0
decodifica_idade_sim("310")   # 0.833… (10 meses)
decodifica_idade_sim("999")   # missing

decodifica_idade_sinan("4025")  # 25.0
decodifica_idade_sinan("5010")  # 110.0
```

| 1º dígito | unidade | exemplo (SIM) | anos |
|---|---|---|---|
| 0 | minutos | `"030"` | 30 / 525 960 |
| 1 | horas | `"112"` | 12 / 8 766 |
| 2 | dias | `"230"` | 30 / 365,25 |
| 3 | meses | `"310"` | 10 / 12 |
| 4 | anos | `"425"` | 25,0 |
| 5 | 100 + valor | `"501"` | 101,0 |
| 9 | ignorada | `"999"` | `missing` |

### Códigos de município do IBGE

```julia
dv_ibge(261110)               # 1 (dígito verificador)
codigo7_ibge(261110)          # 2611101 (SIM/SINASC usam 6; o IBGE, 7)
codigo6_ibge(2611101)         # 261110, validando o DV
```

### Capítulos da CID-10

```julia
capitulo_cid10("X954")        # (numeral="XX", nome="Causas externas …")
capitulo_cid10("I219")        # (numeral="IX", nome="Doenças do aparelho circulatório")
eh_agressao("X954")           # true — X85–Y09 + Y87.1 (recorte CVLI)
eh_agressao("Y10")            # false — intenção indeterminada
```

### Baixo nível

```julia
dcl_descomprime(io, chunk -> processar(chunk))   # descompressor streaming
MicroSUS.cabecalho("arquivo.dbc")                 # só o cabeçalho (campos, larguras)
MicroSUS.limpar_cache()                           # limpa o cache de download
```

## Compatibilidade com Tables.jl

Todas as funções de leitura produzem objetos [`TabelaDBC`](@ref), que
implementam a interface [Tables.jl](https://github.com/JuliaData/Tables.jl).
Ou seja, funcionam direto com DataFrames, Arrow, CSV e qualquer outro
consumidor de Tables.jl:

```julia
using DataFrames, Arrow

# DataFrame
df = DataFrame(ler(caminho))

# Arrow
Arrow.write("saida.arrow", ler(caminho))

# iterar em lotes
for lote in Tables.partitions(ler(caminho))
    # `lote` é um NamedTuple de vetores
end
```

## Arquitetura do streaming

```
.dbc ──DCL 4KiB/chunk──▶ registros ──filtro──▶ parse tipado ──▶ lotes
                         (crus)      (sob        (só as         (NamedTuple,
                                      demanda)    colunas        Tables.jl)
                                                  pedidas)
```

O formato `.dbc` é um cabeçalho DBF em claro + 4 bytes de CRC +
registros comprimidos em PKWare DCL. O descompressor é um porte puro
Julia do `blast.c` de Mark Adler, com a janela de 4 KiB emitida por um
callback `sink` — é isso que permite a leitura com memória constante,
qualquer que seja o tamanho do arquivo.

Cada estágio é encadeado por `Channel`s com buffers pequenos: o
*backpressure* é automático. Se o consumidor (seu laço `for` ou o
`Arrow.write`) desacelera, a descompressão espera. O teto de memória é
`O(tamanho_lote)` — o lote em construção mais um em trânsito —
independente do tamanho do arquivo original.

## Referência da API

Veja a página [Referência da API](api.md) para a lista completa das funções
e tipos exportados, com assinaturas e docstrings. Para detalhes de
implementação, veja [Internos](internos.md).

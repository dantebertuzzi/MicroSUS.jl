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

O resultado concatena por nome de coluna e acrescenta as colunas de
origem `UF_ARQUIVO`, `ANO_ARQUIVO`, `PRELIMINAR` e, nas fontes mensais,
`MES_ARQUIVO`. Arquivos ausentes no FTP geram `@warn` e são pulados.

Os arquivos são lidos em streaming e a padronização roda no próprio
resultado, sem cópia — o SIM de PE 2014–2023 (675 mil óbitos, 92
colunas) chega a 3,4 GiB de pico, contra 5,9 GiB antes. `colunas` e
`filtro` vão para o leitor, como em [`ler`](@ref), e aí só o que foi
pedido chega a existir:

```julia
cvli = fetch_datasus(:SIM_DO; uf = "PE", anos = 2014:2023,
                     colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES],
                     filtro = r -> eh_agressao(r[:CAUSABAS]))   # 580 MiB de pico
```

O filtro vê os códigos crus do arquivo (`r[:SEXO] == "2"`), não os
rótulos da padronização.

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

#### Vários arquivos

Um vetor de caminhos vira uma tabela só, ainda em streaming: os lotes
saem de um arquivo depois do outro, e a memória continua
O(`tamanho_lote`) — dez anos de SIM passam como passaria um.

```julia
caminhos = baixar(:sim, "PE"; anos = 2014:2023)
t = ler(caminhos; colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES],
        filtro = r -> eh_agressao(r[:CAUSABAS]))
cvli = DataFrame(t)        # + coluna :ARQUIVO ("DOPE2014.dbc", …)
```

Os kwargs de sempre valem para cada arquivo. Dois a mais:

| kwarg | default | descrição |
|---|---|---|
| `uniao` | `false` | com `false`, arquivos com colunas diferentes são erro (a mensagem diz quais faltam onde); com `true`, a saída tem a união e as que faltam num arquivo vêm `missing` |
| `origem` | `:ARQUIVO` | nome da coluna com o arquivo de cada linha; `nothing` para não criar |

Os tipos são unificados por coluna — o DATASUS alarga campos e troca o
tipo DBF de alguns entre anos —, então todo lote sai com o mesmo
schema, como o Arrow exige. Devolve uma [`TabelaConcatenada`](@ref).

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

São 48 — a tabela completa, com o ano inicial de cada um, está no
[guia de download](guia/download.md). [`agravos_sinan`](@ref) devolve a mesma
lista, e cada agravo é também uma fonte de [`fetch_datasus`](@ref):

```julia
DataFrame(agravos_sinan())
sc = fetch_datasus(:SINAN_SIFILIS_CONGENITA; anos = 2022)   # = baixar_sinan(:sifilis_congenita; ano = 2022)
```

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

# vários arquivos num .arrow só, com schema unificado
converter(baixar(:sih, "PE"; anos = 2010:2016, meses = 1:12), "rd_pe.arrow";
          colunas = [:DIAG_PRINC, :DIAGSEC1, :VAL_TOT],
          ignorar_ausentes = true, uniao = true)   # DIAGSEC1 só existe a partir de 2011
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

[`process_sinan`](@ref) rotula o núcleo comum às fichas de notificação
(tipo de notificação, sexo, raça/cor, gestação, escolaridade,
hospitalização) e cria `IDADE_ANOS`. Classificação final, critério e
evolução mudam de sentido entre agravos e só são rotulados para dengue,
chikungunya e zika:

```julia
dg = fetch_datasus(:SINAN_DENGUE; anos = 2024)        # agravo = :dengue
combine(groupby(dg, :CLASSI_FIN), nrow)  # "Dengue", "Dengue grave", "Descartado", …

zk = fetch_datasus(:SINAN_ZIKA; anos = 2023, processar = false)
process_sinan(zk; agravo = :zika)                      # explícito
```

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

### UF, região e município

Tabela do IBGE embarcada no pacote — não consulta a rede:

```julia
uf_de("261160")               # "PE" (6 ou 7 dígitos, texto ou inteiro)
regiao("PE")                  # "Nordeste"; também aceita código: regiao(2611606)
municipio("261160")           # (codigo7=2611606, codigo6=261160, nome="Recife",
                              #  uf="PE", regiao="Nordeste"); `nothing` se ignorado
DataFrame(municipios())       # 5.571 linhas, para leftjoin por codigo6
```

Nove municípios têm dígito verificador oficial fora do algoritmo
(Quixaba-PE é 2611533, não 2611531): `codigo7_ibge` e `codigo6_ibge` usam o
da tabela.

### Populações — o denominador das taxas

[`populacao`](@ref) traz a população residente do IBGE (API SIDRA, com
cache local) por município, UF ou Brasil, de 2000 em diante. O `codigo6`
casa com `CODMUNRES` (SIM, SINASC) e `MUNIC_RES` (SIH):

```julia
using DataFrames
pop = DataFrame(populacao(2022))   # codigo7, codigo6, nome, ano, populacao, fonte

do22 = DataFrame(ler(baixar(:sim, "PE"; ano = 2022);
                     colunas = [:CAUSABAS, :CODMUNRES],
                     filtro = r -> eh_agressao(r[:CAUSABAS])))
n = combine(groupby(do22, :CODMUNRES), nrow => :obitos)
n.codigo6 = parse.(Int, n.CODMUNRES)
taxas = innerjoin(n, pop; on = :codigo6)
taxas.por_100mil = 100_000 .* taxas.obitos ./ taxas.populacao
```

A série **não é homogênea**: cada ano vem do Censo (2000, 2010, 2022), da
Contagem (2007) ou da estimativa anual (os demais), e a coluna `fonte` diz
qual. As estimativas de 2011–2021 superestimaram a população — o Censo
2022 achou 203,1 milhões contra 213,3 milhões estimados para 2021. No
Recife, os óbitos por agressão caíram de 655 para 636 de 2021 para 2022,
mas a taxa *subiu* de 39,4 para 42,7 por 100 mil, só pela troca de
denominador (1.661.017 → 1.488.920). Com a população do Censo nos dois
anos, 2021 daria 44,0, e a queda apareceria.

O IBGE não publicou população para 2023: pedir esse ano é erro, a menos
que `interpolar = true` (interpolação geométrica entre 2022 e 2024,
registrada em `fonte`).

### Capítulos da CID-10

```julia
capitulo_cid10("X954")        # (numeral="XX", nome="Causas externas …")
capitulo_cid10("I219")        # (numeral="IX", nome="Doenças do aparelho circulatório")
eh_agressao("X954")           # true — X85–Y09 + Y87.1 (recorte CVLI)
eh_agressao("Y10")            # false — intenção indeterminada
```

### Busca de CID-10

Alvos são prefixos (`"A81"`, `"A810"`) ou faixas de categorias
(`"X85" => "Y09"`); pontos, espaços e caixa são normalizados.

```julia
dcj = ["A810", "F021"]                      # Creutzfeldt-Jakob
cid_casa("A81.0", dcj)                      # true
cid_casa("J189", "J12" => "J18")            # true — pneumonias
cids_em("*I219*E149")                       # ["I219", "E149"]

# causa básica OU qualquer linha da DO (causas múltiplas), no próprio reader
linhas = (:LINHAA, :LINHAB, :LINHAC, :LINHAD, :LINHAII)
t = ler(caminho; colunas = [:CAUSABAS, :CODMUNRES, linhas...],
        filtro = r -> cid_casa(r[:CAUSABAS], dcj) ||
                      any(l -> menciona_cid(r[l], dcj), linhas))
```

### Baixo nível

```julia
dcl_descomprime(io, chunk -> processar(chunk))   # descompressor streaming
cabecalho("arquivo.dbc")                 # só o cabeçalho (campos, larguras)
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

## Isenção de responsabilidade

O MicroSUS.jl é uma **ferramenta de leitura**, não uma fonte de dados. Ele
baixa e decodifica arquivos publicados pelo DATASUS/Ministério da Saúde; o
conteúdo, a exatidão e a completude desses arquivos são de responsabilidade do
órgão que os publica.

- O DATASUS **republica bases retroativamente**: a mesma consulta em datas
  diferentes pode devolver números diferentes. Registre a data de extração.
- Dados **preliminares** existem e são sinalizados: `@warn` quando o `baixar`
  cai numa pasta `PRELIM/`, [`eh_preliminar`](@ref) para cada arquivo e a
  coluna `PRELIMINAR` no resultado de [`fetch_datasus`](@ref).
- Os microdados têm **defeitos próprios** — códigos implausíveis, campos que
  deixam de ser preenchidos no meio de uma série, layouts que mudam entre anos.
  Os que conhecemos estão em [Exemplos intermediários](exemplos-intermediarios.md)
  e no guia de [Schemas e tipagem](guia/schemas.md); a lista não é exaustiva.

O software é distribuído **como está**, sob licença MIT, sem garantia de
qualquer espécie e sem responsabilidade por danos decorrentes do uso. Validar
os resultados, conferir a plausibilidade dos números e responder pelas
conclusões publicadas é de quem faz a análise.

## Referência da API

Veja a página [Referência da API](api.md) para a lista completa das funções
e tipos exportados, com assinaturas e docstrings. Para detalhes de
implementação, veja [Internos](internos.md).

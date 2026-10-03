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
PooledArrays, Scratch, Downloads, Dates, SHA. Arrow é opcional (extensão
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

Com mais de uma thread (`julia -t auto`), os arquivos seguintes são lidos
enquanto o atual é consumido, e a saída continua na mesma ordem: os 10
anos do SIM de PE caem de 4,3 s para 1,9 s com 4 threads e 1,4 s com 8.
As colunas de cada lote também são convertidas em paralelo, o que vale
para um arquivo só: o `DENGBR23` (1,6 milhão de registros) cai de 5,8 s
para 3,3 s com 4 threads. Com uma thread só, a leitura é a sequencial de
sempre.

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
                              #  uf="PE", regiao="Nordeste", …); `nothing` se ignorado
municipio("261160").regiao_saude   # "I Região de Saúde"
DataFrame(municipios())       # 5.571 linhas, para leftjoin por codigo6
```

Cada município traz também as divisões abaixo da UF, com código e nome: a
**região de saúde** (CIR, 439) e a **macrorregião de saúde** (121), do
DATASUS, e as **regiões imediata e intermediária** do IBGE (510 e 133). Os
nomes se repetem entre UFs; agrupe pelo código.

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

#### Por região de saúde

Município pequeno dá taxa instável; UF esconde as diferenças internas. A
região de saúde — o recorte em que o SUS organiza a rede — fica no meio.
`populacao` soma os municípios com `nivel = :regiao_saude` (ou
`:macrorregiao_saude`, `:regiao_imediata`, `:regiao_intermediaria`), e a
coluna de código tem o mesmo nome que em `municipios()`:

```julia
mun = DataFrame(municipios())
do22.codigo6 = parse.(Int, do22.CODMUNRES)
leftjoin!(do22, mun[:, [:codigo6, :codigo_regiao_saude]]; on = :codigo6)
n = combine(groupby(dropmissing(do22, :codigo_regiao_saude), :codigo_regiao_saude),
            nrow => :obitos)
t = innerjoin(n, DataFrame(populacao(2022; nivel = :regiao_saude)); on = :codigo_regiao_saude)
t.por_100mil = 100_000 .* t.obitos ./ t.populacao
```

Em Pernambuco, os óbitos por agressão de 2022 vão de 54,8 por 100 mil na
III Região de Saúde (Mata Sul) a 13,4 na VII (Sertão Central); a I, que
contém o Recife, fica em 39,6 — e a UF inteira, em 37,7. (Os 73 óbitos com
município ignorado ficam fora: o `dropmissing`.)

#### Por sexo e idade, e taxas padronizadas

Uma população envelhecida tem mais óbitos sem ter mais risco. Para
comparar lugares com estruturas etárias diferentes, a taxa padronizada
pergunta quanto seria a taxa de cada um se todos tivessem a mesma
estrutura — a de uma população-padrão. Mortalidade geral em 2022,
padronizada pela população do Brasil no Censo 2022:

| UF | óbitos | abaixo de 30 anos | taxa bruta | padronizada por idade |
|---|---|---|---|---|
| Amazonas | 20.155 | 54% | 510 /100 mil | 776 /100 mil |
| Rio Grande do Sul | 104.096 | 38% | 956 /100 mil | 795 /100 mil |

O RS parece ter quase o dobro da mortalidade do AM; padronizadas, as duas
taxas ficam próximas — a diferença bruta era a idade da população.

```julia
using DataFrames
pop = DataFrame(populacao_por_idade(2022; nivel = :uf))          # sexo × faixa, por UF
br  = combine(groupby(DataFrame(populacao_por_idade(2022; nivel = :brasil)),
                      [:faixa, :idade_min]), :populacao => sum => :padrao)

do_am = fetch_datasus(:SIM_DO; uf = "AM", anos = 2022, colunas = [:IDADE])
do_am.faixa = faixa_etaria.(do_am.IDADE_ANOS)                    # mesmas faixas
casos = combine(groupby(dropmissing(do_am, :faixa), :faixa), nrow => :casos)
am = combine(groupby(pop[pop.codigo_uf .== 13, :], :faixa), :populacao => sum => :populacao)

t = sort!(leftjoin(leftjoin(br, am; on = :faixa), casos; on = :faixa), :idade_min)
t.casos = coalesce.(t.casos, 0)
taxa_padronizada(t.casos, t.populacao, t.padrao)   # (taxa = 776.2, bruta = 509.8, erro_padrao = 5.7, …)
```

[`populacao_por_idade`](@ref) vem dos Censos (2010, 2022 — até o
município) e, nos demais anos, da projeção da população revista em 2018
(Brasil e UFs), que é anterior ao Censo 2022 e está marcada na coluna
`fonte`. A soma das faixas bate com o total oficial dos Censos. A taxa
bruta acima conta só os óbitos com idade conhecida (61 de 20.155 no AM
não têm).

### Indicadores de mortalidade

Quatro indicadores clássicos, por local de residência e ano do evento, como
a RIPSA os define, em qualquer nível territorial (`:brasil`, `:uf`,
`:municipio`, `:regiao_saude` e os demais):

```julia
do22 = fetch_datasus(:SIM_DO; uf = "PE", anos = 2022)
dn22 = fetch_datasus(:SINASC; uf = "PE", anos = 2022)

mortalidade_infantil(do22, dn22; nivel = :regiao_saude)   # e os três componentes
razao_mortalidade_materna(do22, dn22)
proporcao_mal_definidas(do22)
mortalidade_prematura_dcnt(do22)          # 30–69 anos; população da SIDRA
```

Conferidos contra o TabNet do DATASUS, para Pernambuco em 2022 — as
contagens batem exatamente:

| | MicroSUS | TabNet |
|---|--:|--:|
| nascidos vivos (residência) | 117.437 | 117.437 |
| óbitos infantis | 1.558 | 1.558 |
| 0–6 / 7–27 / 28–364 dias | 801 / 245 / 512 | 801 / 245 / 512 |
| óbitos maternos (sem os tardios, O96) | 54 | 54 |
| óbitos | 72.011 | 72.011 |
| causas mal definidas (R00–R99) | 3.817 | 3.817 |
| óbitos por DCNT de 30 a 69 anos | 14.533 | 14.533 |

Daí, mortalidade infantil de 13,27 por mil, razão de mortalidade materna de
46,0 por 100 mil nascidos vivos, 5,3% de causas mal definidas e 324,6
óbitos prematuros por DCNT por 100 mil habitantes de 30 a 69 anos. Os
óbitos infantis batem também nas 12 regiões de saúde.

São taxas pelo **método direto**, sem os fatores de correção de
sub-registro que o Ministério da Saúde aplica à mortalidade infantil e à
materna onde a cobertura do SIM e do SINASC é incompleta: nessas UFs, a taxa
oficial fica acima desta. Em territórios pequenos as taxas oscilam muito de
um ano para o outro — agregue anos ou use um nível maior.

### Capítulos da CID-10

```julia
capitulo_cid10("X954")        # (numeral="XX", nome="Causas externas …")
capitulo_cid10("I219")        # (numeral="IX", nome="Doenças do aparelho circulatório")
descricao_cid("I219")         # "Infarto agudo do miocárdio não especificado"
cid10("I21.9").grupo          # "Doenças isquêmicas do coração"
descricao_cid.(df.CAUSABAS)   # rotula uma coluna inteira (334 mil causas em 0,13 s)
eh_agressao("X954")           # true — X85–Y09 + Y87.1 (recorte CVLI)
eh_agressao("Y10")            # false — intenção indeterminada
```

A tabela é a do DATASUS (versão 2008, a última publicada em CSV), embarcada
no pacote, mais a dengue (A97) da atualização da OMS de 2016. Códigos
posteriores a 2008 recebem a descrição da categoria — `cid10` diz isso em
`nivel`. Nos 20,6 milhões de óbitos do SIM de 2010–2024, só 28 ficam sem
descrição. `cid10` também traz a restrição de sexo do código e se ele é
válido como causa básica de óbito.

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

### Auditoria de qualidade

O DATASUS não usa `missing`: a ausência vem codificada, campos param de ser
preenchidos no meio de uma série, e parte das causas básicas não informa a
causa de fato. Nada disso aparece num `describe`. [`auditar`](@ref) junta as
checagens:

```julia
df = fetch_datasus(:SIM_DO; uf = "PE", anos = 2014:2023)
auditar(df)
```

```
Auditoria — 675806 registros, 2014–2023 (ano de ANO_ARQUIVO)

  Completude: 89 colunas; 17 sempre preenchidas, 3 sempre vazias
    OBITOPUERP     0.1%
    EXAME          0.1%
    …

  Descontinuidades: 2 (campo que muda de preenchimento entre anos)
    FONTESINF   2014→2015: 100.0% → 0.0%
    CRM         2018→2019: 97.3% → 0.0%

  Causas básicas: 4.1% mal definidas (R00–R99), 0.1% com código que não vale como causa básica

  Valores implausíveis:
    idade acima de 120 anos ou negativa (IDADE_ANOS): 4
    peso fora de 100–7.000 g (PESO): 7
    semanas de gestação fora de 20–45 (SEMAGESTAC): 512
```

Em Pernambuco, o CRM do médico atestante deixa de vir nos arquivos a partir
de 2019 — uma análise que dependa dele quebra ali sem erro nenhum. Os detalhes
ficam nos campos: `a.completude` (por coluna e ano), `a.descontinuidades`,
`a.causas` (mal definidas e códigos que não valem como causa básica, por ano)
e `a.implausiveis` (com as primeiras linhas de cada regra em `exemplos`). Os
códigos de "ignorado" só contam como ausência nos dados padronizados, onde
viram `missing`.

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

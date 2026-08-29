# MicroSUS.jl

<div align="center">
  <img src="https://raw.githubusercontent.com/dantebertuzzi/MicroSUS.jl/refs/heads/main/logo_microsus.png" alt="Logo" width="200">
  <br>
  <em>Microdados do DATASUS em Julia — 🇧🇷</em>
  <br>
  <em>See <a href="README.md">README.md</a> for the English version.</em>
  <br>
  <a href="https://doi.org/10.5281/zenodo.22164178"><img src="https://zenodo.org/badge/DOI/10.5281/zenodo.22164178.svg" alt="DOI"></a>
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

```bash
# opcional: também exercita cada fonte registrada (fontes()) contra o
# FTP real do DATASUS
MicroSUS_TEST_NETWORK=true julia --project -e 'using Pkg; Pkg.test()'
```

Documentação completa (Documenter.jl):

```bash
julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
julia --project=docs docs/make.jl     # saída em docs/build/index.html
```

Documentação: **[dantebertuzzi.github.io/MicroSUS.jl](https://dantebertuzzi.github.io/MicroSUS.jl/)** — comece pelos [Exemplos práticos (iniciantes)](https://dantebertuzzi.github.io/MicroSUS.jl/dev/exemplos/) se for a sua primeira vez. Histórico de versões em [CHANGELOG.md](CHANGELOG.md).

Julia ≥ 1.9 (extensões condicionais). Dependências: DataFrames, Tables, InlineStrings, PooledArrays, Scratch, Downloads, Dates. Arrow é opcional (weak dep).

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

> **Malária**: o arquivo do SINAN cobre apenas a notificação **extra-amazônica**. Os casos da região amazônica — a grande maioria — são notificados no SIVEP-Malária, que não faz parte do SINAN e não é servido por este FTP. Um `MALABR{aa}.dbc` de poucas centenas de KB é o esperado, não um download truncado.

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

`fetch_datasus` concatena por nome de coluna (`cols = :union`), adiciona colunas de origem (`UF_ARQUIVO`, `ANO_ARQUIVO`, `MES_ARQUIVO`) e pula arquivos inexistentes com `@warn`. Use `fontes()` para listar todas as fontes disponíveis com seus identificadores, descrições, periodicidade e faixa de anos, ou `fonte(:SIM_DO)` para inspecionar uma só.

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

## Padronização: `process_sim` / `process_sinasc` / `process_sih`

`fetch_datasus` chama a rotina de padronização da fonte por padrão
(`processar = true`). Ela troca códigos por rótulos legíveis, converte datas
em texto para `Date` e numéricos guardados como texto para número:

```julia
df = fetch_datasus(:SIM_DO; uf = "PE", anos = 2023)          # já padronizado
bruto = fetch_datasus(:SIM_DO; uf = "PE", anos = 2023, processar = false)
process_sim(bruto)                                            # equivalente
```

No SIM: rotula `SEXO`, `RACACOR`, `ESTCIV`, `ESC`, `LOCOCOR`, `CIRCOBITO` e
afins, e cria `IDADE_ANOS` em anos completos. No SINASC: `PARTO`, `GRAVIDEZ`,
`ESCMAE`, `ESTCIVMAE`, `CONSULTAS`, `LOCNASC`, `RACACOR`. No SIH: `SEXO`,
`RACA_COR`, `IDENT`, `CAR_INT`, e `IDADE_ANOS` a partir do par `IDADE` +
`COD_IDADE`.

> **Atenção ao SIH**: `SEXO` usa 1 = Masculino e **3** = Feminino (no SIM é 1 e
> 2), e `RACA_COR` usa `01`–`05` + `99` (no SIM é `1`–`5`, e "Parda" é `4`, não
> `03`). Reaproveitar dicionário entre os dois sistemas produz rótulo errado sem
> erro nenhum.

`COBRANCA` e `ESPEC` ficam crus de propósito: têm domínio extenso e variável
entre versões da tabela da AIH, e como código não mapeado vira `missing`, um
dicionário incompleto apagaria dados válidos em silêncio.

Colunas ausentes no layout do ano são ignoradas em silêncio — o layout do
DATASUS muda entre anos, e a rotina é escrita para sobreviver a isso. As demais
fontes (SIH, SIA, CNES, SINAN) ainda não têm rotina: devolvem os códigos brutos
com um `@info`.

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

## Isenção de responsabilidade

O MicroSUS.jl é uma **ferramenta de leitura**, não uma fonte de dados. Ele
baixa e decodifica arquivos publicados pelo DATASUS/Ministério da Saúde; o
conteúdo, a exatidão e a completude desses arquivos são de responsabilidade do
órgão que os publica, não deste projeto.

Três consequências práticas:

- **O DATASUS republica bases retroativamente.** A mesma consulta em datas
  diferentes pode devolver números diferentes. Registre a data de extração
  (ver [Como citar](#como-citar)).
- **Dados preliminares existem e são sinalizados.** Quando o `baixar` cai numa
  pasta `PRELIM/`, ele emite `@warn`. Indicador calculado sobre dado
  preliminar merece asterisco.
- **Os microdados têm defeitos próprios.** Códigos implausíveis, campos que
  deixam de ser preenchidos no meio de uma série, layouts que mudam entre anos.
  A documentação registra os que conhecemos — ver
  [Exemplos intermediários](https://dantebertuzzi.github.io/MicroSUS.jl/dev/exemplos-intermediarios/)
  e o [CHANGELOG](CHANGELOG.md) —, mas a lista não é exaustiva.

O software é distribuído **como está**, sob [licença MIT](LICENSE), sem
garantia de qualquer espécie e sem responsabilidade por danos decorrentes do
uso. Validar os resultados, conferir a plausibilidade dos números e responder
pelas conclusões publicadas é de quem faz a análise.

Encontrou um defeito? [Abra uma issue](https://github.com/dantebertuzzi/MicroSUS.jl/issues) —
é assim que a lista de armadilhas conhecidas cresce.

## Como citar

Se o MicroSUS.jl entrou no seu fluxo de análise, cite **duas coisas
separadamente**: o software e os dados. São objetos distintos, com
responsabilidades distintas — o pacote responde pela leitura e tipagem, o
DATASUS responde pelo conteúdo.

### 1. O software

O repositório traz um [`CITATION.cff`](CITATION.cff), que o GitHub lê
nativamente: o botão **"Cite this repository"**, na barra lateral da página do
projeto, gera APA e BibTeX prontos. Há também um [`CITATION.bib`](CITATION.bib)
para quem prefere pegar o BibTeX direto:

```bibtex
@software{bertuzzi_microsus_2026,
  author  = {Bertuzzi, Dante},
  title   = {{MicroSUS.jl}: streaming reader for {DATASUS} public health microdata in {Julia}},
  year    = {2026},
  version = {0.3.0},
  doi     = {10.5281/zenodo.22164179},
  url     = {https://github.com/dantebertuzzi/MicroSUS.jl},
  note    = {Julia package}
}
```

**Cite a versão que você usou**, não "a última". Os resultados dependem dela: a
0.2.1, por exemplo, corrigiu um defeito que devolvia colunas de data vazias no
SIM. Rode `pkg> status MicroSUS` e use o número que aparecer.

### 2. Os dados do DATASUS

O DATASUS é a fonte primária e precisa ser citado como tal, com **a data de
extração** — as bases são republicadas retroativamente, e a mesma consulta feita
em datas diferentes pode devolver números diferentes. No formato ABNT
(NBR 6023), a forma usual é:

> BRASIL. Ministério da Saúde. DATASUS. *Sistema de Informações sobre
> Mortalidade (SIM)*: microdados. Brasília: Ministério da Saúde, 2023.
> Disponível em: https://datasus.saude.gov.br. Acesso em: 29 ago. 2026.

Troque o sistema pelo que você usou (SIM, SINASC, SIH/SUS, SIA/SUS, CNES,
SINAN) e a data de acesso pela sua.

### 3. Reprodutibilidade

Para que outra pessoa chegue ao seu número, registre no artigo ou no material
suplementar:

- a **versão do MicroSUS.jl** e do Julia;
- o `Project.toml` e o `Manifest.toml` do ambiente — o `Manifest.toml` fixa a
  árvore inteira de dependências e é o que torna o ambiente reconstituível com
  `Pkg.instantiate()`;
- a **data de extração** dos arquivos do DATASUS;
- se você usou dados **preliminares** (`PRELIM/`), diga — o `baixar` avisa com
  `@warn` quando cai nessa pasta.

### As normas por trás disso

O que sustenta as recomendações acima:

| Norma | O que estabelece |
|---|---|
| [FORCE11 — Software Citation Principles](https://force11.org/info/software-citation-principles-published-2016/) | Software é produto de pesquisa citável. Os seis princípios: importância, crédito, identificação unívoca, persistência, acessibilidade e **especificidade** (citar a versão exata). |
| [Citation File Format (CFF) 1.2.0](https://citation-file-format.github.io/) | Formato legível por máquina para metadados de citação. É o que o GitHub e o Zenodo consomem. |
| ABNT NBR 6023:2018 | Referências em publicações brasileiras. Cobre documento eletrônico e exige `Disponível em` + `Acesso em`. |
| [Zenodo + GitHub](https://docs.github.com/en/repositories/archiving-a-github-repository/referencing-and-citing-content) | Emite DOI persistente por release, mais um *concept DOI* que sempre aponta para a versão mais recente. |

**Os DOIs deste projeto**: o repositório está conectado ao
[Zenodo](https://zenodo.org), então cada release é arquivada e recebe um
identificador persistente — a citação deixa de depender de a URL do GitHub
sobreviver a uma mudança de nome ou de dono. Existem dois DOIs, e eles não são
intercambiáveis:

| DOI | O que identifica |
|---|---|
| [10.5281/zenodo.22164178](https://doi.org/10.5281/zenodo.22164178) | *Concept DOI* — o projeto como um todo. Resolve sempre para a versão mais recente; é o que o badge no topo deste README aponta. |
| [10.5281/zenodo.22164179](https://doi.org/10.5281/zenodo.22164179) | A versão 0.3.0, congelada. Cada release futura ganha o seu. |

**No artigo, cite o DOI da versão**, não o do conceito: o concept DOI diz qual
projeto você usou, o DOI da versão diz qual código de fato rodou.

## Licença

MIT
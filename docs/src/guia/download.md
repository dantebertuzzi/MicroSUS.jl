```@meta
CurrentModule = MicroSUS
```

# Download e FTP

## `baixar`

```julia
caminho  = baixar(:sim, "PE"; ano = 2023)              # um arquivo
caminhos = baixar(:sim, "PE"; anos = 2013:2023)        # vários, em paralelo
caminhos = baixar(:sih, "PE"; anos = [2023], meses = 1:12)
```

- **Cache local** via Scratch.jl: chamadas repetidas devolvem o caminho
  já baixado sem tocar na rede. `forcar = true` ignora o cache;
  `quieto = true` silencia os `@info`.
- A forma plural baixa em paralelo (`asyncmap`, 4 conexões) e devolve os
  caminhos na ordem dos períodos.
- Downloads interrompidos não poluem o cache (grava em `.part` + `mv`
  atômico).
- `MicroSUS.limpar_cache()` apaga tudo.

## Caminhos no FTP

Conferidos contra o `microdatasus` (jul/2026) — o FTP do DATASUS já
mudou de estrutura outras vezes, e é a primeira coisa a checar quando um
download falha com `550`:

| sistema | pasta | arquivo |
|---|---|---|
| `:sim` | `SIM/CID10/DORES/` | `DO{UF}{aaaa}.dbc` |
| `:sinasc` | `SINASC/1996_/Dados/DNRES/` | `DN{UF}{aaaa}.dbc` |
| `:sih` | `SIHSUS/200801_/Dados/` | `RD{UF}{aamm}.dbc` |
| `:sia` | `SIASUS/200801_/Dados/` | `PA{UF}{aamm}.dbc` |
| `:cnes` | `CNES/200508_/Dados/ST/` | `ST{UF}{aamm}.dbc` |

[`url_arquivo`](@ref) monta a URL sem baixar:

```julia
url_arquivo(:sinasc, "BA"; ano = 2022)
# "ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/1996_/Dados/DNRES/DNBA2022.dbc"
```

## SINAN (agravos de notificação)

Dengue, chikungunya, zika, tuberculose, hanseníase e outros agravos vêm
do SINAN, cujos arquivos são **nacionais** (um `.dbc` cobre o Brasil
inteiro) — por isso a API é por *agravo*, não por UF. Filtre pela UF de
residência no leitor.

```julia
caminho  = baixar_sinan(:dengue; ano = 2020)      # DENGBR20.dbc, nacional
caminhos = baixar_sinan(:zika; anos = 2016:2020)  # vários anos, em paralelo

# só Pernambuco, filtrando no leitor (SG_UF = UF de residência)
pe = DataFrame(ler(caminho; filtro = r -> strip(r[:SG_UF]) == "26"))
```

Os agravos disponíveis estão na tabela abaixo e em `agravos_sinan()`. O schema `:sinan`
tipa o núcleo comum das fichas de notificação (datas, localidade,
`NU_IDADE_N` → anos, `CLASSI_FIN`, `CRITERIO`, `EVOLUCAO`); os campos
específicos de cada agravo caem na tipagem do DBF.

Como o SINAN fecha com atraso, `baixar_sinan` tenta `FINAIS/` e cai
automaticamente em `PRELIM/` quando o consolidado não existe.

### Agravos disponíveis

Cobertura verificada no FTP do DATASUS em 03/10/2026. "Consolidado até" é o
último ano em `FINAIS/`; os seguintes só existem em `PRELIM/` (ver
[Dados preliminares](#Dados-preliminares)). Um ano que falta no meio da série
é pulado por `fetch_datasus` com um aviso.

| agravo | `fetch_datasus` | arquivo | anos no FTP | observação |
|---|---|---|---|---|
| `:acidente_biologico` — Acidente de trabalho com exposição a material biológico | `:SINAN_ACIDENTE_BIOLOGICO` | `ACBIBR{aa}` | 2006–2025 | consolidado até 2022 |
| `:acidente_trabalho` — Acidente de trabalho grave | `:SINAN_ACIDENTE_TRABALHO` | `ACGRBR{aa}` | 2006–2025 | consolidado até 2022 |
| `:acidente_animais` — Acidente por animais peçonhentos | `:SINAN_ACIDENTE_ANIMAIS` | `ANIMBR{aa}` | 2007–2025 | consolidado até 2022 |
| `:atendimento_antirrabico` — Atendimento antirrábico | `:SINAN_ATENDIMENTO_ANTIRRABICO` | `ANTRBR{aa}` | 2006–2025 | consolidado até 2024 |
| `:botulismo` — Botulismo | `:SINAN_BOTULISMO` | `BOTUBR{aa}` | 2007–2025 | consolidado até 2024 |
| `:cancer_trabalho` — Câncer relacionado ao trabalho | `:SINAN_CANCER_TRABALHO` | `CANCBR{aa}` | 2007–2025 | consolidado até 2022 |
| `:chagas` — Doença de Chagas aguda | `:SINAN_CHAGAS` | `CHAGBR{aa}` | 2000–2025 | consolidado até 2022 |
| `:chikungunya` — Chikungunya | `:SINAN_CHIKUNGUNYA` | `CHIKBR{aa}` | 2014–2025 |  |
| `:colera` — Cólera | `:SINAN_COLERA` | `COLEBR{aa}` | 2007–2025 | sem 2023; consolidado até 2022 |
| `:coqueluche` — Coqueluche | `:SINAN_COQUELUCHE` | `COQUBR{aa}` | 2007–2025 | consolidado até 2022 |
| `:dengue` — Dengue | `:SINAN_DENGUE` | `DENGBR{aa}` | 2000–2025 |  |
| `:dermatoses_ocupacionais` — Dermatoses ocupacionais | `:SINAN_DERMATOSES_OCUPACIONAIS` | `DERMBR{aa}` | 2006–2025 | consolidado até 2022 |
| `:difteria` — Difteria | `:SINAN_DIFTERIA` | `DIFTBR{aa}` | 2007–2025 | consolidado até 2023 |
| `:esquistossomose` — Esquistossomose | `:SINAN_ESQUISTOSSOMOSE` | `ESQUBR{aa}` | 2007–2025 | consolidado até 2022 |
| `:exantematicas` — Doenças exantemáticas (sarampo e rubéola) | `:SINAN_EXANTEMATICAS` | `EXANBR{aa}` | 2007–2025 | série inteira só em `PRELIM/` |
| `:febre_maculosa` — Febre maculosa | `:SINAN_FEBRE_MACULOSA` | `FMACBR{aa}` | 2007–2025 | consolidado até 2021 |
| `:febre_tifoide` — Febre tifoide | `:SINAN_FEBRE_TIFOIDE` | `FTIFBR{aa}` | 2007–2025 | consolidado até 2024 |
| `:hanseniase` — Hanseníase | `:SINAN_HANSENIASE` | `HANSBR{aa}` | 2001–2025 | consolidado até 2023 |
| `:hantavirose` — Hantavirose | `:SINAN_HANTAVIROSE` | `HANTBR{aa}` | 2000–2025 | consolidado até 2024 |
| `:hepatites` — Hepatites virais | `:SINAN_HEPATITES` | `HEPABR{aa}` | 2007–2023 | série inteira só em `PRELIM/` |
| `:intoxicacao_exogena` — Intoxicação exógena | `:SINAN_INTOXICACAO_EXOGENA` | `IEXOBR{aa}` | 2006–2025 | consolidado até 2022 |
| `:leishmaniose_visceral` — Leishmaniose visceral | `:SINAN_LEISHMANIOSE_VISCERAL` | `LEIVBR{aa}` | 2000–2025 |  |
| `:leptospirose` — Leptospirose | `:SINAN_LEPTOSPIROSE` | `LEPTBR{aa}` | 2000–2025 | consolidado até 2024 |
| `:ler_dort` — LER/DORT | `:SINAN_LER_DORT` | `LERDBR{aa}` | 2006–2025 | consolidado até 2022 |
| `:leishmaniose_tegumentar` — Leishmaniose tegumentar americana | `:SINAN_LEISHMANIOSE_TEGUMENTAR` | `LTANBR{aa}` | 2000–2025 |  |
| `:malaria` — Malária | `:SINAN_MALARIA` | `MALABR{aa}` | 2004–2025 | consolidado até 2023 |
| `:meningite` — Meningite | `:SINAN_MENINGITE` | `MENIBR{aa}` | 2007–2024 | consolidado até 2022 |
| `:transtornos_mentais_trabalho` — Transtornos mentais relacionados ao trabalho | `:SINAN_TRANSTORNOS_MENTAIS_TRABALHO` | `MENTBR{aa}` | 2006–2025 | consolidado até 2022 |
| `:tracoma` — Tracoma (notificação) | `:SINAN_TRACOMA` | `NTRABR{aa}` | 2010–2025 | consolidado até 2024 |
| `:pair` — Perda auditiva induzida por ruído relacionada ao trabalho | `:SINAN_PAIR` | `PAIRBR{aa}` | 2006–2025 | consolidado até 2022 |
| `:peste` — Peste | `:SINAN_PESTE` | `PESTBR{aa}` | 2007–2025 | consolidado até 2024 |
| `:paralisia_flacida` — Paralisia flácida aguda | `:SINAN_PARALISIA_FLACIDA` | `PFANBR{aa}` | 2007–2025 | consolidado até 2022 |
| `:pneumoconioses` — Pneumoconioses relacionadas ao trabalho | `:SINAN_PNEUMOCONIOSES` | `PNEUBR{aa}` | 2006–2025 | consolidado até 2022 |
| `:raiva` — Raiva humana | `:SINAN_RAIVA` | `RAIVBR{aa}` | 2007–2025 | consolidado até 2024 |
| `:surto_dta` — Surtos de doenças transmitidas por alimentos | `:SINAN_SURTO_DTA` | `SDTABR{aa}` | 2007–2024 | sem 2014; consolidado até 2018 |
| `:sifilis_adquirida` — Sífilis adquirida | `:SINAN_SIFILIS_ADQUIRIDA` | `SIFABR{aa}` | 2010–2024 | série inteira só em `PRELIM/` |
| `:sifilis_congenita` — Sífilis congênita | `:SINAN_SIFILIS_CONGENITA` | `SIFCBR{aa}` | 2007–2025 | série inteira só em `PRELIM/` |
| `:sifilis_gestante` — Sífilis em gestante | `:SINAN_SIFILIS_GESTANTE` | `SIFGBR{aa}` | 2007–2025 | série inteira só em `PRELIM/` |
| `:rubeola_congenita` — Síndrome da rubéola congênita | `:SINAN_RUBEOLA_CONGENITA` | `SRCBR{aa}` | 2007–2025 | série inteira só em `PRELIM/` |
| `:tetano_acidental` — Tétano acidental | `:SINAN_TETANO_ACIDENTAL` | `TETABR{aa}` | 2007–2025 | consolidado até 2023 |
| `:tetano_neonatal` — Tétano neonatal | `:SINAN_TETANO_NEONATAL` | `TETNBR{aa}` | 2014–2025 | consolidado até 2021 |
| `:toxoplasmose_congenita` — Toxoplasmose congênita | `:SINAN_TOXOPLASMOSE_CONGENITA` | `TOXCBR{aa}` | 2019–2025 | consolidado até 2023 |
| `:toxoplasmose_gestacional` — Toxoplasmose gestacional | `:SINAN_TOXOPLASMOSE_GESTACIONAL` | `TOXGBR{aa}` | 2019–2025 | consolidado até 2023 |
| `:tracoma_inquerito` — Tracoma (inquérito) | `:SINAN_TRACOMA_INQUERITO` | `TRACBR{aa}` | 2009–2025 | consolidado até 2024 |
| `:tuberculose` — Tuberculose | `:SINAN_TUBERCULOSE` | `TUBEBR{aa}` | 2001–2025 | consolidado até 2019 |
| `:varicela` — Varicela | `:SINAN_VARICELA` | `VARCBR{aa}` | 2007–2025 | sem 2020; série inteira só em `PRELIM/` |
| `:violencia` — Violência interpessoal/autoprovocada | `:SINAN_VIOLENCIA` | `VIOLBR{aa}` | 2009–2025 | consolidado até 2024 |
| `:zika` — Zika | `:SINAN_ZIKA` | `ZIKABR{aa}` | 2015–2025 |  |

## O cache está em dia com o DATASUS?

O DATASUS republica bases retroativamente, sem aviso, e o cache não sabe
disso: o arquivo baixado em julho continua sendo usado depois que o
DATASUS o substitui. `verificar_cache()` compara cada arquivo do cache com
o FTP, sem baixar nada, e diz o que fazer:

```julia
using DataFrames
v = DataFrame(verificar_cache())
filter(r -> r.situacao in (:mudou, :era_preliminar), v)
```

| situação | o que é | o que fazer |
|---|---|---|
| `:atualizado` | o FTP tem o mesmo arquivo | nada |
| `:mudou` | o DATASUS republicou | `forcar = true` / `cache = false` |
| `:era_preliminar` | preliminar guardado como definitivo por versões até a 0.3.1 | `forcar = true` |
| `:consolidado_disponivel` | preliminar no cache e consolidado já publicado | o próximo `fetch_datasus` troca sozinho |
| `:ausente_no_ftp` | nenhuma URL candidata existe mais | — |
| `:sem_url` / `:sem_resposta` | nome fora do catálogo / servidor não respondeu | — |

A comparação é por tamanho — o FTP não informa a data de modificação por
essa via —, então uma republicação com exatamente o mesmo número de bytes
passa como `:atualizado`. A consulta usa só o canal de controle do FTP, que
responde mesmo onde o firewall bloqueia as transferências, e vai de dois em
dois arquivos: mais que isso, e o servidor do DATASUS passa a deixar
conexões sem resposta.

## De onde veio este resultado?

Cada download grava, ao lado do arquivo, um registro `.origem` com a URL,
a data, o tamanho e o SHA-256. O `fetch_datasus` anexa ao resultado a lista
dos arquivos de que ele veio:

```julia
df = fetch_datasus(:SIM_DO; uf = "PE", anos = 2019:2023)
DataFrame(proveniencia(df))   # arquivo, url, baixado_em, bytes, sha256, preliminar
```

É o que uma nota de método precisa para que a análise possa ser refeita
sobre os mesmos dados: a URL sozinha não identifica a versão de um arquivo
que o DATASUS republica. A proveniência acompanha o `DataFrame` em cópias,
filtros e agregações. Para arquivos baixados antes da 0.4.1, `baixado_em` é
a data do arquivo no cache.

O cache fica no diretório de Scratch do pacote; a variável de ambiente
`MICROSUS_CACHE` o troca por outro (outro disco, um cache por projeto).

## Falha de rede não é arquivo ausente

Um arquivo que não existe no FTP (ano ainda não publicado para uma UF,
partição `PA...b` que não houve) é pulado com um `@warn`. Uma falha de
rede — timeout, DNS, conexão recusada, canal de dados do FTP bloqueado por
firewall — é outra coisa e interrompe com [`MicroSUS.ErroDeRede`](@ref):
seguir daria um resultado incompleto que parece completo.

```julia
try
    fetch_datasus(:SIM_DO; uf = :all, anos = 2023)
catch e
    e isa MicroSUS.ErroDeRede || rethrow()
    # sem acesso ao FTP: e.url diz qual arquivo, e.causa traz o erro original
end
```

A exceção é o preliminar já no cache: sem rede, ele é usado, com um aviso
que diz que foi por falta de rede.

## Dados preliminares

SIM e SINASC dos anos recentes ficam em `PRELIM/` até a consolidação
(historicamente ~18 meses). Se o consolidado não existir, `baixar`
**tenta automaticamente a pasta preliminar**, com um `@warn` — um
indicador calculado sobre dados preliminares merece um asterisco.

```julia
baixar(:sinasc, "PE"; ano = 2025)
# ┌ Warning: não achei o consolidado; tentando dados PRELIMINARES
# └   url = ".../SINASC/PRELIM/DNRES/DNPE2025.dbc"

url_arquivo(:sim, "PE"; ano = 2025, prelim = true)   # URL direta
```

Se as duas falharem, o erro relançado é o da URL principal (consolidada).

O preliminar fica no cache numa subpasta `PRELIM/`, separado do consolidado de
mesmo nome. Duas consequências:

- **dá para saber de onde veio cada arquivo**: `eh_preliminar(caminho)`; o
  `show` de `ler(caminho)` avisa; e `fetch_datasus` acrescenta a coluna
  `PRELIMINAR` e lista, num `@warn`, os arquivos preliminares do resultado;
- **o consolidado substitui o preliminar quando sai**: o consolidado é sempre
  tentado primeiro, mesmo com o preliminar em cache. O custo é uma tentativa
  de rede por chamada enquanto o ano não consolida; sem rede, o preliminar do
  cache é usado (com aviso).

O próprio preliminar também muda — o DATASUS o republica até consolidar —, e o
do cache não é atualizado sozinho: o aviso diz quando ele foi baixado, e
`forcar = true` (ou `cache = false` no `fetch_datasus`) o rebaixa.

```julia
c = baixar(:sim, "PE"; ano = 2025)
eh_preliminar(c)                                       # true

df = fetch_datasus(:SIM_DO; uf = "PE", anos = 2023:2025)
combine(groupby(df, :ANO_ARQUIVO), :PRELIMINAR => first)
```

!!! warning "Cache de versões anteriores"
    Até a 0.3.1 o preliminar era guardado no mesmo lugar do consolidado, com o
    mesmo nome — e, uma vez no cache, era devolvido para sempre como se fosse
    definitivo. Um cache montado por essas versões pode ter preliminares
    antigos na raiz; rebaixe os anos recentes com `forcar = true` (ou rode
    `MicroSUS.limpar_cache()`).

## Limites de cobertura

- **SINASC**: o helper cobre 1996+ (estrutura `1996_/Dados`); 1994–1995
  ficam em `SINASC/1994_1995/`, com outro padrão de nomes — monte a URL
  manualmente e use [`ler`](@ref) no arquivo baixado.
- **SIH/SIA**: estrutura pós-2008 (`200801_`); os arquivos de
  1992–2007 / 1994–2007 têm pastas e layouts próprios.
- **CNES**: só o `ST` (estabelecimentos) tem helper; os outros tipos
  (`LT`, `PF`, `EQ`, ...) seguem o mesmo padrão de URL — adapte a partir
  de `url_arquivo(:cnes, ...)`.

## Paralelizar a leitura entre arquivos

O DCL é sequencial por natureza (cada byte depende do histórico), então
não há paralelismo *dentro* de um arquivo. O padrão é paralelizar
*entre* arquivos:

```julia
caminhos = baixar(:sinasc, "PE"; anos = 2019:2023, quieto = true)
partes = asyncmap(caminhos; ntasks = Threads.nthreads()) do c
    materializar(ler(c; colunas = [:DTNASC, :CODMUNRES]))
end
```

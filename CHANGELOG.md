# Changelog

All notable changes to MicroSUS.jl are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the package is in `0.x`, breaking changes bump the minor version and
fixes bump the patch version, following Julia's `^0.x.y` compatibility rules.

## [Unreleased]

### Added

- Downloads interrompidos são retomados de onde pararam (FTP e `file://`):
  até cinco vezes na mesma chamada, e o parcial fica no cache
  (`.parcial`) para a próxima. O tamanho no servidor é conferido antes de
  retomar; se mudou, o parcial é descartado.
- Espelhos: `MICROSUS_ESPELHOS` lista origens com a árvore de pastas do FTP
  (`file://`, HTTP), usadas quando o DATASUS falha por rede — ou antes dele,
  com `MICROSUS_ESPELHO_PRIMEIRO=true`. O DATASUS continua decidindo se um
  arquivo existe. `exportar_espelho(destino)` copia o cache para essa
  árvore, e `proveniencia` ganha `obtido_de`.
- Manifest dos dados: `travar_dados("dados.toml", resultados...)` grava URL,
  SHA-256, tamanho e data da extração de cada arquivo de que os resultados
  vieram; `restaurar_dados("dados.toml")` os devolve ao cache conferindo o
  hash — do DATASUS ou de um espelho, que é onde uma versão republicada pode
  sobreviver — e ativa a trava na sessão (`soltar_dados()` desativa).
  Arquivo que não volta com o mesmo hash é erro, salvo `estrito = false`.
  Nova dependência: `TOML` (biblioteca padrão).
- `auditar(df)`: checagens de qualidade antes de analisar — completude por
  coluna e ano, descontinuidades (campo que para ou começa a ser preenchido
  entre anos), causas básicas mal definidas (R00–R99) e códigos que não
  valem como causa básica, e valores implausíveis (idade, datas, peso, idade
  da mãe, semanas de gestação, causa incompatível com o sexo). No SIM de PE
  2014–2023 (676 mil óbitos, 1,3 s): o CRM do atestante some a partir de
  2019.
- Indicadores de mortalidade (RIPSA), por residência e ano, em qualquer nível
  territorial: `mortalidade_infantil` (e os componentes neonatal precoce,
  neonatal tardio e pós-neonatal), `razao_mortalidade_materna`,
  `proporcao_mal_definidas` e `mortalidade_prematura_dcnt` (30–69 anos, as
  quatro DCNT do Plano de DANT, com a população da SIDRA). Para PE em 2022,
  todas as contagens batem com o TabNet. `CID_MATERNA` e `CID_DCNT` exportam
  os recortes.

## [0.4.1] - 2026-10-03

### Added

- 17 fontes novas no catálogo, cada uma com a faixa de anos conferida no FTP:
  os recortes nacionais do SIM (`:SIM_DOFET`, `:SIM_DOINF`, `:SIM_DOEXT`,
  `:SIM_DOMAT`, 1996 em diante), os demais arquivos da AIH (`:SIH_SP` desde
  1997, `:SIH_RJ` desde 2006, `:SIH_ER` desde 2011) e as demais tabelas do
  CNES (`:CNES_LT`, `:CNES_EQ`, `:CNES_SR` e mais sete; `:CNES_EE` parou em
  2018). Vêm brutas, sem rotina de padronização. `fontes()` ganha
  `ano_final`, e `verificar_cache` reconhece os arquivos delas. Os nacionais
  do SIM de 2025 estão em `CID10/DOFET` e, idênticos, em `PRELIM/DOFET`: essas
  fontes tentam o PRELIM primeiro, o preliminar do cache só vale enquanto
  estiver no FTP, e `verificar_cache` não toma a cópia por consolidação.

- Regiões abaixo da UF em `municipio`/`municipios()`: região de saúde (CIR,
  439) e macrorregião de saúde (121), das tabelas territoriais do DATASUS, e
  regiões imediata e intermediária do IBGE (510 e 133), cada uma com código e
  nome. `populacao` e `populacao_por_idade` aceitam `nivel = :regiao_saude`,
  `:macrorregiao_saude`, `:regiao_imediata` e `:regiao_intermediaria`, somando
  os municípios (o Censo 2022 fecha em 203.080.756 por qualquer um deles).
  Óbitos por agressão em PE, 2022: de 54,8 por 100 mil na III Região de Saúde
  a 13,4 na VII.

- `descricao_cid(cod)` e `cid10(cod)`: descrição em português de um código
  da CID-10, com categoria, grupo, capítulo, restrição de sexo e validade como
  causa básica de óbito. Tabela do DATASUS (versão 2008, a última publicada em
  CSV) embarcada em `data/cid10.tsv`, sem rede, mais a dengue (A97) da
  atualização da OMS de 2016. Códigos posteriores a 2008 recebem a descrição
  da categoria, marcado em `nivel`. Nos 20,6 milhões de óbitos do SIM de
  2010–2024, só 28 ficam sem descrição; uma coluna de 334 mil causas é
  rotulada em 0,13 s.

- `populacao_por_idade(ano; nivel)`: população do IBGE por sexo e faixa
  etária — Censos 2010 e 2022 até o município, e a projeção da população
  (revisão 2018, anterior ao Censo 2022, marcada na coluna `fonte`) para
  Brasil e UFs nos demais anos de 2000–2060. Consulta por idade simples,
  agregada em faixas configuráveis; a soma bate com o total oficial dos
  Censos (5.570 municípios, 203.080.756 em 2022). `faixa_etaria(idade)` põe os
  microdados nas mesmas faixas, e `taxa_padronizada(casos, pop, padrao)` faz a
  padronização direta. Mortalidade geral em 2022: bruta 956 (RS) contra 510
  (AM) por 100 mil; padronizadas pelo Brasil, 795 e 776.

- `verificar_cache()`: compara cada arquivo do cache com o FTP do DATASUS,
  sem baixar nada, e classifica em `:atualizado`, `:mudou` (o DATASUS
  republicou), `:era_preliminar` (preliminar guardado como definitivo por
  versões até a 0.3.1), `:consolidado_disponivel`, `:ausente_no_ftp`,
  `:sem_url` ou `:sem_resposta`. No cache de quem escreveu isto, achou os três
  preliminares antigos que só tinham aparecido por comparação manual.
  Funciona pelo canal de controle do FTP, que responde mesmo onde o firewall
  bloqueia as transferências.
- `proveniencia(df)`: os arquivos de que um resultado de `fetch_datasus` veio
  — URL, data do download, bytes, SHA-256, preliminar —, anexados ao
  `DataFrame` como metadado e preservados em cópias, filtros e agregações.
- Cada download grava um registro `.origem` ao lado do arquivo no cache.
  Arquivos de caches antigos ganham o registro na primeira leitura, com a
  data do arquivo.
- `MICROSUS_CACHE` troca o diretório do cache.

### Changed

- Dependências: `SHA` (biblioteca padrão) e DataFrames ≥ 1.4, a primeira com
  metadados.

### Fixed

- `fetch_datasus(:SINASC)` lia a cópia desatualizada do SINASC. O catálogo
  tentava primeiro `SINASC/NOV/DNRES`, uma cópia que parou em 2022 e que, para
  2016, ficou com a versão de janeiro de 2020; a pasta canônica,
  `SINASC/1996_/Dados/DNRES` (a única com 2023 em diante, e a que o
  `baixar(:sinasc, …)` já usava), tem a versão republicada em julho de 2025.
  Nos demais anos as duas pastas têm o mesmo arquivo. Achado pelo
  `verificar_cache`. Quem tem o `DNPE2016` (ou outra UF de 2016) baixado pela
  pasta antiga continua com ele no cache — `verificar_cache()` o aponta como
  `:mudou`.
- A suíte de testes escrevia no cache de quem a rodava (e deixava arquivos
  lá); agora usa um diretório temporário.

## [0.4.0] - 2026-10-03

### Migrando da 0.3

Mudanças que alteram o resultado de código que já existia:

- **`fetch_datasus` padroniza SINAN e CNES.** Antes devolvia os códigos crus
  com um `@info`; agora aplica `process_sinan` e `process_cnes`. Para o
  comportamento antigo, `processar = false`.
- **Colunas categóricas têm elemento `String`**, não mais `InlineString`.
  Comparações (`== "261110"`) não mudam; código que dependia do tipo exato, sim.
- **Nomes de campo vêm em maiúsculas.** O único afetado é `contador` (SIM de
  2010; SINASC de 1996, 2014, 2015 e 2017), que vira `CONTADOR`. Pedidos em
  `colunas` e `r[:campo]` aceitam qualquer caixa.
- **Falha de rede interrompe com `MicroSUS.ErroDeRede`**, em vez de seguir com
  um `@warn` de "arquivos não encontrados" e um resultado incompleto. Arquivo
  de fato ausente continua sendo pulado com `@warn`.
- **Texto do CNES é lido como CP1252.** `"N║ 64"` passa a sair `"Nº 64"`.
- **Malária (`MALABR`) é reconhecida como SINAN**: `NU_IDADE_N` passa a vir em
  anos, não no código cru (`4025`).
- **`fetch_datasus` acrescenta `PRELIMINAR`** e `UF_ARQUIVO` passa a ser
  categórica.
- **`converter` grava categóricas como texto simples**, sem dicionário Arrow.
- **Cache:** preliminares vão para `PRELIM/`. Um cache montado até a 0.3.1 pode
  ter preliminares antigos na raiz, que o pacote não tem como reconhecer —
  rebaixe os anos recentes com `forcar = true` ou rode `MicroSUS.limpar_cache()`.

### Added

- `haskey(r, :CAMPO)` no `filtro` de `ler`/`fetch_datasus`: campos que não
  existem em todos os anos (as linhas da DO, `DIAGSEC1` no SIH) davam
  `KeyError` com `r[:CAMPO]`.
- `scripts/creutzfeldt_jakob.jl`: óbitos (SIM) e internações (SIH) por doença
  de Creutzfeldt-Jakob por região, UF e município, com taxas por milhão de
  habitantes. Um exemplo de análise sobre a API: `fetch_datasus` com
  `colunas` e `filtro`, `cid_casa`/`menciona_cid`, `municipio`/`uf_de`/`regiao`
  e `populacao`.

- `process_cnes`, aplicado por `fetch_datasus` a `:CNES_ST` e `:CNES_PF`:
  rotula 119 campos categóricos do CNES (tipo de unidade, esfera, natureza
  jurídica, nível de hierarquia, gestão, vínculo com o SUS, turno, clientela,
  os indicadores de serviços). Os dicionários (`data/rotulos_cnes.tsv`) vêm do
  `microdatasus` (MIT, `data/LICENSE-microdatasus`), restritos aos campos cujos
  códigos observados em arquivos reais de 2005, 2019 e 2023 estão todos
  cobertos; corrigido "luvrativa" → "lucrativa". Nos cinco arquivos de
  validação, um único valor (código `3301` de `NAT_JUR`) fica sem rótulo. Os
  rótulos não foram conferidos contra as tabelas oficiais (`TAB_CNES`).
- `rotular!(...; avisar = true, ignorados)`: código fora do dicionário vira
  `missing` com um `@warn` que diz qual e em quantos registros — contados por
  linha, mesmo em colunas categóricas. `process_cnes` usa; as rotinas com
  dicionários próprios (SIM, SINASC, SIH, SINAN) seguem sem aviso.

- Busca de CID-10: `cid_casa(cid, alvos)` aceita prefixos (`"A81"`) e faixas de
  categorias (`"X85" => "Y09"`), normalizando ponto, espaço e caixa
  (`normaliza_cid`); `cids_em(texto)` separa os códigos concatenados das linhas
  da Declaração de Óbito e `menciona_cid(texto, alvos)` testa causas múltiplas
  sem casar pedaços formados pela junção de dois códigos vizinhos. Tudo cabe
  no `filtro` de `ler`. `eh_agressao` agora é `cid_casa` com o recorte de CVLI.
- Tabela de municípios do IBGE embarcada (`data/municipios.csv`, 5.571 linhas):
  `municipio(cod)` devolve nome, UF, região e códigos de 6 e 7 dígitos sem
  acesso à rede; `municipios()` devolve a tabela inteira para joins; `uf_de` e
  `regiao` resolvem UF e grande região a partir de sigla ou código.
- 48 agravos do SINAN, de 16: entram sífilis congênita, em gestante e
  adquirida, leptospirose, coqueluche, acidente de trabalho, LER/DORT,
  toxoplasmose congênita e gestacional, varicela e outros. Cada um é aceito
  por `baixar_sinan`/`url_sinan` e é uma fonte de `fetch_datasus`
  (`:sifilis_congenita` → `:SINAN_SIFILIS_CONGENITA`). O ano inicial de cada
  um foi verificado no FTP do DATASUS; `agravos_sinan()` lista todos, e o guia
  de download tem a tabela com a cobertura e as lacunas (cólera 2023, surtos de
  DTA 2014, varicela 2020).
- `process_sinan(df; agravo = :auto)`, aplicado por `fetch_datasus` a toda fonte
  `:SINAN_*`. Rotula o núcleo comum às fichas (`TP_NOT`, `CS_SEXO`, `CS_RACA`,
  `CS_GESTANT`, `CS_ESCOL_N`, `HOSPITALIZ`), converte as datas `DT_*` e cria
  `IDADE_ANOS`. `CLASSI_FIN`, `CRITERIO` e `EVOLUCAO` mudam de sentido entre
  agravos e só são rotulados para dengue, chikungunya e zika, cada um com seu
  dicionário — inclusive a ficha da dengue anterior a 2014 (1–4) e a ficha
  própria da chikungunya de 2014–2016 (1 = confirmado, 2 = descartado), que um
  dicionário único rotularia como "Dengue clássico". Validado contra
  DENGBR23, CHIKBR15, ZIKABR23, VIOLBR09 e MALABR22: só viram `missing` os
  códigos de ignorado (`9`, `I`) e o `0` não documentado.
- `rotular!(...; ignora_zeros = true)`: `"01"` e `"1"` dão o mesmo rótulo. O
  SINAN grava as duas formas no mesmo arquivo (ZIKABR23: 1.101 `"01"` e 502
  `"1"` em `CS_ESCOL_N`); sem isso, metade dos registros viraria `missing`.
- `ler(caminhos::AbstractVector)`: vários `.dbc`/`.dbf` como uma tabela só
  (`TabelaConcatenada`), em streaming — os lotes saem de um arquivo depois do
  outro e a memória continua O(`tamanho_lote`). Os tipos são unificados por
  coluna (texto de larguras diferentes vira a `InlineString` mais larga,
  inteiro + decimal vira `Float64`, outra mudança de tipo vira `String` com
  aviso), então todo lote tem o mesmo schema. `uniao = true` faz a união de
  layouts diferentes com `missing`; sem ele, a diferença é erro e a mensagem
  diz o que falta onde. `origem` (padrão `:ARQUIVO`) acrescenta o arquivo de
  cada linha. Com `colunas`, a ordem da saída é a pedida. Validado com o SIM de
  PE 2010–2023 (902.936 registros, 100 colunas na união) e o SIH de 2010 + 2016
  (`DIAGSEC1` só a partir de 2011): idêntico à leitura arquivo a arquivo.
- `converter` aceita um vetor de caminhos e grava um `.arrow` só.
- `ler(caminhos; origem = f)`: `origem` também aceita uma função
  `caminho -> NamedTuple`, cujas chaves viram colunas constantes por arquivo.
- `process_sim`, `process_sinasc`, `process_sih` e `process_sinan` aceitam
  `copiar = false`, para padronizar no lugar.

- `eh_preliminar(caminho)` diz se um arquivo veio de uma pasta `PRELIM/` do
  DATASUS; `fetch_datasus` acrescenta a coluna `PRELIMINAR` e lista num `@warn`
  os arquivos preliminares do resultado; o `show` de `ler` avisa. Antes, a
  única marca era um `@warn` no download, que não chegava ao resultado — nem
  aparecia nas chamadas seguintes, servidas do cache.
- `populacao(anos; nivel = :municipio, interpolar = false)`: população
  residente do IBGE por município, UF ou Brasil, de 2000 em diante, pela API
  SIDRA e com cache local — o denominador das taxas. O `codigo6` casa com
  `CODMUNRES`/`MUNIC_RES`. Cada linha traz a `fonte` (Censo 2000/2010/2022,
  Contagem 2007 ou estimativa anual), porque a série não é homogênea: as
  estimativas de 2011–2021 superestimaram a população (213,3 milhões para
  2021 contra 203,1 milhões no Censo 2022), e uma taxa que atravesse esses
  anos salta só pelo denominador — no Recife, os óbitos por agressão caíram de
  655 para 636 e a taxa subiu de 39,4 para 42,7 por 100 mil. 2023, sem
  publicação do IBGE, é erro, a não ser com `interpolar = true`. Sem
  dependência nova: o JSON da SIDRA é lido com regex. Os totais batem com os
  oficiais (teste de rede).

- `notebooks/sim-pe-2023.ipynb`, linked from both READMEs by a badge that opens it in Google
  Colab, which runs Julia natively. It reads one year of death certificates from Pernambuco
  (SIM, 2023 — 68,527 records) with `fetch_datasus(...; processar = false)`, audits the raw codes
  with [MissingPatterns.jl](https://github.com/dantebertuzzi/MissingPatterns.jl) — DATASUS codes
  absence as `9` or as a blank field, so `isna` is what makes it visible — and then does the
  statistics the audit supports: deaths by month, age at death by cause with `eh_agressao`, a
  Mann-Whitney, a chi-square, and a logistic regression whose complete-case cost is the number
  the audit already priced. Committed with the outputs of a real run, so it reads on GitHub
  without being executed.

  Two things the notebook establishes about this package's own output: the `isna` audit of the
  raw frame reproduces `process_sim`'s `missing` counts exactly, field by field; and `OCUP`, which
  `process_sim` deliberately leaves unlabelled, keeps 8,067 blank occupations that survive
  standardisation looking like data.

### Changed

- Com mais de uma thread, as colunas de cada lote são convertidas em
  paralelo (uma tarefa por coluna; lotes com menos de 2.000 linhas ficam na
  thread atual). Acelera também a leitura de um arquivo só: `DOSP2023` 1,72 →
  1,23 s com 4 threads e 1,15 s com 8 — perto do piso de 1,0 s da
  descompressão, que é sequencial —; `DENGBR23` 4,7 → 3,3 s e 2,9 s; os 10
  anos do SIM de PE 2,2 → 1,9 s e 1,4 s. Com uma thread, nada muda. O pico de
  memória com 8 threads sobe cerca de 12%. Resultado idêntico com 8 threads
  nas 1.078 colunas de comparação.
- `fetch_datasus` baixa até 4 arquivos ao mesmo tempo (como o `baixar` no
  plural), em vez de um por vez; e, com mais de uma thread, `ler(caminhos)` —
  e portanto `fetch_datasus` — lê os arquivos seguintes enquanto o atual é
  consumido, com a saída na mesma ordem. Os 10 anos do SIM de PE: 4,3 → 2,1 s
  com 4 threads, 1,7 s com 8; `fetch_datasus` dos mesmos anos: 4,9 → 2,7 s e
  2,1 s. Oito downloads com 1 s de latência simulada: 8,8 → 2,7 s. Com uma
  thread, a leitura é a sequencial de sempre. Resultado idêntico com 8
  threads nas 1.078 colunas dos 12 casos de comparação.
- A leitura converte cada lote coluna a coluna, em vez de linha a linha. Antes,
  cada campo de cada registro passava por uma chamada despachada em tempo de
  execução (29 milhões no `DOSP2023`), o texto virava uma `String` temporária
  antes da `InlineString`, e cada linha de uma coluna categórica criava uma
  `String` só para procurá-la no dicionário. Agora o texto ASCII vai direto
  dos bytes para a `InlineString`, a categórica é montada a partir dos índices
  (cada valor distinto vira `String` uma vez por lote) e a idade do SIM/SINAN
  é decodificada sem `String` intermediária. `DOSP2023`: 4,3 → 1,9 s e 60 → 4,6
  milhões de alocações; `DENGBR23` (1,6 milhão de registros): 17,8 → 5,2 s e
  384 → 20 milhões de alocações; `fetch_datasus` do SIM de PE 2014–2023: 9,4 →
  4,7 s. Resultado idêntico, valor e tipo, nas 1.078 colunas de 12 casos
  (SIM, SINASC, SIH, SINAN, CNES, SIA; lote pequeno, filtro, `pool = false`,
  outra codificação, vários arquivos).
- `fetch_datasus` lê os arquivos em streaming, por `ler(caminhos)`, e
  padroniza o próprio resultado sem copiá-lo. No SIM de PE 2014–2023 (675.806
  óbitos, 92 colunas) o pico de memória cai de 5,9 para 3,4 GiB, com o mesmo
  resultado coluna a coluna e o mesmo tempo. Ganha `colunas` e `filtro`, que
  vão para o leitor: dez anos de CVLI em PE com três colunas ficam em 580 MiB
  de pico. `UF_ARQUIVO` passa a ser categórica.
- `DataFrame(ler(...))` não copia mais as colunas (`Tables.columns` devolve
  `Tables.CopiedColumns`) e a materialização acumula os lotes em vez de
  guardá-los todos para concatenar no fim: no `DOSP2023`, pico de 2,1 para
  1,5 GiB.

- Os agravos do SINAN vêm de uma tabela única (`src/agravos.jl`). Eram três
  listas mantidas à mão — a de `baixar_sinan` (16 agravos), a de
  `fetch_datasus`/`fontes()` (6) e a de `detecta_sistema` (19 prefixos) — e
  divergiam: malária estava em `fetch_datasus` mas não era reconhecida como
  SINAN por `detecta_sistema`, e 10 dos 16 agravos de `baixar_sinan` não
  existiam em `fontes()`. Todo símbolo e toda fonte que existiam continuam
  aceitos.
- `:SINAN_CHIKUNGUNYA` começa em 2014 (era 2015) e `:SINAN_ZIKA` em 2015 (era
  2016): os dois anos estão publicados.
- O tipo do elemento das colunas categóricas (`pool = true`) passou de
  `InlineString` para `String`. Comparações (`== "261110"`) não mudam; código
  que dependia do tipo exato do elemento, sim.

### Fixed

- Ler o cabeçalho de um `.dbc` corrompido deixava o arquivo aberto: `abre_dbc`
  não o fechava quando a leitura falhava. No Windows, o arquivo ficava preso
  (`EBUSY`) e não podia ser apagado nem baixado de novo.

- Um `.dbc` truncado no cache era devolvido para sempre: o cache só conferia
  se o arquivo existia (`DENGBR00.dbc`, com o cabeçalho cortado, no cache de
  quem escreveu isto). O cabeçalho passa a ser lido antes de usar o arquivo
  do cache; se falha, ele é descartado e baixado de novo, com aviso.

- Leituras de vários anos do SINASC e do SIM saíam com duas colunas para o
  mesmo campo: o DATASUS grava `contador` no SIM de 2010 e no SINASC de 1996,
  2014, 2015 e 2017, e `CONTADOR` nos demais anos (é o único campo assim nos
  654 arquivos do cache de teste). No SINASC de PE 2014–2023, cada coluna
  ficava com metade dos 1,3 milhão de valores e `missing` no resto. Os nomes
  de campo passam a ser lidos em maiúsculas, a convenção do DBF; `colunas` e
  o `r[:campo]` do filtro aceitam qualquer caixa, então `:contador` continua
  funcionando.

- Texto do CNES saía corrompido: `"3ª"` como `"3¬"`, `"Nº 64"` como `"N║ 64"`,
  `"28°"` como `"28░"`. O CNES é CP1252, e o pacote o lia como CP850 — os
  arquivos de 2005 e 2019 até declaram o LDID `0x58` (Windows ANSI ocidental),
  que o pacote não conhecia; os de 2023 não declaram nada (`0x00`). Os LDIDs
  `0x58` e `0x59` passam a valer CP1252, e o CNES sem declaração também. SIH
  continua CP850 (declara `0x02`, e `"DOCUMENTAçaO"` só sai certo assim); SIM,
  SINASC, SINAN e SIA de 2023 não têm byte não ASCII nos dados. Na comparação
  de 1.078 colunas, só a do CNES mudou.

- No Windows, um download que falhava podia terminar num `IOError` (`EBUSY` ao
  apagar o `.part`): com os downloads simultâneos, dois pedidos do mesmo
  arquivo escreviam no mesmo `.part`, e o Windows não apaga arquivo aberto por
  outra tarefa. O `IOError` escondia o erro do download, e com ele a diferença
  entre arquivo ausente e falha de rede. Cada download passa a usar um `.part`
  próprio, e uma falha ao limpá-lo nunca esconde o erro original.

- Falha de rede era tratada como arquivo ausente. `baixar_url` — e com ela
  `fetch_datasus` — contava todo `RequestError` como "o arquivo não existe",
  embora a docstring prometesse propagar timeout e DNS: sem acesso ao FTP, um
  `fetch_datasus(:SIM_DO; uf = :all, …)` devolvia um resultado incompleto, ou
  vazio, com só um `@warn` de "arquivos não encontrados". Agora só conta como
  ausente a resposta de arquivo inexistente (libcurl 78/19/37; HTTP/FTP 404,
  410, 550); o resto interrompe com `MicroSUS.ErroDeRede`. Sem rede, um
  preliminar já no cache continua sendo usado, e o aviso passa a dizer que foi
  por falta de rede (antes dizia "consolidado ainda não publicado").
  `baixar` e `baixar_sinan` seguem a mesma regra.

- `codigo7_ibge` e `codigo6_ibge` erravam em nove municípios cujo dígito
  verificador oficial não segue o algoritmo de `dv_ibge` (Bom Princípio do
  Piauí, Brejo do Piauí, Canavieira, Quixaba, Cônego Marinho, Ponto Chique,
  Coronel Barros, Buriti de Goiás, Buritinópolis): `codigo7_ibge(261153)`
  devolvia 2611531 em vez de 2611533, e `codigo6_ibge(2611533)` rejeitava um
  código válido. As duas agora usam o dígito da tabela oficial e caem no
  algoritmo só para códigos fora dela.
- `detecta_sistema` olhava só as 4 primeiras letras do nome, o que não serve
  para prefixos de 3 (`SRCBR21.dbc`, rubéola congênita); agora casa o nome
  inteiro (`{PREFIXO}BR{aa}.dbc`).
- `converter` — e `Arrow.write(saida, ler(caminho))`, como a docstring de `ler`
  sugere — falhava com `fatal error writing arrow data` em todo arquivo que
  produzisse mais de um lote e tivesse uma coluna categórica: o Arrow não grava
  o dicionário de um `PooledArray` de `InlineString` em mais de um record batch.
  Com o lote padrão de 100.000 linhas, isso derrubava a conversão de qualquer
  UF grande (`DOSP2023`, 334.303 registros). As colunas categóricas agora usam
  `PooledArray{String}`; o pool guarda só os valores distintos, e a leitura do
  `DOSP2023` inteiro não mudou de tempo nem de memória. Arrow entrou nas
  dependências de teste, com um teste de regressão.
- `converter` grava as colunas categóricas como texto simples, sem
  dicionário. Com dicionário, um valor que só aparece num lote posterior vira
  um *delta*, e o leitor do Arrow.jl 2.8 falha de forma intermitente ao abrir
  o arquivo (`MethodError` em `resize!` de um `DictEncoded`) — o que acontece
  ao juntar UFs ou anos num `.arrow` só. O `DOSP2023` sai 13% maior (161 MiB
  contra 142 MiB) e é gravado 3× mais rápido.
- Preliminar e consolidado têm o mesmo nome de arquivo e eram guardados no
  mesmo lugar do cache. Um preliminar baixado uma vez passava a ser devolvido
  para sempre — sem aviso, como se fosse definitivo, e mesmo depois que o
  DATASUS publicasse o consolidado. Agora o preliminar mora em `PRELIM/` dentro
  do cache, e o consolidado é sempre tentado antes: quando sai, substitui o
  preliminar. Vale para `baixar`, `baixar_sinan` e `fetch_datasus`. **Caches
  montados até a 0.3.1 podem ter preliminares antigos na raiz**: rebaixe os
  anos recentes com `forcar = true`, ou rode `MicroSUS.limpar_cache()`.
- `limpar_cache` agora apaga também subpastas do cache.

- Os arquivos do CNES de 2023 não abriam (`descritor de campo truncado`):
  `STPE2312.dbc` e `STBA2312.dbc` trazem `0x00` onde o DBF põe o `0x0D` que
  encerra a lista de campos, embora os 208 descritores estejam completos e a
  soma das larguras bata com o tamanho do registro. O fim da lista passa a
  ser o tamanho do cabeçalho declarado no arquivo; o `0x0D` continua aceito,
  e um cabeçalho de fato truncado continua sendo erro.

### Documentation

- `docs/checa_blocos.jl`, rodado pelo CI antes de construir a documentação. As
  páginas de exemplos são pipelines — os blocos rodam em ordem e compartilham
  estado —, mas o Documenter não executa blocos ```julia, então um nome que
  falta ou uma coluna que o DataFrame não carregou passavam batido e só
  apareciam para quem tentasse seguir a página. O script parseia cada bloco e
  acusa três coisas: bloco que não parseia, nome usado antes (ou sem nunca) ser
  definido, e coluna acessada num DataFrame que não a carregou. Rodado contra
  as versões da página anteriores a cada correção de hoje, pega todos os sete
  defeitos.
- Seção 7: `ip` e a coluna `:mes` nunca eram definidos, e dois números não se
  reproduziam. A comparação entre semestres em Alagoas é de **2,14×** (média
  mensal de jul–set contra jan–jun), não 2,24; a amplitude do índice sem
  Alagoas é de **44** pontos, não 46. O bloco agora calcula os dois.

## [0.3.1] - 2026-08-29

### Documentation

- "Isenção de responsabilidade" section in both READMEs and on the
  documentation home page. The MIT disclaimer already does the legal work, but
  it is in English, in all caps, in a file nobody opens. This states in plain
  language that the package is a reading tool rather than a data source, that
  content and accuracy are the publishing agency's responsibility, that DATASUS
  republishes retroactively, that preliminary data is flagged, and that
  validating results is the analyst's job.
- DOI. The repository is archived on Zenodo, so releases now carry a persistent
  identifier: `10.5281/zenodo.22164178` is the concept DOI (always the newest
  version, and what the README badge points at) and `10.5281/zenodo.22164179`
  is v0.3.0. Recorded in `CITATION.cff` (top-level `doi` plus an `identifiers`
  block), in `CITATION.bib` and in the "How to cite" section of both READMEs.
  The shipped BibTeX carries the concept DOI, which stays valid across
  releases; the section explains that a paper should swap it for the DOI of the
  version that actually ran.

## [0.3.0] - 2026-08-29

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
- `baixar_sinan(:malaria)` / `url_sinan(:malaria)` — the agravo was registered
  for `fetch_datasus` as `:SINAN_MALARIA` but missing from `_SINAN_AGRAVO`, so
  the `baixar_sinan` path raised `ArgumentError` for a disease both READMEs
  listed as available.
- `CITATION.cff` and `CITATION.bib`, so GitHub's "Cite this repository" button
  works and a BibTeX entry is available. Both READMEs gained a "How to cite"
  section covering the software, the DATASUS data (with extraction date, since
  the databases are republished retroactively) and reproducibility, plus the
  standards behind those recommendations (FORCE11, CFF 1.2.0, ABNT NBR 6023).

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
  years, the secondary-diagnosis field that moves between columns mid-series,
  the 6-vs-7-digit IBGE municipality join, cross-system comparison without a
  shared identifier, age standardisation, and the data-entry lag that truncates
  the last three months of any competence-based extract. The full pipeline is
  runnable at `docs/exemplo_intermediario.jl`; every number on the page came
  from one run of it.
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

[Unreleased]: https://github.com/dantebertuzzi/MicroSUS.jl/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/dantebertuzzi/MicroSUS.jl/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/dantebertuzzi/MicroSUS.jl/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/dantebertuzzi/MicroSUS.jl/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/dantebertuzzi/MicroSUS.jl/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/dantebertuzzi/MicroSUS.jl/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/dantebertuzzi/MicroSUS.jl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/dantebertuzzi/MicroSUS.jl/releases/tag/v0.1.0

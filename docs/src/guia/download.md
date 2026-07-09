# Download e FTP

## `baixar`

```julia
caminho  = baixar(:sim, "PE"; ano = 2023)              # um arquivo
caminhos = baixar(:sim, "PE"; anos = 2013:2023)        # vários, paralelo
caminhos = baixar(:sih, "PE"; anos = [2023], meses = 1:12)
```

- **Cache local** via Scratch.jl: chamadas repetidas devolvem o caminho
  já baixado sem tocar a rede. `forcar = true` ignora o cache;
  `quieto = true` silencia os `@info`.
- A forma plural baixa em paralelo (`asyncmap`, 4 conexões) e devolve
  os caminhos na ordem dos períodos.
- Downloads interrompidos não poluem o cache (escrita em `.part` +
  `mv` atômico).
- `MicroSUS.limpar_cache()` zera tudo.

## Caminhos do FTP

Conferidos contra o `microdatasus` (jul/2026) — o FTP do DATASUS já
mudou de estrutura no passado, e é a primeira coisa a checar quando um
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
inteiro) — por isso a API é por *agravo*, não por UF. Filtre a UF de
residência no leitor.

```julia
caminho = baixar_sinan(:dengue; ano = 2020)          # DENGBR20.dbc, nacional
caminhos = baixar_sinan(:zika; anos = 2016:2020)     # vários anos, paralelo

# só Pernambuco, filtrando no leitor (SG_UF = residência)
pe = DataFrame(ler(caminho; filtro = r -> strip(r[:SG_UF]) == "26"))
```

Agravos disponíveis: `:dengue`, `:chikungunya`, `:zika`,
`:leishmaniose_visceral`, `:leishmaniose_tegumentar`, `:esquistossomose`,
`:febre_tifoide`, `:meningite`, `:tuberculose`, `:hanseniase`,
`:hepatites`, `:violencia`, `:intoxicacao_exogena`, `:acidente_animais`
(a lista completa está em `MicroSUS._SINAN_AGRAVO`). O schema `:sinan`
tipa o núcleo comum das fichas (datas, local, `NU_IDADE_N` → anos,
`CLASSI_FIN`, `CRITERIO`, `EVOLUCAO`); campos específicos de cada agravo
caem na tipagem do DBF.

Como o SINAN finaliza com atraso, `baixar_sinan` tenta `FINAIS/` e cai
para `PRELIM/` automaticamente quando o consolidado não existe.

## Dados preliminares

SIM e SINASC de anos recentes ficam em `PRELIM/` até a consolidação
(que historicamente leva ~18 meses). Se o consolidado não existir,
`baixar` **tenta a pasta preliminar automaticamente**, com um `@warn` —
indicador calculado sobre preliminar merece asterisco na figura.

```julia
baixar(:sinasc, "PE"; ano = 2025)
# ┌ Warning: não achei o consolidado; tentando dados PRELIMINARES
# └   url = ".../SINASC/PRELIM/DNRES/DNPE2025.dbc"

url_arquivo(:sim, "PE"; ano = 2025, prelim = true)   # URL direta
```

Se ambos falharem, o erro relançado é o da URL principal (consolidada).

## Limites de cobertura

- **SINASC**: o helper cobre 1996+ (estrutura `1996_/Dados`);
  1994–1995 vivem em `SINASC/1994_1995/` com outro padrão de nome —
  monte a URL manualmente e use [`ler`](@ref) no arquivo baixado.
- **SIH/SIA**: estrutura pós-2008 (`200801_`); os arquivos
  1992–2007/1994–2007 têm pastas e layouts próprios.
- **CNES**: só o `ST` (estabelecimentos) tem helper; os demais tipos
  (`LT`, `PF`, `EQ`, ...) seguem o mesmo padrão de URL — adapte a
  partir de `url_arquivo(:cnes, ...)`.

## Paralelizar leitura por arquivo

O DCL é sequencial por natureza (cada byte depende do histórico), então
não há paralelismo *dentro* de um arquivo. O padrão é paralelizar
*entre* arquivos:

```julia
caminhos = baixar(:sinasc, "PE"; anos = 2019:2023, quieto = true)
partes = asyncmap(caminhos; ntasks = Threads.nthreads()) do c
    materializar(ler(c; colunas = [:DTNASC, :CODMUNRES]))
end
```

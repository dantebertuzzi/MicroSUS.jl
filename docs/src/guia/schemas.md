# Schemas e tipagem

## Detecção automática

`schema = :auto` (default) deduz o sistema pelo prefixo do nome do
arquivo, via [`MicroSUS.detecta_sistema`](@ref):

| prefixo | sistema | exemplo |
|---|---|---|
| `DO` | `:sim` | `DOPE2023.dbc` |
| `DN` | `:sinasc` | `DNBA2022.dbc` |
| `RD`, `SP` | `:sih` | `RDPE2301.dbc` |
| `PA` | `:sia` | `PAPE2301.dbc` |
| `ST`, `LT`, `PF` | `:cnes` | `STPE2301.dbc` |

Se o prefixo não for reconhecido (arquivo renomeado, por exemplo),
force com `schema = :sim` etc., ou passe um `Dict` próprio.

## Tipos lógicos

Um schema é um `Dict{Symbol,Symbol}` de campo → tipo lógico:

| tipo lógico | vira | observações |
|---|---|---|
| `:texto` | `InlineStrings` | dimensionado pela largura do campo |
| `:pool` | `PooledArray` de `InlineStrings` | categóricas; `pool = false` rebaixa para `:texto` |
| `:inteiro` | `Union{Missing,Int32}` | parse direto dos bytes; vazio → `missing` |
| `:float` | `Union{Missing,Float64}` | idem |
| `:data_ddmmyyyy` | `Union{Missing,Date}` | SIM e SINASC |
| `:data_yyyymmdd` | `Union{Missing,Date}` | SIH e campos tipo `D` do DBF |
| `:idade_sim` | `Union{Missing,Float64}` | codificação do SIM → **anos** |

Campos **fora** do schema caem na tipagem do próprio DBF:
`N` → `:inteiro` ou `:float` (conforme decimais), `D` →
`:data_yyyymmdd`, `C` → `:texto`.

## A `IDADE` do SIM

O campo tem 3 dígitos: o primeiro é a **unidade**, os dois últimos o
valor. [`decodifica_idade_sim`](@ref) converte para anos:

| 1º dígito | unidade | exemplo | anos |
|---|---|---|---|
| 0 | minutos | `"030"` | 30 / 525 960 |
| 1 | horas | `"112"` | 12 / 8 766 |
| 2 | dias | `"230"` | 30 / 365,25 |
| 3 | meses | `"310"` | 10 / 12 |
| 4 | anos | `"425"` | 25,0 |
| 5 | 100 + valor | `"501"` | 101,0 |
| 9 | ignorada | `"999"` | `missing` |

## Schema próprio

Passe um `Dict` completo — ele **substitui** (não estende) o schema
automático:

```julia
meu = Dict(:DTOBITO => :data_ddmmyyyy,
           :CAUSABAS => :pool,
           :IDADE => :texto)      # quero os 3 dígitos crus
t = ler(caminho; schema = meu)
```

Ou estenda o registro global (afeta as próximas chamadas com
`schema = :auto`/`:sim`):

```julia
MicroSUS.SCHEMAS[:sim][:LINHAA] = :texto
```

## O que os schemas embutidos cobrem

Os campos mais usados de cada sistema — datas, numéricos e as
categóricas de alto tráfego (sexo, raça/cor, municípios, causa básica,
procedimento, diagnóstico...). A lista exata está em
[`MicroSUS.SCHEMAS`](@ref); os layouts oficiais completos ficam na
documentação de cada sistema no DATASUS. Campos não cobertos continuam
funcionando (tipagem do DBF) — o schema só melhora a ergonomia.

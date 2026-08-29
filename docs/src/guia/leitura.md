# Leitura: `ler`, filtro, partições

## Assinatura

```julia
ler(caminho; colunas = nothing, filtro = nothing, tamanho_lote = 100_000,
    schema = :auto, encoding = :auto, pool = true) -> TabelaDBC
```

Funciona com `.dbc` e `.dbf`. Devolve uma [`TabelaDBC`](@ref)
**preguiçosa** — nada é lido até a iteração.

| kwarg | default | efeito |
|---|---|---|
| `colunas` | `nothing` (todas) | `Vector{Symbol}`; campos fora da lista nem são materializados |
| `filtro` | `nothing` | `RegistroDBF -> Bool`, roda antes do parse das colunas |
| `tamanho_lote` | `100_000` | linhas por partição — o teto de memória do pipeline |
| `schema` | `:auto` | ver [Schemas e tipagem](schemas.md) |
| `encoding` | `:auto` | language driver do cabeçalho; DATASUS ⇒ `:cp850` |
| `pool` | `true` | `PooledArray` nas categóricas do schema |
| `ignorar_ausentes` | `false` | descarta colunas que não existem neste layout em vez de lançar erro |

## Materializar tudo

```julia
using DataFrames
df = DataFrame(ler(caminho))          # via Tables.columns
nt = materializar(ler(caminho))       # NamedTuple de vetores, sem DataFrames
```

## Selecionar colunas

```julia
t = ler(caminho; colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES])
```

A ordem pedida é a ordem das colunas na saída. Nome inexistente lança
`ArgumentError` listando os disponíveis (útil porque os layouts variam
entre anos).

## Layouts que mudam entre anos

Os layouts do DATASUS ganham e perdem campos. No SIH, o bloco
`DIAGSEC1`–`DIAGSEC9` só existe a partir de 2014; pedir `:DIAGSEC1` na leitura
de 2010 lança `ArgumentError`. Em séries longas isso obriga a inspecionar cada
arquivo antes de ler — ou a delegar:

```julia
t = ler(caminho; colunas = [:DT_INTER, :DIAG_PRINC, :DIAGSEC1],
        ignorar_ausentes = true)      # em 2010 vêm só as duas primeiras
```

As colunas descartadas saem por `@debug` (habilite com
`ENV["JULIA_DEBUG"] = "MicroSUS"` para vê-las). Se **nenhuma** das colunas
pedidas existir, ainda é erro — nesse caso o problema é outro: arquivo errado,
ou nome digitado errado.

Para decidir por conta própria, [`cabecalho`](@ref) lê só o cabeçalho, sem
descomprimir:

```julia
cab = cabecalho(caminho)
:DIAGSEC1 in keys(cab.indice)     # o campo existe neste ano?
```

## Filtrar linhas no leitor

O `filtro` recebe um [`MicroSUS.RegistroDBF`](@ref): uma visão sobre os
bytes do registro em que `r[:CAMPO]` devolve o texto do campo (trim +
transcodificação) **sob demanda** — só o campo consultado é
decodificado, e linhas rejeitadas não materializam nenhuma coluna.

```julia
# só óbitos por agressão (CVLI)
t = ler(caminho; filtro = r -> eh_agressao(r[:CAUSABAS]))

# só residentes em Petrolina
t = ler(caminho; filtro = r -> r[:CODMUNRES] == "261110")

# combinações — cada campo consultado custa um parse
t = ler(caminho; filtro = r -> r[:CODMUNRES] == "261110" &&
                               r[:SEXO] == "2")
```

O valor devolvido por `r[:CAMPO]` é sempre o **texto** do campo (a
tipagem do schema acontece depois, só nas colunas selecionadas das
linhas aprovadas) — compare com strings.

## Processar em lotes

```julia
using Tables
for lote in Tables.partitions(ler(caminho; tamanho_lote = 50_000))
    # `lote` é um NamedTuple de vetores — uma tabela Tables.jl válida.
    # Agregue aqui e descarte; a memória fica em O(tamanho_lote).
end
```

Cada lote é independente: dá para construir agregações incrementais
(contagens por grupo, histogramas, somas) sem nunca ter o arquivo
inteiro em memória.

## Inspecionar sem ler

```julia
cab = cabecalho(caminho)     # só o cabeçalho
cab.n_registros, cab.tamanho_registro
[c.nome for c in cab.campos]
```

E o `show` da `TabelaDBC` resume campos, tipos resolvidos, encoding e
se há filtro ativo:

```julia
julia> ler(caminho; colunas = [:DTOBITO, :IDADE])
TabelaDBC — DOPE2023.dbc
  registros (cabeçalho): 68437   encoding: cp850   lote: 100000
  colunas (2):
    DTOBITO     C(8)     → data_ddmmyyyy
    IDADE       C(3)     → idade_sim
```

## Notas

- Registros deletados (flag `0x2A`) são pulados automaticamente.
- A contagem do cabeçalho (`cab.n_registros`) pode diferir do total
  lido se houver deletados ou filtro.
- `pool = false` troca `PooledArray` por vetores planos de
  `InlineStrings` — útil se a coluna vai direto para um `groupby`
  do DuckDB, por exemplo.

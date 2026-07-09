# Conversão para Arrow

## `converter`

```julia
using MicroSUS, Arrow      # Arrow ativa a extensão condicional

caminho = baixar(:sim, "PE"; ano = 2023)
converter(caminho, "do_pe_2023.arrow")

# com os mesmos kwargs de `ler` — recorte já na conversão:
converter(caminho, "cvli_pe_2023.arrow";
          colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO],
          filtro  = r -> eh_agressao(r[:CAUSABAS]),
          tamanho_lote = 50_000)
```

A conversão é **streaming de ponta a ponta**: `Arrow.write` consome
`Tables.partitions(TabelaDBC)` e grava um *record batch* por lote.
Memória O(`tamanho_lote`) do `.dbc` até o `.arrow`, qualquer que seja
o tamanho do arquivo.

Sem `using Arrow`, chamar `converter` dá um `MethodError` com um hint
explicando o que carregar — o pacote base não depende de Arrow.

## Por que converter

O `.arrow` resultante é colunar, tipado e **memory-mapped**:

```julia
using Arrow, DataFrames
t = Arrow.Table("do_pe_2023.arrow")    # abre sem carregar na RAM
df = DataFrame(t)                       # zero-copy onde possível
```

E é o formato de entrada natural do DuckDB para consulta preguiçosa:

```sql
-- duckdb
SELECT CODMUNRES, count(*) AS obitos
FROM 'do_pe_*.arrow'
GROUP BY CODMUNRES
ORDER BY obitos DESC;
```

O fluxo recomendado para projetos multi-ano é converter uma vez e
consultar sempre:

```julia
using MicroSUS, Arrow
for ano in 2013:2023
    c = baixar(:sim, "PE"; ano = ano, quieto = true)
    converter(c, "sim_pe_$ano.arrow";
              colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO])
end
```

## Preservação de tipos

| no leitor | no Arrow |
|---|---|
| `Union{Missing,Date}` | `Date` (nullable) |
| `Union{Missing,Int32}` / `Float64` | `Int32` / `Float64` (nullable) |
| `PooledArray` | dictionary-encoded |
| `InlineStrings` | `String` |

A codificação por dicionário das categóricas sobrevive à ida e volta —
`Arrow.Table` devolve colunas pooled de novo.

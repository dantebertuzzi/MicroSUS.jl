# MicroSUS.jl

Microdados do DATASUS em Julia — leitura **streaming** de `.dbc`/`.dbf`
com memória constante, schemas tipados por sistema e interface Tables.jl.

O `.dbc` do DATASUS é um DBF com os registros comprimidos em PKWare DCL
("implode"). O descompressor daqui é um porte puro Julia do `blast.c`
de Mark Adler, em versão streaming: a janela de 4 KiB é emitida em
chunks, então um arquivo nacional multi-ano nunca precisa caber na RAM
— só o lote em processamento.

## Instalação

```julia
] dev caminho/para/MicroSUS.jl
```

## Uso

```julia
using MicroSUS, DataFrames

# download com cache local (Scratch.jl)
caminho = baixar(:sim, "PE"; ano = 2023)

# tudo tipado: datas ddmmyyyy → Date, IDADE do SIM → anos (Float64),
# categóricas → PooledArray, texto → InlineStrings, CP850 → UTF-8
df = DataFrame(ler(caminho))

# seleção de colunas + filtro DE LINHAS NO LEITOR
# (campos não pedidos nem viram String; o filtro parseia sob demanda)
t = ler(caminho;
        colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO],
        filtro  = r -> eh_agressao(r[:CAUSABAS]))   # CVLI: X85–Y09 + Y87.1
cvli = DataFrame(t)

# processamento em lotes (memória O(tamanho_lote))
for lote in Tables.partitions(ler(caminho; tamanho_lote = 50_000))
    # lote é um NamedTuple de vetores — uma tabela Tables.jl válida
end

# .dbc → Arrow em streaming (extensão condicional)
using Arrow
converter(caminho, "do_pe_2023.arrow";
          colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES])
```

Vários períodos em paralelo:

```julia
caminhos = baixar(:sim, "PE"; anos = 2013:2023)
caminhos = baixar(:sih, "PE"; anos = [2023], meses = 1:12)
```

## Schemas

`schema = :auto` deduz o sistema pelo prefixo do arquivo
(`DO` → `:sim`, `DN` → `:sinasc`, `RD`/`SP` → `:sih`, `PA` → `:sia`,
`ST` → `:cnes`). A tipagem cobre datas (`ddmmyyyy` no SIM/SINASC,
`aaaammdd` no SIH), numéricos e as categóricas usuais. Você pode passar
um `Dict{Symbol,Symbol}` próprio com os tipos lógicos
(`:texto`, `:pool`, `:inteiro`, `:float`, `:data_ddmmyyyy`,
`:data_yyyymmdd`, `:idade_sim`).

A `IDADE` do SIM (unidade no 1º dígito) vira anos:
`decodifica_idade_sim("425") == 25.0`, `"501" → 101.0`,
`"310" → 10/12`, `"999" → missing`.

## Dimensões auxiliares

```julia
codigo7_ibge(261110)          # 2611101 (Petrolina — dígito verificador)
codigo6_ibge(2611101)         # 261110, validando o DV
capitulo_cid10("X954")        # (numeral = "XX", nome = "Causas externas ...")
eh_agressao("X954")           # true
```

## Utilidades de baixo nível

```julia
descomprime_dbc_para_dbf("DOPE2023.dbc", "DOPE2023.dbf")  # streaming
dcl_descomprime(io, chunk -> ...)                          # sink genérico
MicroSUS.cabecalho("DOPE2023.dbc")                         # só o cabeçalho
```

## Notas

- Encoding: o language driver do cabeçalho decide; `0x00` cai em CP850,
  que é a prática do DATASUS. Sobrescreva com `encoding = :latin1` etc.
- O filtro roda **antes** do parse das colunas selecionadas; `r[:CAMPO]`
  devolve o texto (trim + transcodificação) só do campo consultado.
- `pool = false` desliga o PooledArray se você prefere vetores planos.

## Licença

MIT

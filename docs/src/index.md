# MicroSUS.jl

Microdados do DATASUS em Julia — leitura **streaming** de `.dbc`/`.dbf`
com memória constante, schemas tipados por sistema (SIM, SINASC, SIH,
SIA, CNES), transcodificação CP850 → UTF-8, download com cache local e
interface Tables.jl com partições.

## Instalação

```julia
] dev caminho/para/MicroSUS.jl
] test MicroSUS          # suíte completa, sem depender de rede
```

Julia ≥ 1.9. Dependências: Tables, InlineStrings, PooledArrays,
Scratch, Downloads, Dates. Arrow é opcional (extensão condicional).

## Início rápido

```julia
using MicroSUS, DataFrames

# download com cache local — não rebaixa o que já tem
caminho = baixar(:sim, "PE"; ano = 2023)

# tudo tipado: datas → Date, IDADE do SIM → anos, categóricas →
# PooledArray, texto → InlineStrings, CP850 → UTF-8
df = DataFrame(ler(caminho))

# seleção de colunas + filtro de linhas NO LEITOR
t = ler(caminho;
        colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO],
        filtro  = r -> eh_agressao(r[:CAUSABAS]))   # CVLI: X85–Y09 + Y87.1
cvli = DataFrame(t)

# processamento em lotes, memória constante
using Tables
for lote in Tables.partitions(ler(caminho; tamanho_lote = 50_000))
    # `lote` é um NamedTuple de vetores — tabela Tables.jl válida
end

# .dbc → Arrow em streaming
using Arrow
converter(caminho, "do_pe_2023.arrow")
```

## Mapa da documentação

- [O formato .dbc e o streaming](formato.md) — por que os microdados
  "pesam", como o `.dbc` funciona por dentro e a arquitetura de
  memória constante deste pacote.
- [Leitura](guia/leitura.md) — `ler` em detalhe: colunas, filtro,
  partições, materialização.
- [Schemas e tipagem](guia/schemas.md) — detecção por prefixo, tipos
  lógicos, a `IDADE` do SIM, schemas próprios.
- [Download e FTP](guia/download.md) — `baixar`, cache, caminhos
  atuais do FTP, dados preliminares.
- [Conversão para Arrow](guia/arrow.md) — `converter` e o fluxo
  dbc → Arrow → DuckDB/consulta preguiçosa.
- [Dimensões](guia/dimensoes.md) — dígito verificador IBGE,
  capítulos CID-10, recorte de agressões (CVLI).
- [Referência da API](api.md) — todos os exports, com assinaturas.
- [Internos](internos.md) — o descompressor DCL, o pipeline de
  canais, encoding, e as funções não exportadas.

## Filosofia

O pacote faz uma coisa: colocar microdados do DATASUS dentro do
ecossistema Tables.jl **sem exigir que eles caibam na RAM**. Análise,
join com dimensões nominais (DTB do IBGE, CID-10 completa, CBO) e
visualização ficam com as ferramentas que você já usa — DataFrames,
Arrow, DuckDB, Makie.

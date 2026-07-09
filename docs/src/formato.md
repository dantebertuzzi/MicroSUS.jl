# O formato `.dbc` e o streaming

## Anatomia de um `.dbc`

Um `.dbc` do DATASUS não é um formato próprio de compressão — é um
DBF (dBase III) com uma cirurgia:

```
┌────────────────────────────┐
│ cabeçalho DBF em claro     │  ← contagem de registros, larguras,
│ (tamanho nos bytes 8–9)    │    descritores de campo, language driver
├────────────────────────────┤
│ 4 bytes (CRC32)            │  ← ignorados na leitura
├────────────────────────────┤
│ registros comprimidos em   │  ← PKWare DCL ("implode"),
│ PKWare DCL                 │    o mesmo do PKZIP 1.x
└────────────────────────────┘
```

O corpo descomprimido é o corpo do DBF original: registros de largura
fixa, byte 0 = flag de deleção (`0x20` ativo, `0x2A` deletado), campos
concatenados sem separador, e um `0x1A` de EOF no final.

## Por que os microdados "pesam"

Duas multiplicações em cascata:

1. **Expansão do DCL**: o DBF de largura fixa comprime muito bem
   (campos com espaços, códigos repetidos), então o `.dbc` expande
   tipicamente 4–8× ao descomprimir.
2. **Materialização como `String`**: cada `String` em Julia carrega
   ~40 bytes de overhead de objeto. Um DBF de 60 campos × 1 milhão de
   registros materializado ingenuamente vira dezenas de GB de pressão
   no GC. (O R mitiga isso por acidente: factors são pooled e há um
   string pool global.)

O MicroSUS ataca as duas pontas: nunca materializa o arquivo
descomprimido (streaming) e, quando materializa valores, usa
`InlineStrings` (sem ponteiro) e `PooledArray` (categóricas).

## O descompressor DCL

`src/dcl.jl` é um porte puro Julia do `blast.c` de Mark Adler (o
descompressor de referência do formato, usado pelo `read.dbc` do R via
C). Propriedades que importam aqui:

- O DCL é um LZ77 com janela de até 4 KiB e códigos Huffman fixos
  (tabelas embutidas no formato) — **descomprime incrementalmente por
  natureza**.
- O porte emite a janela a um `sink(chunk)` a cada preenchimento:
  memória O(1) em relação ao arquivo, exatamente a arquitetura do
  `outfun` do blast original.
- A cópia de matches é byte a byte para preservar a semântica de
  sobreposição (`dist < len` ⇒ repetição de padrão) e lida com o
  wrap circular da janela.

## O pipeline

```
.dbc ──DCL, chunks de 4 KiB──▶ montagem de registros ──▶ filtro ──▶ parse ──▶ lotes
      (task própria)            (atravessa fronteiras     (campo     (só as     (Channel de
                                 de chunk)                 sob        colunas    NamedTuples)
                                                           demanda)   pedidas)
```

Cada estágio é encadeado por `Channel`s com buffer pequeno, então o
*backpressure* é automático: se o consumidor (seu `for` sobre
`Tables.partitions`, ou o `Arrow.write`) desacelera, a descompressão
espera. O teto de memória do processo é `O(tamanho_lote)` — o lote em
construção mais um em trânsito — independente do tamanho do arquivo.

Consequência prática: um SINASC nacional multi-ano, ou o recorte de um
único município dentro do DNBA inteiro, passam pelo leitor de um
notebook sem drama.

## Ordem das otimizações no leitor

Para cada registro bruto:

1. **flag de deleção** — registros `0x2A` são descartados antes de
   qualquer coisa;
2. **`filtro`** — recebe um [`MicroSUS.RegistroDBF`](@ref), uma visão
   leve sobre os bytes; `r[:CAMPO]` decodifica só o campo consultado.
   Linhas rejeitadas não materializam nenhuma coluna;
3. **parse das colunas selecionadas** — numéricos e datas são
   parseados direto dos bytes (sem `String` intermediária); texto passa
   pelo fast path ASCII e só paga transcodificação quando há byte
   ≥ `0x80`.

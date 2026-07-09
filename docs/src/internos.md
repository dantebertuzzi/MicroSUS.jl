# Internos

Funções e estruturas não exportadas, documentadas para quem quiser
estender o pacote (ou entender o pipeline). Nada aqui é API estável.

## Pipeline de leitura

```@docs
MicroSUS.canal_registros
MicroSUS.abre_dbc
MicroSUS.le_cabecalho_dbf
MicroSUS.RegistroDBF
```

O fluxo completo: [`MicroSUS.abre_dbc`](@ref) lê o cabeçalho em claro e
posiciona o `IO` no fluxo DCL; [`dcl_descomprime`](@ref) emite chunks
de ≤ 4 KiB; [`MicroSUS.canal_registros`](@ref) monta registros de
largura fixa atravessando fronteiras de chunk e emite lotes de
registros brutos por um `Channel`; `MicroSUS._canal_lotes` (em
`src/tables.jl`) aplica filtro e parse e emite `NamedTuple`s prontos.

## Encoding

```@docs
MicroSUS.decodifica_texto
MicroSUS.encoding_do_ldid
```

As tabelas `MicroSUS._CP850_ALTA` (128 caracteres da metade alta do
CP850) e `MicroSUS._CP1252_80_9F` vivem em `src/encoding.jl`. O fast
path ASCII evita qualquer lookup quando o campo não tem byte ≥ `0x80`.

## O descompressor DCL

O porte do `blast.c` está em `src/dcl.jl`, isolado do resto — pode ser
usado para qualquer fluxo PKWare DCL, não só DATASUS:

- `MicroSUS._Huffman` / `MicroSUS._constroi`: tabelas canônicas a
  partir da representação compacta do formato (byte = repetições − 1
  no nibble alto, comprimento no baixo);
- `MicroSUS._decodifica`: decodificação bit a bit com os códigos
  **invertidos** (peculiaridade do PKWare);
- `MicroSUS._bits`: buffer de bits LSB-first;
- janela circular de 4 KiB (`_MAXWIN`) com flush ao `sink` — a razão
  da memória O(1).

Os parâmetros do formato: `lit` (literais crus vs. codificados),
`dict` ∈ 4..6 (log₂ do dicionário − 6), comprimentos via
`_LEN_BASE`/`_LEN_EXTRA`, fim de fluxo em `len == 519`.

## Parsers de bytes

Em `src/schema.jl`: `MicroSUS._parse_int`, `MicroSUS._parse_float` e
`MicroSUS._parse_data` operam direto no `Vector{UInt8}` do registro
(offsets do [`CampoDBF`](@ref)), sem `String` intermediária. Vazio,
não-dígito ou data impossível → `missing`, nunca exceção.

## O compressor dos testes

`test/runtests.jl` contém um compressor DCL mínimo (`comprime_dcl`):
literais crus, matches e o código de fim, com os códigos canônicos
computados das mesmas tabelas do descompressor e emitidos MSB-first
invertidos. Ele existe só para permitir round-trip real nos testes —
não é um compressor de verdade (não procura matches), e por isso vive
fora de `src/`.

## Invariantes úteis para PRs

- Nenhum estágio do pipeline pode reter mais que O(`tamanho_lote`).
- `filtro` nunca deve disparar parse de campo não consultado.
- Campo fora do schema precisa continuar legível (tipagem do DBF).
- `] test MicroSUS` roda sem rede.

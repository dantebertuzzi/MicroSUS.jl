# Internos

Funções e estruturas não exportadas, documentadas para quem quiser
estender o pacote (ou entender o pipeline). Nada aqui é API estável.

## Pipeline de leitura

```@docs
MicroSUS.canal_registros
MicroSUS.LoteRegistros
MicroSUS.abre_dbc
MicroSUS.le_cabecalho_dbf
MicroSUS.RegistroDBF
```

O fluxo completo: [`MicroSUS.abre_dbc`](@ref) lê o cabeçalho em claro e
posiciona o `IO` no fluxo DCL; [`dcl_descomprime`](@ref) emite chunks
de ≤ 4 KiB; [`MicroSUS.canal_registros`](@ref) monta registros de
largura fixa atravessando fronteiras de chunk e emite lotes de
registros brutos, contíguos num buffer só ([`MicroSUS.LoteRegistros`](@ref)), por um `Channel`; `MicroSUS._canal_lotes` (em
`src/tables.jl`) aplica o filtro e junta os registros aceitos em lotes de
`tamanho_lote` (`MicroSUS._junta_lotes`), converte cada lote por blocos de
4 MiB (`MicroSUS._converte_lote`) e emite `NamedTuple`s prontos.

Os buffers de registros são reaproveitados: o juntador usa sempre o mesmo,
e devolve os do montador por um canal de livres (o `livres` de
`canal_registros`). Um lote entregue à conversão só vale durante a
chamada — a conversão copia tudo o que lê.

## Helpers de padronização

Usados por [`process_sim`](@ref), [`process_sinasc`](@ref),
[`process_sih`](@ref), [`process_sinan`](@ref) e [`process_cnes`](@ref); são o que você reaproveita ao escrever a rotina de uma
fonte ainda não coberta.

```@docs
MicroSUS.processar_fonte
MicroSUS.rotular!
MicroSUS.para_data!
MicroSUS.para_int!
```

`rotular!` converte código **não mapeado em `missing`**. É deliberado — "9",
"99" e afins significam "ignorado" —, mas implica que um dicionário incompleto
apaga dados válidos em silêncio. Ao escrever um dicionário novo, cubra o
domínio inteiro ou deixe a coluna crua.

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
- `MicroSUS._decodifica`: decodifica os códigos de até 8 bits pela
  tabela `rapida` de cada `_Huffman` (indexada pelos próximos 8 bits do
  fluxo) e cai em `MicroSUS._decodifica_lento`, bit a bit, nos mais
  longos; os códigos vêm **invertidos** (peculiaridade do PKWare);
- `MicroSUS._bits`: bits LSB-first num `UInt64`, recarregado de um buffer
  de entrada de 64 KiB (`_enche!`/`_recarrega!`);
- janela circular de 4 KiB (`_MAXWIN`) com flush ao `sink` — a razão
  da memória O(1).

Os parâmetros do formato: `lit` (literais crus vs. codificados),
`dict` ∈ 4..6 (log₂ do dicionário − 6), comprimentos via
`_LEN_BASE`/`_LEN_EXTRA`, fim de fluxo em `len == 519`.

## Parsers de bytes

Em `src/schema.jl`: `MicroSUS._parse_int`, `MicroSUS._parse_float` e
`MicroSUS._parse_data` operam direto nos bytes do lote (o deslocamento do
registro mais o offset do [`CampoDBF`](@ref)), sem `String` intermediária. Vazio,
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
- Nada pode guardar uma referência a um `LoteRegistros` depois de
  convertê-lo: o buffer é reaproveitado no lote seguinte.
- `filtro` nunca deve disparar parse de campo não consultado.
- Campo fora do schema precisa continuar legível (tipagem do DBF).
- `] test MicroSUS` roda sem rede.

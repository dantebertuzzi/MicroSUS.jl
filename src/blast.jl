# blast.jl — Descompressor PKWare DCL "implode" (algoritmo *explode*).
#
# Os arquivos .dbc do DATASUS são arquivos .dbf cujo bloco de registros foi
# comprimido com o algoritmo "implode" da PKWare Data Compression Library
# (o mesmo formato tratado pelo blast.c de Mark Adler e pela biblioteca
# usada pelo read.dbc do R). Esta é uma implementação independente em Julia
# puro, escrita a partir da especificação pública do formato.
#
# Formato do fluxo comprimido:
#   byte 0 : flag de literais (0 = literais crus de 8 bits; 1 = literais
#            codificados com Huffman)
#   byte 1 : log2 do tamanho do dicionário menos 6 (4, 5 ou 6 →
#            1024/2048/4096 bytes)
#   depois : fluxo de bits LSB-first; a cada passo, 1 bit decide entre
#            literal (0) ou par comprimento/distância (1). Os códigos de
#            Huffman são canônicos, fixos e armazenados com bits invertidos.
#   fim    : par com comprimento 519 encerra o fluxo.

"""
    DBCError(msg)

Erro lançado quando um arquivo `.dbc` está corrompido, truncado ou não segue
o formato esperado (DBF + PKWare DCL).
"""
struct DBCError <: Exception
    msg::String
end

Base.showerror(io::IO, e::DBCError) = print(io, "DBCError: ", e.msg)

const MAXBITS = 13

# Tabelas fixas do formato PKWare DCL, em codificação run-length:
# cada byte b representa (b >> 4) + 1 símbolos consecutivos com códigos de
# comprimento b & 0x0f bits.
const LITLEN = UInt8[
    11, 124, 8, 7, 28, 7, 188, 13, 76, 4, 10, 8, 12, 10, 12, 10, 8, 23, 8,
    9, 7, 6, 7, 8, 7, 6, 55, 8, 23, 24, 12, 11, 7, 9, 11, 12, 6, 7, 22, 5,
    7, 24, 6, 11, 9, 6, 7, 22, 7, 11, 38, 7, 9, 8, 25, 11, 8, 11, 9, 12,
    8, 12, 5, 38, 5, 38, 5, 11, 7, 5, 6, 21, 6, 10, 53, 8, 7, 24, 10, 27,
    44, 253, 253, 253, 252, 252, 252, 13, 12, 45, 12, 45, 12, 61, 12, 45,
    44, 173,
]
const LENLEN = UInt8[2, 35, 36, 53, 38, 23]
const DISTLEN = UInt8[2, 20, 53, 230, 247, 151, 248]

# Comprimento = BASE[símbolo + 1] + bits extras (EXTRA[símbolo + 1] bits).
const BASE  = Int[3, 2, 4, 5, 6, 7, 8, 9, 10, 12, 16, 24, 40, 72, 136, 264]
const EXTRA = Int[0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]

"""
Código de Huffman canônico pronto para decodificação.

- `count[len + 1]`: número de códigos com comprimento `len` bits;
- `symbol`: símbolos em ordem canônica.
"""
struct Huffman
    count::Vector{Int}
    symbol::Vector{Int}
end

"""
    construir_huffman(rep) -> Huffman

Expande uma tabela run-length de comprimentos de código e monta as
estruturas de decodificação canônica, validando que o código é completo.
"""
function construir_huffman(rep::Vector{UInt8})
    comprimentos = Int[]
    for b in rep
        n = (b >> 4) + 1
        append!(comprimentos, fill(Int(b & 0x0f), n))
    end

    count = zeros(Int, MAXBITS + 1)
    for l in comprimentos
        count[l + 1] += 1
    end

    # Verifica que o conjunto de comprimentos forma um código completo.
    restante = 1
    for len in 1:MAXBITS
        restante <<= 1
        restante -= count[len + 1]
        restante < 0 && throw(DBCError("tabela de Huffman com excesso de códigos"))
    end

    offs = zeros(Int, MAXBITS)
    for len in 1:MAXBITS-1
        offs[len + 1] = offs[len] + count[len + 1]
    end

    symbol = zeros(Int, length(comprimentos))
    for (i, l) in enumerate(comprimentos)
        if l != 0
            symbol[offs[l] + 1] = i - 1   # símbolos são 0-based no formato
            offs[l] += 1
        end
    end

    return Huffman(count, symbol)
end

const LITCODE  = construir_huffman(LITLEN)
const LENCODE  = construir_huffman(LENLEN)
const DISTCODE = construir_huffman(DISTLEN)

"""
Leitor de bits LSB-first sobre um vetor de bytes.
"""
mutable struct BitReader
    data::Vector{UInt8}
    pos::Int      # próximo byte a consumir (1-based)
    bitbuf::Int   # buffer de bits
    bitcnt::Int   # bits válidos no buffer
end

BitReader(data::Vector{UInt8}) = BitReader(data, 1, 0, 0)

@inline function proximo_byte!(s::BitReader)
    s.pos > length(s.data) && throw(DBCError("fluxo comprimido truncado"))
    b = Int(s.data[s.pos])
    s.pos += 1
    return b
end

"""
    bits!(s, n) -> Int

Lê `n` bits do fluxo, LSB-first.
"""
function bits!(s::BitReader, n::Int)
    val = s.bitbuf
    while s.bitcnt < n
        val |= proximo_byte!(s) << s.bitcnt
        s.bitcnt += 8
    end
    s.bitbuf = val >> n
    s.bitcnt -= n
    return val & ((1 << n) - 1)
end

"""
    decodificar!(s, h) -> Int

Decodifica um símbolo Huffman canônico. Os bits do código chegam invertidos
no fluxo (particularidade do formato PKWare DCL), por isso o `⊻ 1`.
"""
function decodificar!(s::BitReader, h::Huffman)
    len = 1
    code = 0
    first = 0
    index = 0
    bitbuf = s.bitbuf
    restante = s.bitcnt

    while true
        while restante > 0
            restante -= 1
            code |= (bitbuf & 1) ⊻ 1
            bitbuf >>= 1
            cnt = h.count[len + 1]
            if code - cnt < first
                s.bitbuf = bitbuf
                s.bitcnt = (s.bitcnt - len) & 7
                return h.symbol[index + (code - first) + 1]
            end
            index += cnt
            first = (first + cnt) << 1
            code <<= 1
            len += 1
        end
        restante = (MAXBITS + 1) - len
        restante == 0 && break
        bitbuf = proximo_byte!(s)
        restante > 8 && (restante = 8)
    end

    throw(DBCError("código de Huffman inválido no fluxo comprimido"))
end

"""
    blast(comprimido::Vector{UInt8}; sizehint = 0) -> Vector{UInt8}

Descomprime um bloco no formato PKWare DCL ("implode"). É o algoritmo usado
no corpo dos arquivos `.dbc` do DATASUS. `sizehint` pré-aloca a saída quando
o tamanho descomprimido é conhecido (ex.: calculado pelo header DBF).
"""
function blast(comprimido::Vector{UInt8}; sizehint::Integer = 0)
    s = BitReader(comprimido)

    lit = bits!(s, 8)
    lit > 1 && throw(DBCError("flag de literais inválida ($lit); o arquivo não parece ser PKWare DCL"))

    dict = bits!(s, 8)
    (4 <= dict <= 6) || throw(DBCError("tamanho de dicionário inválido ($dict)"))

    out = UInt8[]
    sizehint > 0 && sizehint!(out, sizehint)

    while true
        if bits!(s, 1) == 1
            # Par comprimento/distância.
            sym = decodificar!(s, LENCODE)
            len = BASE[sym + 1] + bits!(s, EXTRA[sym + 1])
            len == 519 && break   # código de fim de fluxo

            nbits = len == 2 ? 2 : dict
            dist = (decodificar!(s, DISTCODE) << nbits) + bits!(s, nbits) + 1
            dist > length(out) &&
                throw(DBCError("distância de cópia aponta antes do início da saída"))

            # Cópia byte a byte: correta inclusive quando dist < len
            # (sobreposição, semântica LZ77).
            @inbounds for _ in 1:len
                push!(out, out[end - dist + 1])
            end
        else
            # Literal: cru (8 bits) ou codificado, conforme a flag inicial.
            b = lit == 1 ? decodificar!(s, LITCODE) : bits!(s, 8)
            push!(out, UInt8(b))
        end
    end

    return out
end

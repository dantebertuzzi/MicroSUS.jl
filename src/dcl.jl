# ─────────────────────────────────────────────────────────────────────
# PKWare DCL "explode" — porte puro Julia do blast.c (Mark Adler),
# em versão STREAMING: a janela de 4 KiB é emitida ao `sink` a cada
# preenchimento, então a memória é O(1) em relação ao arquivo.
# ─────────────────────────────────────────────────────────────────────

const _MAXBITS = 13     # maior comprimento de código Huffman
const _MAXWIN = 4096    # janela/dicionário máximo

struct _Huffman
    count::Vector{Int}   # count[len + 1] = nº de códigos com comprimento len
    symbol::Vector{Int}  # símbolos em ordem canônica
end

# Constrói tabela canônica a partir da representação compacta do PKWare:
# cada byte = (repetições - 1) << 4 | comprimento.
function _constroi(rep::Vector{UInt8}, n::Int)
    lens = Int[]
    sizehint!(lens, n)
    for r in rep
        len = Int(r & 0x0f)
        for _ in 1:(Int(r >> 4) + 1)
            push!(lens, len)
        end
    end
    @assert length(lens) == n "tabela compacta inconsistente"

    count = zeros(Int, _MAXBITS + 1)
    for l in lens
        count[l + 1] += 1
    end

    # verifica que o conjunto de comprimentos é completo (código válido)
    left = 1
    for len in 1:_MAXBITS
        left <<= 1
        left -= count[len + 1]
        left < 0 && error("conjunto de códigos Huffman sobre-subscrito")
    end

    starts = zeros(Int, _MAXBITS)
    off = 0
    for len in 1:_MAXBITS
        starts[len] = off
        off += count[len + 1]
    end
    symbol = zeros(Int, off)
    pos = copy(starts)
    for (sym, l) in enumerate(lens)
        if l != 0
            symbol[pos[l] + 1] = sym - 1
            pos[l] += 1
        end
    end
    return _Huffman(count, symbol)
end

# tabelas fixas do formato (idênticas ao blast.c)
const _LITLEN = UInt8[
    11, 124, 8, 7, 28, 7, 188, 13, 76, 4, 10, 8, 12, 10, 12, 10, 8, 23, 8,
    9, 7, 6, 7, 8, 7, 6, 55, 8, 23, 24, 12, 11, 7, 9, 11, 12, 6, 7, 22, 5,
    7, 24, 6, 11, 9, 6, 7, 22, 7, 11, 38, 7, 9, 8, 25, 11, 8, 11, 9, 12,
    8, 12, 5, 38, 5, 38, 5, 11, 7, 5, 6, 21, 6, 10, 53, 8, 7, 24, 10, 27,
    44, 253, 253, 253, 252, 252, 252, 13, 12, 45, 12, 45, 12, 61, 12, 45,
    44, 173]
const _LENLEN = UInt8[2, 35, 36, 53, 38, 23]
const _DISTLEN = UInt8[2, 20, 53, 230, 247, 151, 248]
const _LEN_BASE = Int[3, 2, 4, 5, 6, 7, 8, 9, 10, 12, 16, 24, 40, 72, 136, 264]
const _LEN_EXTRA = Int[0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8]

const _LITCODE = _constroi(_LITLEN, 256)
const _LENCODE = _constroi(_LENLEN, 16)
const _DISTCODE = _constroi(_DISTLEN, 64)

mutable struct _DCLState{I<:IO}
    io::I
    bitbuf::Int
    bitcnt::Int
    janela::Vector{UInt8}
    prox::Int          # bytes preenchidos na janela (0 .. _MAXWIN)
    primeira::Bool     # ainda estamos na primeira janela?
end

_DCLState(io::IO) = _DCLState(io, 0, 0, Vector{UInt8}(undef, _MAXWIN), 0, true)

@inline function _bits(s::_DCLState, need::Int)
    val = s.bitbuf
    while s.bitcnt < need
        val |= Int(read(s.io, UInt8)) << s.bitcnt
        s.bitcnt += 8
    end
    s.bitbuf = val >> need
    s.bitcnt -= need
    return val & ((1 << need) - 1)
end

# Decodifica um símbolo. Os códigos do PKWare são armazenados INVERTIDOS
# no fluxo de bits; o primeiro bit lido é o mais significativo do código.
@inline function _decodifica(s::_DCLState, h::_Huffman)
    code = 0
    first = 0
    index = 0
    for len in 1:_MAXBITS
        code |= _bits(s, 1) ⊻ 1
        cnt = h.count[len + 1]
        if code - first < cnt
            return h.symbol[index + code - first + 1]
        end
        index += cnt
        first = (first + cnt) << 1
        code <<= 1
    end
    error("fluxo DCL corrompido: código Huffman inválido")
end

@inline function _flush!(s::_DCLState, sink)
    if s.prox == _MAXWIN
        sink(view(s.janela, 1:_MAXWIN))
        s.prox = 0
        s.primeira = false
    end
    return nothing
end

"""
    dcl_descomprime(io::IO, sink) -> Int

Descomprime um fluxo PKWare DCL ("implode") lido de `io`, chamando
`sink(chunk::AbstractVector{UInt8})` com blocos de até 4096 bytes à
medida que a janela enche. Retorna o total de bytes descomprimidos.
Memória constante (janela de 4 KiB). Porte do `blast.c`.
"""
function dcl_descomprime(io::IO, sink)
    s = _DCLState(io)

    lit = _bits(s, 8)          # 0 = literais crus; 1 = literais codificados
    lit ≤ 1 || error("fluxo DCL inválido (flag de literais = $lit)")
    dict = _bits(s, 8)         # log2(dicionário) - 6
    4 ≤ dict ≤ 6 || error("fluxo DCL inválido (dicionário = $dict)")

    total = 0
    while true
        if _bits(s, 1) == 1
            # par comprimento/distância
            sym = _decodifica(s, _LENCODE)
            len = _LEN_BASE[sym + 1] + _bits(s, _LEN_EXTRA[sym + 1])
            len == 519 && break                       # código de fim
            nb = len == 2 ? 2 : dict
            dist = (_decodifica(s, _DISTCODE) << nb) + _bits(s, nb) + 1
            (s.primeira && dist > s.prox) &&
                error("fluxo DCL corrompido: distância antes do início")

            total += len
            while len > 0
                fromi = s.prox - dist        # posição 0-based na janela
                avail = _MAXWIN
                if s.prox < dist             # histórico dá a volta na janela
                    fromi += _MAXWIN
                    avail = dist
                end
                avail -= s.prox
                n = min(avail, len)
                len -= n
                # cópia byte a byte, para a frente: preserva a semântica de
                # sobreposição (dist < len ⇒ repetição de padrão)
                @inbounds for k in 1:n
                    s.janela[s.prox + k] = s.janela[fromi + k]
                end
                s.prox += n
                _flush!(s, sink)
            end
        else
            # literal
            b = lit == 1 ? _decodifica(s, _LITCODE) : _bits(s, 8)
            s.prox += 1
            @inbounds s.janela[s.prox] = b % UInt8
            total += 1
            _flush!(s, sink)
        end
    end

    s.prox > 0 && sink(view(s.janela, 1:s.prox))
    return total
end

"""
    dcl_descomprime(io::IO) -> Vector{UInt8}

Versão de conveniência que materializa tudo num vetor (para arquivos
pequenos ou testes). Prefira a versão com `sink` em produção.
"""
function dcl_descomprime(io::IO)
    out = UInt8[]
    dcl_descomprime(io, chunk -> append!(out, chunk))
    return out
end

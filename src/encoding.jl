# ─────────────────────────────────────────────────────────────────────
# Transcodificação para UTF-8. DBFs do DATASUS circulam em CP850 (DOS,
# o mais comum) ou CP1252/Latin-1. Materializar os bytes crus como
# String corrompe acentos silenciosamente — daí o fast path ASCII e a
# tabela de mapeamento para a metade alta.
# ─────────────────────────────────────────────────────────────────────

# CP850, bytes 0x80–0xFF (ordem oficial da code page)
const _CP850_ALTA = [
    'Ç','ü','é','â','ä','à','å','ç','ê','ë','è','ï','î','ì','Ä','Å',
    'É','æ','Æ','ô','ö','ò','û','ù','ÿ','Ö','Ü','ø','£','Ø','×','ƒ',
    'á','í','ó','ú','ñ','Ñ','ª','º','¿','®','¬','½','¼','¡','«','»',
    '░','▒','▓','│','┤','Á','Â','À','©','╣','║','╗','╝','¢','¥','┐',
    '└','┴','┬','├','─','┼','ã','Ã','╚','╔','╩','╦','╠','═','╬','¤',
    'ð','Ð','Ê','Ë','È','ı','Í','Î','Ï','┘','┌','█','▄','¦','Ì','▀',
    'Ó','ß','Ô','Ò','õ','Õ','µ','þ','Þ','Ú','Û','Ù','ý','Ý','¯','´',
    '\u00ad','±','‗','¾','¶','§','÷','¸','°','¨','·','¹','³','²','■','\u00a0',
]

# CP1252, bytes 0x80–0x9F (o resto coincide com Latin-1)
const _CP1252_80_9F = [
    '€','\u0081','‚','ƒ','„','…','†','‡','ˆ','‰','Š','‹','Œ','\u008d','Ž','\u008f',
    '\u0090','‘','’','“','”','•','–','—','˜','™','š','›','œ','\u009d','ž','Ÿ',
]

@inline _byte_para_char(b::UInt8, ::Val{:cp850}) =
    b < 0x80 ? Char(b) : _CP850_ALTA[b - 0x7f]
@inline _byte_para_char(b::UInt8, ::Val{:latin1}) = Char(b)
@inline _byte_para_char(b::UInt8, ::Val{:cp1252}) =
    b < 0x80 ? Char(b) : (b ≤ 0x9f ? _CP1252_80_9F[b - 0x7f] : Char(b))

"""
    decodifica_texto(bytes, lo, hi, encoding::Symbol) -> String

Converte `bytes[lo:hi]` para `String` UTF-8, removendo espaços à
direita. `encoding` ∈ (:cp850, :latin1, :cp1252, :utf8, :raw).
Fast path: se todos os bytes forem ASCII (caso da imensa maioria dos
campos do DATASUS), não há tabela envolvida.
"""
function decodifica_texto(bytes::AbstractVector{UInt8}, lo::Int, hi::Int,
                          encoding::Symbol)
    # trim de espaços/NULs à direita
    while hi ≥ lo && (bytes[hi] == 0x20 || bytes[hi] == 0x00)
        hi -= 1
    end
    hi < lo && return ""

    ascii = true
    @inbounds for i in lo:hi
        if bytes[i] ≥ 0x80
            ascii = false
            break
        end
    end
    if ascii || encoding === :utf8 || encoding === :raw
        return String(bytes[lo:hi])
    end

    io = IOBuffer(sizehint = 2 * (hi - lo + 1))
    v = encoding === :cp850 ? Val(:cp850) :
        encoding === :latin1 ? Val(:latin1) :
        encoding === :cp1252 ? Val(:cp1252) :
        throw(ArgumentError("encoding desconhecido: $encoding"))
    @inbounds for i in lo:hi
        print(io, _byte_para_char(bytes[i], v))
    end
    return String(take!(io))
end

# Language driver ID (byte 29 do cabeçalho DBF) → encoding.
# 0x00 = não especificado: DATASUS na prática é CP850.
function encoding_do_ldid(ldid::UInt8)
    ldid == 0x02 && return :cp850
    ldid == 0x64 && return :cp850    # "DOS 852"? na dúvida, DOS multilíngue
    ldid == 0x03 && return :cp1252
    ldid == 0x57 && return :cp1252   # ANSI
    return :cp850                     # default sensato para DATASUS
end

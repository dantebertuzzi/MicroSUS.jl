# ─────────────────────────────────────────────────────────────────────
# DBF (dBase III): cabeçalho, descritores de campo, offsets fixos.
# ─────────────────────────────────────────────────────────────────────

struct CampoDBF
    nome::Symbol
    tipo::Char       # 'C' texto, 'N' numérico, 'D' data AAAAMMDD, 'L', 'F'
    largura::Int
    decimais::Int
    offset::Int      # offset 0-based dentro do registro (byte 0 = flag deleção)
end

struct CabecalhoDBF
    n_registros::Int
    tamanho_cabecalho::Int
    tamanho_registro::Int
    ldid::UInt8                       # language driver id (encoding)
    campos::Vector{CampoDBF}
    indice::Dict{Symbol,CampoDBF}
end

_u16le(b, i) = Int(b[i]) | (Int(b[i + 1]) << 8)
_u32le(b, i) = Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) |
               (Int(b[i + 3]) << 24)

"""
    le_cabecalho_dbf(bytes::Vector{UInt8}) -> CabecalhoDBF

Interpreta os primeiros bytes de um DBF (ou o cabeçalho em claro de um
`.dbc`): contagem de registros, tamanhos, language driver e descritores
de campo (32 bytes cada, terminados por 0x0D).
"""
function le_cabecalho_dbf(bytes::Vector{UInt8})
    length(bytes) ≥ 33 || error("cabeçalho DBF truncado ($(length(bytes)) bytes)")
    n_reg = _u32le(bytes, 5)          # offset 4 (0-based)
    hsize = _u16le(bytes, 9)          # offset 8
    rsize = _u16le(bytes, 11)         # offset 10
    ldid = bytes[30]                  # offset 29

    campos = CampoDBF[]
    offset = 1                        # byte 0 do registro é a flag de deleção
    pos = 33                          # descritores começam no offset 32
    while pos ≤ length(bytes) && bytes[pos] != 0x0d
        pos + 31 ≤ length(bytes) || error("descritor de campo truncado")
        fim_nome = pos
        while fim_nome < pos + 10 && bytes[fim_nome] != 0x00
            fim_nome += 1
        end
        nome = Symbol(String(bytes[pos:(fim_nome - 1)]))
        tipo = Char(bytes[pos + 11])
        larg = Int(bytes[pos + 16])
        dec = Int(bytes[pos + 17])
        push!(campos, CampoDBF(nome, tipo, larg, dec, offset))
        offset += larg
        pos += 32
    end
    isempty(campos) && error("DBF sem campos")
    offset == rsize ||
        @warn "soma das larguras ($offset) ≠ tamanho do registro ($rsize)"

    indice = Dict(c.nome => c for c in campos)
    return CabecalhoDBF(n_reg, hsize, rsize, ldid, campos, indice)
end

# ── acesso bruto a um campo dentro de um registro ────────────────────

"""
    RegistroDBF

Visão leve sobre os bytes de um registro. `r[:CAMPO]` devolve o texto
do campo (trim + transcodificação), parseando só o que for pedido —
é o objeto passado ao `filtro` de [`ler`](@ref).
"""
struct RegistroDBF
    dados::Vector{UInt8}
    cab::CabecalhoDBF
    encoding::Symbol
end

function Base.getindex(r::RegistroDBF, nome::Symbol)
    c = get(r.cab.indice, nome, nothing)
    c === nothing && throw(KeyError(nome))
    return decodifica_texto(r.dados, c.offset + 1, c.offset + c.largura,
                            r.encoding)
end

Base.keys(r::RegistroDBF) = (c.nome for c in r.cab.campos)

_deletado(registro::AbstractVector{UInt8}) = registro[1] == 0x2a  # '*'

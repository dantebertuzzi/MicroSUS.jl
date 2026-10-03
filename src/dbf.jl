# ─────────────────────────────────────────────────────────────────────
# DBF (dBase III): cabeçalho, descritores de campo, offsets fixos.
# ─────────────────────────────────────────────────────────────────────

"""
    CampoDBF

Descritor de um campo DBF: `nome`, `tipo` (`'C'` texto, `'N'` numérico,
`'D'` data `aaaammdd`, `'F'`, `'L'`), `largura`, `decimais` e `offset`
(0-based dentro do registro; o byte 0 é a flag de deleção).
"""
struct CampoDBF
    nome::Symbol
    tipo::Char       # 'C' texto, 'N' numérico, 'D' data AAAAMMDD, 'L', 'F'
    largura::Int
    decimais::Int
    offset::Int      # offset 0-based dentro do registro (byte 0 = flag deleção)
end

"""
    CabecalhoDBF

Cabeçalho de um DBF/DBC: contagem de registros, tamanhos do cabeçalho e
do registro, language driver (`ldid`, decide o encoding) e os
[`CampoDBF`](@ref) na ordem do arquivo (+ um índice por nome).
Obtenha com [`MicroSUS.cabecalho`](@ref) sem ler nenhum dado.
"""
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

O fim da lista de campos é o tamanho do cabeçalho declarado no próprio
arquivo; o 0x0D é aceito mas não exigido. Os arquivos do CNES de 2023
(`STPE2312.dbc`, `STBA2312.dbc`) trazem 0x00 no lugar dele, com os 208
descritores completos e a soma das larguras batendo com o registro.
"""
function le_cabecalho_dbf(bytes::Vector{UInt8})
    length(bytes) ≥ 33 || error("cabeçalho DBF truncado ($(length(bytes)) bytes)")
    n_reg = _u32le(bytes, 5)          # offset 4 (0-based)
    hsize = _u16le(bytes, 9)          # offset 8
    rsize = _u16le(bytes, 11)         # offset 10
    ldid = bytes[30]                  # offset 29
    length(bytes) ≥ hsize ||
        error("cabeçalho DBF truncado ($(length(bytes)) de $hsize bytes)")

    campos = CampoDBF[]
    offset = 1                        # byte 0 do registro é a flag de deleção
    pos = 33                          # descritores começam no offset 32
    # os descritores cabem entre o byte 33 e o último byte do cabeçalho,
    # reservado ao terminador 0x0D — que pode vir como 0x00
    while pos + 31 < hsize && bytes[pos] != 0x0d
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

    # Nomes em maiúsculas, a convenção do DBF. O DATASUS a quebra num campo
    # só, e não sempre: `contador` no SIM de 2010 e no SINASC de 1996, 2014,
    # 2015 e 2017, `CONTADOR` nos demais — e a leitura de vários anos saía
    # com duas colunas para o mesmo campo, cada uma com metade dos valores.
    vistos = Set{Symbol}()
    for (i, c) in enumerate(campos)
        n = _nome_campo(c.nome)
        n in vistos && error("campos $(c.nome) e $n coincidem sem distinção de caixa")
        push!(vistos, n)
        n === c.nome || (campos[i] = CampoDBF(n, c.tipo, c.largura, c.decimais, c.offset))
    end

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

_nome_campo(nome::Symbol) = Symbol(uppercase(String(nome)))

function Base.getindex(r::RegistroDBF, nome::Symbol)
    c = get(r.cab.indice, _nome_campo(nome), nothing)
    c === nothing && throw(KeyError(nome))
    return decodifica_texto(r.dados, c.offset + 1, c.offset + c.largura,
                            r.encoding)
end

Base.keys(r::RegistroDBF) = (c.nome for c in r.cab.campos)

# `haskey(r, :LINHAA)` no filtro: campos que não existem em todos os anos
# (as linhas da DO, DIAGSEC1 no SIH) — `r[:CAMPO]` daria KeyError neles
Base.haskey(r::RegistroDBF, nome::Symbol) = haskey(r.cab.indice, _nome_campo(nome))

_deletado(registro::AbstractVector{UInt8}) = registro[1] == 0x2a  # '*'

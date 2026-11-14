# ─────────────────────────────────────────────────────────────────────
# .dbc = cabeçalho DBF em claro + 4 bytes (CRC32) + registros
# comprimidos em PKWare DCL. Aqui: abertura, conversão dbc→dbf e o
# streaming de registros (Channel de lotes de registros brutos).
# ─────────────────────────────────────────────────────────────────────

"""
    abre_dbc(caminho) -> (io, CabecalhoDBF)

Abre um `.dbc`, lê o cabeçalho DBF em claro e posiciona `io` no início
do fluxo comprimido (cabeçalho + 4 bytes de CRC).
"""
function abre_dbc(caminho::AbstractString)
    io = open(caminho, "r")
    try
        seek(io, 8)
        hsize = Int(read(io, UInt8)) | (Int(read(io, UInt8)) << 8)
        seekstart(io)
        header = read(io, hsize)
        length(header) == hsize || error("arquivo truncado: $caminho")
        cab = le_cabecalho_dbf(header)
        seek(io, hsize + 4)
        return io, cab
    catch
        # sem isto, um arquivo corrompido ficava aberto — e no Windows não
        # pode ser apagado (EBUSY), nem para baixá-lo de novo
        close(io)
        rethrow()
    end
end

_eh_dbc(caminho) = lowercase(splitext(caminho)[2]) == ".dbc"

"""
    descomprime_dbc_para_dbf(entrada, saida) -> saida

Converte `.dbc` → `.dbf` em streaming (equivalente ao `dbc2dbf` do
`read.dbc`, memória constante).
"""
function descomprime_dbc_para_dbf(entrada::AbstractString,
                                  saida::AbstractString)
    io, _ = abre_dbc(entrada)
    seekstart(io)
    hsize_lo = (seek(io, 8); read(io, UInt8))
    hsize = Int(hsize_lo) | (Int(read(io, UInt8)) << 8)
    seekstart(io)
    header = read(io, hsize)
    seek(io, hsize + 4)
    open(saida, "w") do out
        write(out, header)
        dcl_descomprime(io, chunk -> write(out, chunk))
        write(out, 0x1a)   # EOF marker do dBase
    end
    close(io)
    return saida
end

# ── streaming de registros brutos ────────────────────────────────────

"""
    LoteRegistros

Lote de `n` registros brutos de largura fixa, contíguos num único buffer:
o registro `i` ocupa `dados[(i - 1) * tamanho + 1 : i * tamanho]`. Um
vetor só por lote, em vez de um `Vector{UInt8}` por registro — menos
objetos para o GC (334 mil a menos por leitura no DOSP2023).
"""
struct LoteRegistros
    dados::Vector{UInt8}
    n::Int
    tamanho::Int
end

Base.length(l::LoteRegistros) = l.n

# deslocamento (0-based) do registro `i` dentro de `dados`
@inline _base(l::LoteRegistros, i::Int) = (i - 1) * l.tamanho

# Estado da montagem, chamado como sink do descompressor. Um objeto com
# campos tipados, e não uma closure: as variáveis que a closure antiga
# reatribuía viravam `Core.Box`, instáveis em tipo, no laço mais quente.
mutable struct _Montador{C}
    canal::C
    rsize::Int
    lote::Int
    n_esperado::Int
    dados::Vector{UInt8}
    n::Int            # registros completos (não deletados) no lote atual
    preenchido::Int   # bytes já copiados do registro em montagem
    emitidos::Int     # registros completos vistos, deletados incluídos
end

function (m::_Montador)(chunk::AbstractVector{UInt8})
    i = 1
    n = length(chunk)
    rsize = m.rsize
    while i ≤ n
        # ignora EOF marker solto no fim do arquivo
        if m.preenchido == 0 && m.emitidos ≥ m.n_esperado &&
           @inbounds(chunk[i]) == 0x1a
            return nothing
        end
        base = m.n * rsize
        pega = min(rsize - m.preenchido, n - i + 1)
        copyto!(m.dados, base + m.preenchido + 1, chunk, i, pega)
        m.preenchido += pega
        i += pega
        if m.preenchido == rsize
            m.preenchido = 0
            m.emitidos += 1
            # deletado ('*'): o próximo registro sobrescreve este
            @inbounds m.dados[base + 1] == 0x2a || (m.n += 1)
            if m.n == m.lote
                put!(m.canal, LoteRegistros(m.dados, m.n, rsize))
                m.dados = Vector{UInt8}(undef, m.lote * rsize)
                m.n = 0
            end
        end
    end
    return nothing
end

"""
    canal_registros(caminho, cab; lote = 4096) -> Channel{LoteRegistros}

Produz lotes de registros brutos ([`MicroSUS.LoteRegistros`](@ref), cada
registro com `tamanho_registro` bytes, já sem os deletados), lendo `.dbc`
(descompressão em task separada) ou `.dbf` (leitura direta). A montagem
lida com registros que atravessam a fronteira dos chunks de 4 KiB da
janela DCL.
"""
function canal_registros(caminho::AbstractString, cab::CabecalhoDBF;
                         lote::Int = 4096)
    rsize = cab.tamanho_registro
    Channel{LoteRegistros}(2; spawn = true) do canal
        m = _Montador(canal, rsize, lote, cab.n_registros,
                      Vector{UInt8}(undef, lote * rsize), 0, 0, 0)
        if _eh_dbc(caminho)
            io, _ = abre_dbc(caminho)
            try
                dcl_descomprime(io, m)
            finally
                close(io)
            end
        else
            open(caminho, "r") do io
                seek(io, cab.tamanho_cabecalho)
                buf = Vector{UInt8}(undef, 1 << 16)
                while !eof(io)
                    n = readbytes!(io, buf)
                    m(view(buf, 1:n))
                end
            end
        end
        m.n > 0 && put!(canal, LoteRegistros(m.dados, m.n, rsize))
    end
end

"""
    cabecalho(caminho) -> CabecalhoDBF

Lê apenas o cabeçalho de um `.dbc` ou `.dbf` (campos, larguras,
contagem de registros), **sem descomprimir nem tocar nos dados**.

É o primeiro comando de qualquer análise multi-ano: o layout do DATASUS muda
entre anos, e conferir treze cabeçalhos custa menos que uma leitura.

```julia
cab = cabecalho("RDPE2201.dbc")
cab.n_registros                              # 48562
[c.nome for c in cab.campos]                 # nomes disponíveis
:DIAGSEC1 in keys(cab.indice)                # o campo existe neste ano?
```

Para ler apenas as colunas que existem em cada arquivo de uma série, combine
com `ler(...; ignorar_ausentes = true)`.
"""
function cabecalho(caminho::AbstractString)
    if _eh_dbc(caminho)
        io, cab = abre_dbc(caminho)
        close(io)
        return cab
    else
        open(caminho, "r") do io
            seek(io, 8)
            hsize = Int(read(io, UInt8)) | (Int(read(io, UInt8)) << 8)
            seekstart(io)
            return le_cabecalho_dbf(read(io, hsize))
        end
    end
end

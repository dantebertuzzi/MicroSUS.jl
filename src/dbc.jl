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
    seek(io, 8)
    hsize = Int(read(io, UInt8)) | (Int(read(io, UInt8)) << 8)
    seekstart(io)
    header = read(io, hsize)
    length(header) == hsize || error("arquivo truncado: $caminho")
    cab = le_cabecalho_dbf(header)
    seek(io, hsize + 4)
    return io, cab
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
    canal_registros(caminho, cab; lote = 4096) -> Channel{Vector{Vector{UInt8}}}

Produz lotes de registros brutos (cada um com `tamanho_registro` bytes,
já sem registros deletados), lendo `.dbc` (descompressão em task
separada) ou `.dbf` (leitura direta). A montagem lida com registros
que atravessam a fronteira dos chunks de 4 KiB da janela DCL.
"""
function canal_registros(caminho::AbstractString, cab::CabecalhoDBF;
                         lote::Int = 4096)
    rsize = cab.tamanho_registro
    Channel{Vector{Vector{UInt8}}}(2; spawn = true) do canal
        atual = Vector{Vector{UInt8}}()
        sizehint!(atual, lote)
        parcial = Vector{UInt8}(undef, rsize)
        preenchido = 0
        emitidos = 0

        function consome(chunk::AbstractVector{UInt8})
            i = 1
            n = length(chunk)
            while i ≤ n
                # ignora EOF marker solto no fim do arquivo
                if preenchido == 0 && chunk[i] == 0x1a &&
                   emitidos ≥ cab.n_registros
                    return
                end
                falta = rsize - preenchido
                pega = min(falta, n - i + 1)
                copyto!(parcial, preenchido + 1, chunk, i, pega)
                preenchido += pega
                i += pega
                if preenchido == rsize
                    if !_deletado(parcial)
                        push!(atual, copy(parcial))
                    end
                    emitidos += 1
                    preenchido = 0
                    if length(atual) ≥ lote
                        put!(canal, atual)
                        atual = Vector{Vector{UInt8}}()
                        sizehint!(atual, lote)
                    end
                end
            end
        end

        if _eh_dbc(caminho)
            io, _ = abre_dbc(caminho)
            try
                dcl_descomprime(io, consome)
            finally
                close(io)
            end
        else
            open(caminho, "r") do io
                seek(io, cab.tamanho_cabecalho)
                buf = Vector{UInt8}(undef, 1 << 16)
                while !eof(io)
                    n = readbytes!(io, buf)
                    consome(view(buf, 1:n))
                end
            end
        end

        isempty(atual) || put!(canal, atual)
    end
end

"""
    cabecalho(caminho) -> CabecalhoDBF

Lê apenas o cabeçalho de um `.dbc` ou `.dbf` (campos, larguras,
contagem de registros), sem tocar nos dados.
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

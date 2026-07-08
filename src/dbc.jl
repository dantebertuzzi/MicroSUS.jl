# dbc.jl — Conversão .dbc → .dbf e leitura como tabela.
#
# Estrutura de um .dbc do DATASUS:
#   [0 .. hsize-1]      header DBF intacto (hsize lido dos bytes 8-9, LE)
#   [hsize .. hsize+3]  CRC32 (ignorado, como no read.dbc do R)
#   [hsize+4 .. fim]    registros DBF comprimidos com PKWare DCL

"""
    dbc_para_dbf_bytes(raw::Vector{UInt8}) -> Vector{UInt8}

Converte o conteúdo bruto de um arquivo `.dbc` nos bytes do `.dbf`
equivalente (header + registros descomprimidos). Valida a consistência do
resultado contra os metadados do header DBF (nº de registros × tamanho do
registro).
"""
function dbc_para_dbf_bytes(raw::Vector{UInt8})
    length(raw) < 32 && throw(DBCError("arquivo muito pequeno para ser um .dbc"))

    # Bytes 4-7: nº de registros; 8-9: tamanho do header; 10-11: tamanho do
    # registro. Tudo little-endian, herdado do formato DBF.
    nrec  = Int(raw[5]) | Int(raw[6]) << 8 | Int(raw[7]) << 16 | Int(raw[8]) << 24
    hsize = Int(raw[9]) | Int(raw[10]) << 8
    rsize = Int(raw[11]) | Int(raw[12]) << 8

    (hsize < 32 || hsize + 4 >= length(raw)) &&
        throw(DBCError("header DBF inconsistente (hsize = $hsize)"))

    header      = raw[1:hsize]
    comprimido  = raw[hsize + 5:end]          # pula CRC32 de 4 bytes
    esperado    = nrec * rsize + 1            # +1: byte EOF (0x1a)

    registros = blast(comprimido; sizehint = esperado)

    # Alguns arquivos antigos omitem o byte EOF; tolera diferença de 1.
    abs(length(registros) - esperado) > 1 && throw(DBCError(
        "tamanho descomprimido ($(length(registros)) bytes) não bate com o " *
        "header DBF (esperados $esperado bytes para $nrec registros de $rsize bytes)"))

    return vcat(header, registros)
end

"""
    dbc2dbf(origem::AbstractString, destino::AbstractString) -> destino

Descomprime o arquivo `.dbc` em `origem` gravando o `.dbf` em `destino`.
Equivalente à função homônima do pacote `read.dbc` do R.
"""
function dbc2dbf(origem::AbstractString, destino::AbstractString)
    write(destino, dbc_para_dbf_bytes(read(origem)))
    return destino
end

"""
    read_dbc(caminho::AbstractString) -> DataFrame
    read_dbc(io::IO) -> DataFrame

Lê um arquivo `.dbc` do DATASUS diretamente para um `DataFrame`, sem gravar
intermediários em disco. A tabela subjacente (`DBFTables.Table`) implementa
a interface Tables.jl; use [`read_dbc_table`](@ref) se preferir o objeto
tabular sem materializar o `DataFrame`.

# Exemplo
```julia
df = read_dbc("DOPE2023.dbc")
```
"""
read_dbc(caminho::AbstractString) = DataFrame(read_dbc_table(caminho))
read_dbc(io::IO) = DataFrame(read_dbc_table(io))

"""
    read_dbc_table(caminho::AbstractString) -> DBFTables.Table
    read_dbc_table(io::IO) -> DBFTables.Table

Como [`read_dbc`](@ref), mas devolve o `DBFTables.Table` (fonte Tables.jl
preguiçosa) em vez de um `DataFrame` materializado.
"""
read_dbc_table(caminho::AbstractString) =
    DBFTables.Table(IOBuffer(dbc_para_dbf_bytes(read(caminho))))
read_dbc_table(io::IO) = DBFTables.Table(IOBuffer(dbc_para_dbf_bytes(read(io))))

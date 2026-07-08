module MicroSUSArrowExt

using MicroSUS
using Arrow
using Tables

"""
Streaming `.dbc`/`.dbf` → Arrow: `Arrow.write` consome
`Tables.partitions(TabelaDBC)`, gravando um record batch por lote —
memória O(tamanho_lote) do começo ao fim.
"""
function MicroSUS.converter(entrada::AbstractString, saida::AbstractString;
                            kwargs...)
    t = MicroSUS.ler(entrada; kwargs...)
    Arrow.write(saida, t)
    return saida
end

end # module

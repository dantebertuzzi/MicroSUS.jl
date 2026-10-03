module MicroSUSArrowExt

using MicroSUS
using Arrow
using Tables

# Colunas categóricas saem como texto simples, sem dicionário. Com
# dicionário, um valor que só aparece num lote posterior vira um "delta"
# de dicionário, e o leitor do Arrow.jl (2.8) falha de forma intermitente
# ao juntar três ou mais desses lotes (MethodError em resize! de um
# DictEncoded). Sem dicionário, o DOSP2023 sai 13% maior e é gravado 3×
# mais rápido.
_sem_dicionario(lote) =
    map(c -> c isa MicroSUS.PooledArrays.PooledArray ? Vector(c) : c, lote)

"""
Streaming `.dbc`/`.dbf` → Arrow: `Arrow.write` consome
`Tables.partitions(TabelaDBC)`, gravando um record batch por lote —
memória O(tamanho_lote) do começo ao fim.
"""
function MicroSUS.converter(entrada::Union{AbstractString,AbstractVector{<:AbstractString}},
                            saida::AbstractString;
                            kwargs...)
    t = MicroSUS.ler(entrada; kwargs...)
    Arrow.write(saida, Tables.partitioner(_sem_dicionario, Tables.partitions(t)))
    return saida
end

end # module

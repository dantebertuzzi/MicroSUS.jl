# process.jl — Infraestrutura comum de padronização de microdados.
#
# A filosofia é a mesma do microdatasus: os arquivos brutos carregam códigos
# ("1", "2", "9"...) que precisam de rotulagem, datas em texto ddmmaaaa e
# numéricos armazenados como caracteres. As funções aqui são utilitárias
# genéricas; os dicionários específicos de cada fonte ficam em sim.jl,
# sinasc.jl etc.

"""
    processar_fonte(id::Symbol, df::DataFrame; verbose = true) -> DataFrame

Despacha para a rotina de padronização da fonte, se existir. Fontes sem
rotina implementada devolvem o `DataFrame` inalterado (com um aviso).
"""
function processar_fonte(id::Symbol, df::DataFrame; verbose::Bool = true)
    id === :SIM_DO  && return process_sim(df)
    id === :SINASC  && return process_sinasc(df)
    verbose && @info "fonte :$id ainda não tem rotina de padronização; devolvendo dados brutos (use processar = false para silenciar)"
    return df
end

_limpa(x::AbstractString) = strip(x)
_limpa(x) = x

"""
    rotular!(df, col, labels) -> df

Substitui os códigos da coluna `col` pelos rótulos do dicionário `labels`.
Códigos ausentes do dicionário (ex.: "9" = ignorado) viram `missing`.
Não faz nada se a coluna não existir no `DataFrame` — o layout dos arquivos
do DATASUS varia entre anos.
"""
function rotular!(df::DataFrame, col::Symbol, labels::Dict{String,String})
    hasproperty(df, col) || return df
    df[!, col] = map(df[!, col]) do v
        v === missing && return missing
        s = string(_limpa(v))
        isempty(s) && return missing
        get(labels, s, missing)
    end
    return df
end

"""
    para_data!(df, col; formato = dateformat"ddmmyyyy") -> df

Converte uma coluna de datas em texto (`"01072026"`) para `Date`. Valores
inválidos, vazios ou zerados viram `missing`.
"""
function para_data!(df::DataFrame, col::Symbol;
                    formato::DateFormat = dateformat"ddmmyyyy")
    hasproperty(df, col) || return df
    df[!, col] = map(df[!, col]) do v
        v === missing && return missing
        s = string(_limpa(v))
        (isempty(s) || all(==('0'), s)) && return missing
        length(s) == 7 && (s = "0" * s)   # dia sem zero à esquerda
        try
            Date(s, formato)
        catch
            missing
        end
    end
    return df
end

"""
    para_int!(df, col) / para_float!(df, col) -> df

Converte colunas numéricas armazenadas como texto. Valores já numéricos
passam intactos; texto inválido vira `missing`.
"""
para_int!(df::DataFrame, col::Symbol)   = _para_num!(df, col, Int)
para_float!(df::DataFrame, col::Symbol) = _para_num!(df, col, Float64)

function _para_num!(df::DataFrame, col::Symbol, ::Type{T}) where {T<:Real}
    hasproperty(df, col) || return df
    df[!, col] = map(df[!, col]) do v
        v === missing && return missing
        v isa Real && return T <: Integer ? round(T, v) : T(v)
        s = string(_limpa(v))
        isempty(s) && return missing
        something(tryparse(T, s), missing)
    end
    return df
end

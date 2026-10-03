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
function processar_fonte(id::Symbol, df::DataFrame; verbose::Bool = true,
                         copiar::Bool = true)
    id === :SIM_DO  && return process_sim(df; copiar)
    id === :SINASC  && return process_sinasc(df; copiar)
    id === :SIH_RD  && return process_sih(df; copiar)
    if startswith(string(id), "SINAN_")
        agravo = Symbol(lowercase(string(id)[7:end]))
        return process_sinan(df; agravo = haskey(SINAN_AGRAVOS, agravo) ? agravo : nothing,
                             copiar)
    end
    verbose && @info "fonte :$id ainda não tem rotina de padronização; devolvendo dados brutos (use processar = false para silenciar)"
    return df
end

_limpa(x::AbstractString) = strip(x)
_limpa(x) = x

"""
    rotular!(df, col, labels; ignora_zeros = false) -> df

Substitui os códigos da coluna `col` pelos rótulos do dicionário `labels`.
Códigos ausentes do dicionário (ex.: "9" = ignorado) viram `missing`.
Não faz nada se a coluna não existir no `DataFrame` — o layout dos arquivos
do DATASUS varia entre anos.

Com `ignora_zeros = true`, zeros à esquerda são descartados antes da
consulta (`"01"` e `"1"` dão o mesmo rótulo; `"00"` vira `"0"`): o SINAN
grava as duas formas no mesmo arquivo.
"""
function rotular!(df::DataFrame, col::Symbol, labels::Dict{String,String};
                  ignora_zeros::Bool = false)
    hasproperty(df, col) || return df
    df[!, col] = map(df[!, col]) do v
        v === missing && return missing
        s = string(_limpa(v))
        isempty(s) && return missing
        if ignora_zeros && all(isdigit, s)
            s = lstrip(s, '0')
            isempty(s) && (s = "0")
        end
        get(labels, s, missing)
    end
    return df
end

"""
    para_data!(df, col; formato = dateformat"ddmmyyyy") -> df

Converte uma coluna de datas em texto (`"01072026"`) para `Date`. Valores
inválidos, vazios ou zerados viram `missing`. Colunas que o leitor já
tipou como `Date` (schemas `:data_ddmmyyyy`/`:data_yyyymmdd`) passam
intactas.
"""
function para_data!(df::DataFrame, col::Symbol;
                    formato::DateFormat = dateformat"ddmmyyyy")
    hasproperty(df, col) || return df
    df[!, col] = map(df[!, col]) do v
        v === missing && return missing
        v isa Date && return v
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

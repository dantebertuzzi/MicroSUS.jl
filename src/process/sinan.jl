# sinan.jl — Padronização dos microdados do SINAN (agravos de notificação).
#
# O SINAN não é um sistema com um layout: é uma família de fichas, uma por
# agravo, que compartilham um núcleo de notificação (sexo, raça, gestação,
# escolaridade, tipo de notificação) e divergem no resto. Duas armadilhas
# observadas nos arquivos nacionais e que motivam o desenho desta rotina:
#
#   * CLASSI_FIN, CRITERIO e EVOLUCAO mudam de significado de um agravo para
#     outro. "1" é "Dengue clássico" na ficha antiga da dengue e "Confirmado"
#     na da zika; violência usa outra codificação. Por isso esses três campos
#     só são rotulados quando o agravo é conhecido, com o dicionário dele.
#   * Os códigos numéricos vêm ora com, ora sem zero à esquerda — no mesmo
#     arquivo (ZIKABR23: CS_ESCOL_N tem 1.101 "01" e 502 "1"). A rotulagem
#     normaliza antes de consultar o dicionário.

const SINAN_TP_NOT = Dict(
    "1" => "Negativa", "2" => "Individual", "3" => "Surto", "4" => "Agregado",
)

const SINAN_SEXO = Dict("M" => "Masculino", "F" => "Feminino")   # I = ignorado

const SINAN_RACA = Dict(
    "1" => "Branca", "2" => "Preta", "3" => "Amarela",
    "4" => "Parda", "5" => "Indígena",
)

const SINAN_GESTANT = Dict(
    "1" => "1º trimestre", "2" => "2º trimestre", "3" => "3º trimestre",
    "4" => "Idade gestacional ignorada", "5" => "Não", "6" => "Não se aplica",
)

const SINAN_ESCOL = Dict(
    "0" => "Analfabeto",
    "1" => "1ª a 4ª série incompleta do EF",
    "2" => "4ª série completa do EF",
    "3" => "5ª à 8ª série incompleta do EF",
    "4" => "Ensino fundamental completo",
    "5" => "Ensino médio incompleto",
    "6" => "Ensino médio completo",
    "7" => "Educação superior incompleta",
    "8" => "Educação superior completa",
    "10" => "Não se aplica",
)   # 9 = ignorado

const SINAN_SIMNAO = Dict("1" => "Sim", "2" => "Não")

# ── dicionários por agravo ───────────────────────────────────────────

const _ARBO_CRITERIO = Dict(
    "1" => "Laboratorial", "2" => "Clínico-epidemiológico", "3" => "Em investigação",
)

const _ARBO_EVOLUCAO = Dict(
    "1" => "Cura", "2" => "Óbito pelo agravo", "3" => "Óbito por outras causas",
    "4" => "Óbito em investigação",
)

# Dengue e chikungunya compartilham a ficha de arboviroses urbanas desde
# 2014–2015: 10–12 são as classes da dengue, 13 é chikungunya.
const _ARBO_CLASSI = Dict(
    "5" => "Descartado", "8" => "Inconclusivo",
    "10" => "Dengue", "11" => "Dengue com sinais de alarme",
    "12" => "Dengue grave", "13" => "Chikungunya",
)

const _DENGUE_CLASSI = merge(_ARBO_CLASSI, Dict(
    # ficha anterior a 2014
    "1" => "Dengue clássico", "2" => "Dengue com complicações",
    "3" => "Febre hemorrágica do dengue", "4" => "Síndrome do choque do dengue",
))

const _CHIK_CLASSI = merge(_ARBO_CLASSI, Dict(
    # ficha própria de 2014–2016, codificada como a da zika: CHIKBR15 tem
    # 17.661 "1" e 13.338 "2" ao lado de 665 "13"; em CHIKBR17 restam 22.
    "1" => "Confirmado", "2" => "Descartado",
))

const _ZIKA_CLASSI = Dict("1" => "Confirmado", "2" => "Descartado", "8" => "Inconclusivo")

const SINAN_AGRAVOS = Dict{Symbol,NamedTuple}(
    :dengue      => (classi_fin = _DENGUE_CLASSI, criterio = _ARBO_CRITERIO,
                     evolucao = _ARBO_EVOLUCAO),
    :chikungunya => (classi_fin = _CHIK_CLASSI, criterio = _ARBO_CRITERIO,
                     evolucao = _ARBO_EVOLUCAO),
    :zika        => (classi_fin = _ZIKA_CLASSI, criterio = _ARBO_CRITERIO,
                     evolucao = _ARBO_EVOLUCAO),
)

# ID_AGRAVO (sem ponto) → agravo. "A92" aparece truncado nos arquivos da
# zika (ZIKABR23: 13.284 "A92." ao lado de 22.719 "A928").
const _AGRAVO_DO_CID = Dict(
    "A90" => :dengue, "A920" => :chikungunya, "A928" => :zika, "A92" => :zika,
)

function _agravo_do_df(df::DataFrame)
    hasproperty(df, :ID_AGRAVO) || return nothing
    achados = Set{Union{Nothing,Symbol}}()
    for v in df.ID_AGRAVO
        v === missing && continue
        s = replace(strip(string(v)), '.' => "")
        isempty(s) && continue
        push!(achados, get(_AGRAVO_DO_CID, s, nothing))
        length(achados) > 1 && return nothing
    end
    return length(achados) == 1 ? only(achados) : nothing
end

# NU_IDADE_N chega em três formas: Float64 em anos (schema :idade_sinan),
# o código cru como texto ("4025") ou como inteiro (4025 — campo N lido
# sem o schema do SINAN). O inteiro é o código, não a idade.
function _idade_anos_sinan(v)
    v === missing && return missing
    a = v isa AbstractFloat ? v :
        v isa Integer       ? decodifica_idade_sinan(lpad(string(v), 4, '0')) :
                              decodifica_idade_sinan(string(v))
    return a === missing || isnan(a) ? missing : floor(Int, a)
end

"""
    process_sinan(df::DataFrame; agravo = :auto, copiar = true) -> DataFrame

Padroniza microdados do SINAN. Rotula o núcleo comum às fichas de todos os
agravos — `TP_NOT`, `CS_SEXO`, `CS_RACA`, `CS_GESTANT`, `CS_ESCOL_N`,
`HOSPITALIZ` — e cria `IDADE_ANOS` (anos completos) a partir de
`NU_IDADE_N`.

`CLASSI_FIN`, `CRITERIO` e `EVOLUCAO` mudam de significado entre agravos e
só são rotulados quando o agravo é conhecido: `agravo` pode ser `:dengue`,
`:chikungunya`, `:zika` ou `nothing` (só o núcleo). Com `:auto`, o agravo
é inferido de `ID_AGRAVO` quando todas as linhas apontam para um dos três;
nos demais (malária, tuberculose, violência…) esses campos ficam como
estão.

Códigos com zero à esquerda (`"01"`) valem o mesmo que sem (`"1"`) — os
arquivos trazem as duas formas. Códigos de "ignorado" (`"9"`, `"I"`) e não
documentados (`"0"` em `CLASSI_FIN`) viram `missing`.

Colunas ausentes são ignoradas e as originais, preservadas. Chamado
automaticamente por [`fetch_datasus`](@ref) quando `processar = true`,
com o agravo da fonte (`:SINAN_DENGUE` → `:dengue`).

!!! note "Fichas anteriores ao SINAN NET"
    Os dicionários do núcleo são os do SINAN NET (2007 em diante).
    Arquivos mais antigos usam outras codificações em alguns campos —
    `TUBEBR01` traz `CS_RACA = "0"` em 83% dos registros, campo que a
    ficha da época não coletava. Rotular esses anos exige o dicionário da
    ficha correspondente.

`copiar = false` padroniza `df` no lugar, sem a cópia inicial — o que
[`fetch_datasus`](@ref) faz, já que o `DataFrame` é dele.
"""
function process_sinan(df::DataFrame; agravo::Union{Symbol,Nothing} = :auto,
                       copiar::Bool = true)
    copiar && (df = copy(df))
    agravo === :auto && (agravo = _agravo_do_df(df))
    agravo === nothing || haskey(SINAN_AGRAVOS, agravo) ||
        throw(ArgumentError("agravo :$agravo sem dicionário; use um de " *
                            "$(sort!(collect(keys(SINAN_AGRAVOS)))) ou nothing"))

    for col in propertynames(df)
        startswith(string(col), "DT_") || continue
        para_data!(df, col; formato = dateformat"yyyymmdd")
    end

    rotular!(df, :CS_SEXO, SINAN_SEXO)
    rotular!(df, :TP_NOT,     SINAN_TP_NOT;  ignora_zeros = true)
    rotular!(df, :CS_RACA,    SINAN_RACA;    ignora_zeros = true)
    rotular!(df, :CS_GESTANT, SINAN_GESTANT; ignora_zeros = true)
    rotular!(df, :CS_ESCOL_N, SINAN_ESCOL;   ignora_zeros = true)
    rotular!(df, :HOSPITALIZ, SINAN_SIMNAO;  ignora_zeros = true)

    if agravo !== nothing
        d = SINAN_AGRAVOS[agravo]
        rotular!(df, :CLASSI_FIN, d.classi_fin; ignora_zeros = true)
        rotular!(df, :CRITERIO,   d.criterio;   ignora_zeros = true)
        rotular!(df, :EVOLUCAO,   d.evolucao;   ignora_zeros = true)
    end

    if hasproperty(df, :NU_IDADE_N)
        df[!, :IDADE_ANOS] = _idade_anos_sinan.(df.NU_IDADE_N)
    end

    return df
end

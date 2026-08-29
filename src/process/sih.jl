# sih.jl — Padronização dos microdados do SIH/SUS (AIH reduzida, arquivo RD).
#
# Os dicionários seguem os valores efetivamente observados nos arquivos e a
# documentação da AIH. Atenção a duas divergências em relação ao SIM, que são
# fonte recorrente de erro em quem reaproveita código entre os dois sistemas:
#
#   SEXO      no SIH é 1 = Masculino, 3 = Feminino (no SIM é 1 e 2);
#   RACA_COR  no SIH é 01..05 + 99 (no SIM é 1..5, e "Parda" é 4, não 03).

const SIH_SEXO = Dict("1" => "Masculino", "3" => "Feminino",
                      "M" => "Masculino", "F" => "Feminino")   # layouts antigos

const SIH_RACACOR = Dict(
    "01" => "Branca", "02" => "Preta", "03" => "Parda",
    "04" => "Amarela", "05" => "Indígena",
)   # 99 = sem informação, deliberadamente fora → missing

const SIH_IDENT = Dict("1" => "Normal", "5" => "Longa permanência")

const SIH_CAR_INT = Dict(
    "01" => "Eletivo",
    "02" => "Urgência",
    "03" => "Acidente no local de trabalho ou a serviço da empresa",
    "04" => "Acidente no trajeto para o trabalho",
    "05" => "Outros tipos de acidente de trânsito",
    "06" => "Outros tipos de lesões e envenenamentos por agentes químicos ou físicos",
)

const SIH_MORTE = Dict(0 => "Não", 1 => "Sim")

"""
    idade_sih(idade, cod_idade) -> Union{Int,Missing}

Idade em anos completos a partir do par `IDADE` + `COD_IDADE` do SIH. O
`COD_IDADE` é a unidade: `0` minutos, `1` horas, `2` dias, `3` meses,
`4` anos, `5` anos acima de 100 (`IDADE` = 5, `COD_IDADE` = 5 ⇒ 105 anos).
Idades abaixo de um ano resultam em `0`.

Diferente do SIM, onde unidade e valor vêm no mesmo campo de 3 dígitos
([`decodifica_idade_sim`](@ref)), aqui são duas colunas — por isso a função
recebe dois argumentos.

Aceita tanto os valores já tipados pelo schema quanto o texto cru.
"""
function idade_sih(idade, cod)
    i, c = _int_ou_missing(idade), _int_ou_missing(cod)
    (i === missing || c === missing) && return missing
    c == 4 && return i
    c == 5 && return 100 + i
    c in (0, 1, 2, 3) && return 0
    return missing
end

_int_ou_missing(v) = v === missing ? missing :
    v isa Integer ? Int(v) :
    v isa AbstractFloat ? (isnan(v) ? missing : round(Int, v)) :
    something(tryparse(Int, strip(string(v))), missing)

"""
    process_sih(df::DataFrame) -> DataFrame

Padroniza microdados do SIH/SUS (`:SIH_RD`): rotula as variáveis categóricas
de domínio fechado (`SEXO`, `RACA_COR`, `IDENT`, `CAR_INT`, `MORTE`) e cria
`IDADE_ANOS` a partir de `IDADE` + `COD_IDADE`.

Colunas ausentes no layout do ano são ignoradas — o layout do SIH mudou em
2011, 2013 e 2014, e a rotina é escrita para sobreviver a isso. As colunas
originais são preservadas.

!!! note "O que esta rotina deliberadamente não rotula"
    `COBRANCA` (motivo de saída) e `ESPEC` (especialidade do leito) têm
    domínios extensos que variam entre versões da tabela da AIH. Como
    [`rotular!`](@ref) converte código não mapeado em `missing`, um
    dicionário incompleto apagaria dados válidos em silêncio — pior que
    devolver o código cru. Ficam como estão; use as tabelas oficiais da AIH
    se precisar deles rotulados.

    `RACA_COR = "99"` (sem informação) vira `missing`, que é o que ele
    significa.

Chamada automaticamente por [`fetch_datasus`](@ref) quando `processar = true`.
"""
function process_sih(df::DataFrame)
    df = copy(df)

    for col in (:DT_INTER, :DT_SAIDA, :NASC)
        para_data!(df, col; formato = dateformat"yyyymmdd")
    end

    rotular!(df, :SEXO,     SIH_SEXO)
    rotular!(df, :RACA_COR, SIH_RACACOR)
    rotular!(df, :IDENT,    SIH_IDENT)
    rotular!(df, :CAR_INT,  SIH_CAR_INT)

    if hasproperty(df, :IDADE) && hasproperty(df, :COD_IDADE)
        df[!, :IDADE_ANOS] = idade_sih.(df[!, :IDADE], df[!, :COD_IDADE])
    end

    for col in (:DIAS_PERM, :QT_DIARIAS, :MORTE, :ANO_CMPT, :MES_CMPT)
        para_int!(df, col)
    end
    for col in (:VAL_TOT, :VAL_SH, :VAL_SP, :US_TOT)
        para_float!(df, col)
    end

    return df
end

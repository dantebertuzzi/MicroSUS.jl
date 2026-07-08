# sim.jl — Padronização dos microdados do SIM (Declarações de Óbito, CID-10).
#
# Dicionários conforme a "Estrutura do arquivo de Declaração de Óbito"
# publicada pelo Ministério da Saúde (documentação do SIM/CID-10).

const SIM_SEXO = Dict("1" => "Masculino", "2" => "Feminino")

const SIM_RACACOR = Dict(
    "1" => "Branca", "2" => "Preta", "3" => "Amarela",
    "4" => "Parda", "5" => "Indígena",
)

const SIM_ESTCIV = Dict(
    "1" => "Solteiro", "2" => "Casado", "3" => "Viúvo",
    "4" => "Separado judicialmente", "5" => "União estável",
)

const SIM_ESC = Dict(
    "1" => "Nenhuma", "2" => "1 a 3 anos", "3" => "4 a 7 anos",
    "4" => "8 a 11 anos", "5" => "12 anos ou mais",
)

const SIM_LOCOCOR = Dict(
    "1" => "Hospital", "2" => "Outro estabelecimento de saúde",
    "3" => "Domicílio", "4" => "Via pública", "5" => "Outros",
    "6" => "Aldeia indígena",
)

const SIM_SIMNAO = Dict("1" => "Sim", "2" => "Não")

const SIM_CIRCOBITO = Dict(
    "1" => "Acidente", "2" => "Suicídio", "3" => "Homicídio", "4" => "Outros",
)

const SIM_FONTE = Dict(
    "1" => "Boletim de ocorrência", "2" => "Hospital",
    "3" => "Família", "4" => "Outra",
)

const SIM_GRAVIDEZ = Dict(
    "1" => "Única", "2" => "Dupla", "3" => "Tripla e mais",
)

const SIM_OBITOPARTO = Dict(
    "1" => "Antes", "2" => "Durante", "3" => "Depois",
)

const SIM_TPMORTEOCO = Dict(
    "1" => "Na gravidez", "2" => "No parto", "3" => "No abortamento",
    "4" => "Até 42 dias após o término da gestação",
    "5" => "De 43 dias a 1 ano após o término da gestação",
    "8" => "Não ocorreu nestes períodos",
)

"""
    idade_sim(v) -> Union{Int,Missing}

Decodifica o campo `IDADE` do SIM (unidade + valor) em idade em anos
completos. O primeiro dígito indica a unidade: `0` minutos, `1` horas,
`2` dias, `3` meses, `4` anos, `5` centenas de anos (`"501"` = 101 anos).
Idades abaixo de um ano resultam em `0`.
"""
function idade_sim(v)
    v === missing && return missing
    s = string(_limpa(v))
    length(s) < 3 && return missing
    unidade = s[1]
    valor = tryparse(Int, s[2:end])
    valor === nothing && return missing
    unidade == '4' && return valor
    unidade == '5' && return 100 + valor
    unidade in ('0', '1', '2', '3') && return 0
    return missing
end

"""
    process_sim(df::DataFrame) -> DataFrame

Padroniza microdados do SIM (`:SIM_DO`): converte datas (`DTOBITO`,
`DTNASC`, ...) para `Date`, rotula variáveis categóricas (sexo, raça/cor,
estado civil, escolaridade, local de ocorrência, circunstância do óbito
etc.) e cria `IDADE_ANOS` a partir do campo codificado `IDADE`.

Colunas ausentes no layout do ano são simplesmente ignoradas; a coluna
original `IDADE` é preservada. Chamado automaticamente por
[`fetch_datasus`](@ref) quando `processar = true`.
"""
function process_sim(df::DataFrame)
    df = copy(df)

    for col in (:DTOBITO, :DTNASC, :DTATESTADO, :DTINVESTIG, :DTCADASTRO)
        para_data!(df, col)
    end

    rotular!(df, :SEXO,       SIM_SEXO)
    rotular!(df, :RACACOR,    SIM_RACACOR)
    rotular!(df, :ESTCIV,     SIM_ESTCIV)
    rotular!(df, :ESC,        SIM_ESC)
    rotular!(df, :LOCOCOR,    SIM_LOCOCOR)
    rotular!(df, :ASSISTMED,  SIM_SIMNAO)
    rotular!(df, :NECROPSIA,  SIM_SIMNAO)
    rotular!(df, :ACIDTRAB,   SIM_SIMNAO)
    rotular!(df, :CIRCOBITO,  SIM_CIRCOBITO)
    rotular!(df, :FONTE,      SIM_FONTE)
    rotular!(df, :GRAVIDEZ,   SIM_GRAVIDEZ)
    rotular!(df, :OBITOPARTO, SIM_OBITOPARTO)
    rotular!(df, :OBITOGRAV,  SIM_SIMNAO)
    rotular!(df, :OBITOPUERP, SIM_SIMNAO)
    rotular!(df, :TPMORTEOCO, SIM_TPMORTEOCO)

    if hasproperty(df, :IDADE)
        df[!, :IDADE_ANOS] = idade_sim.(df[!, :IDADE])
    end

    para_int!(df, :QTDFILVIVO)
    para_int!(df, :QTDFILMORT)
    para_float!(df, :PESO)

    return df
end

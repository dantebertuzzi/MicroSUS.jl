# sinasc.jl — Padronização dos microdados do SINASC (Nascidos Vivos).
#
# Dicionários conforme a "Estrutura do arquivo da Declaração de Nascido
# Vivo" publicada pelo Ministério da Saúde.

const SINASC_SEXO = Dict(
    "1" => "Masculino", "2" => "Feminino",
    "M" => "Masculino", "F" => "Feminino",   # layouts antigos
)

const SINASC_LOCNASC = Dict(
    "1" => "Hospital", "2" => "Outro estabelecimento de saúde",
    "3" => "Domicílio", "4" => "Outros", "5" => "Aldeia indígena",
)

const SINASC_ESTCIVMAE = Dict(
    "1" => "Solteira", "2" => "Casada", "3" => "Viúva",
    "4" => "Separada judicialmente", "5" => "União estável",
)

const SINASC_ESCMAE = Dict(
    "1" => "Nenhuma", "2" => "1 a 3 anos", "3" => "4 a 7 anos",
    "4" => "8 a 11 anos", "5" => "12 anos ou mais",
)

const SINASC_GRAVIDEZ = Dict(
    "1" => "Única", "2" => "Dupla", "3" => "Tripla e mais",
)

const SINASC_PARTO = Dict("1" => "Vaginal", "2" => "Cesáreo")

const SINASC_CONSULTAS = Dict(
    "1" => "Nenhuma", "2" => "1 a 3 consultas",
    "3" => "4 a 6 consultas", "4" => "7 ou mais consultas",
)

const SINASC_RACACOR = Dict(
    "1" => "Branca", "2" => "Preta", "3" => "Amarela",
    "4" => "Parda", "5" => "Indígena",
)

const SINASC_STPARTO = Dict("1" => "Sim", "2" => "Não", "3" => "Não se aplica")

"""
    process_sinasc(df::DataFrame) -> DataFrame

Padroniza microdados do SINASC (`:SINASC`): converte datas (`DTNASC`,
`DTNASCMAE`, ...) para `Date`, rotula variáveis categóricas (sexo, tipo de
parto, gravidez, escolaridade e estado civil da mãe, raça/cor, consultas de
pré-natal, local de nascimento) e converte numéricos armazenados como texto
(`PESO`, `IDADEMAE`, `APGAR1`, `APGAR5`, `SEMAGESTAC`, ...).

Colunas ausentes no layout do ano são ignoradas. Chamado automaticamente
por [`fetch_datasus`](@ref) quando `processar = true`.
"""
function process_sinasc(df::DataFrame)
    df = copy(df)

    for col in (:DTNASC, :DTNASCMAE, :DTULTMENST, :DTCADASTRO, :DTDECLARAC)
        para_data!(df, col)
    end

    rotular!(df, :SEXO,      SINASC_SEXO)
    rotular!(df, :LOCNASC,   SINASC_LOCNASC)
    rotular!(df, :ESTCIVMAE, SINASC_ESTCIVMAE)
    rotular!(df, :ESCMAE,    SINASC_ESCMAE)
    rotular!(df, :GRAVIDEZ,  SINASC_GRAVIDEZ)
    rotular!(df, :PARTO,     SINASC_PARTO)
    rotular!(df, :CONSULTAS, SINASC_CONSULTAS)
    rotular!(df, :RACACOR,   SINASC_RACACOR)
    rotular!(df, :RACACORMAE, SINASC_RACACOR)
    rotular!(df, :STTRABPART, SINASC_STPARTO)
    rotular!(df, :STCESPARTO, SINASC_STPARTO)

    for col in (:PESO, :IDADEMAE, :IDADEPAI, :QTDFILVIVO, :QTDFILMORT,
                :SEMAGESTAC, :APGAR1, :APGAR5, :QTDGESTANT, :QTDPARTNOR,
                :QTDPARTCES, :CONSPRENAT)
        para_int!(df, col)
    end

    return df
end

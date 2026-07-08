# sources.jl — Catálogo das fontes de microdados do DATASUS.
#
# Toda a informação sobre onde os arquivos vivem no FTP e como são nomeados
# fica centralizada aqui. Se o DATASUS reorganizar diretórios (acontece de
# tempos em tempos), este é o único arquivo a ajustar.

const FTP_RAIZ = "ftp://ftp.datasus.gov.br/dissemin/publicos"

const UFS = ["AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO", "MA",
             "MT", "MS", "MG", "PA", "PB", "PR", "PE", "PI", "RJ", "RN",
             "RS", "RO", "RR", "SC", "SP", "SE", "TO"]

"""
Especificação de uma fonte de microdados do DATASUS.

# Campos
- `id`: identificador usado em [`fetch_datasus`](@ref) (ex.: `:SIM_DO`);
- `nome`: descrição humana;
- `periodicidade`: `:anual` (um arquivo por UF/ano) ou `:mensal` (por UF/mês);
- `abrangencia`: `:uf` (um arquivo por UF) ou `:br` (arquivo nacional);
- `urls`: função `(uf, ano, mes) -> Vector{String}` com as URLs candidatas,
  em ordem de preferência (a primeira que existir é usada);
- `sufixos`: sufixos de particionamento a tentar além do arquivo base
  (ex.: SIA-PA divide meses grandes em `PAxxaamma.dbc`, `...b.dbc`, ...);
- `anos`: faixa de anos com cobertura conhecida.
"""
Base.@kwdef struct FonteDATASUS
    id::Symbol
    nome::String
    periodicidade::Symbol
    abrangencia::Symbol = :uf
    urls::Function
    sufixos::Vector{String} = [""]
    anos::UnitRange{Int}
end

aa(ano::Integer) = string(ano % 100; pad = 2)      # ano com 2 dígitos
mm(mes::Integer) = string(mes; pad = 2)            # mês com 2 dígitos

const FONTES = Dict{Symbol,FonteDATASUS}()

registrar!(f::FonteDATASUS) = (FONTES[f.id] = f)

# ---------------------------------------------------------------------------
# SIM — Sistema de Informações sobre Mortalidade
# ---------------------------------------------------------------------------
registrar!(FonteDATASUS(
    id = :SIM_DO,
    nome = "SIM — Declarações de Óbito (CID-10)",
    periodicidade = :anual,
    urls = (uf, ano, _) -> [
        "$FTP_RAIZ/SIM/CID10/DORES/DO$(uf)$(ano).dbc",
        "$FTP_RAIZ/SIM/PRELIM/DORES/DO$(uf)$(ano).dbc",   # anos recentes
    ],
    anos = 1996:2100,
))

# ---------------------------------------------------------------------------
# SINASC — Sistema de Informações sobre Nascidos Vivos
# ---------------------------------------------------------------------------
registrar!(FonteDATASUS(
    id = :SINASC,
    nome = "SINASC — Declarações de Nascido Vivo",
    periodicidade = :anual,
    urls = (uf, ano, _) -> [
        "$FTP_RAIZ/SINASC/NOV/DNRES/DN$(uf)$(ano).dbc",
        "$FTP_RAIZ/SINASC/1996_/Dados/DNRES/DN$(uf)$(ano).dbc",
        "$FTP_RAIZ/SINASC/PRELIM/DNRES/DN$(uf)$(ano).dbc",
    ],
    anos = 1996:2100,
))

# ---------------------------------------------------------------------------
# SIH — Sistema de Informações Hospitalares (AIH reduzida)
# ---------------------------------------------------------------------------
registrar!(FonteDATASUS(
    id = :SIH_RD,
    nome = "SIH — Autorizações de Internação Hospitalar (arquivo RD)",
    periodicidade = :mensal,
    urls = (uf, ano, mes) -> ano >= 2008 ?
        ["$FTP_RAIZ/SIHSUS/200801_/Dados/RD$(uf)$(aa(ano))$(mm(mes)).dbc"] :
        ["$FTP_RAIZ/SIHSUS/199201_200712/Dados/RD$(uf)$(aa(ano))$(mm(mes)).dbc"],
    anos = 1992:2100,
))

# ---------------------------------------------------------------------------
# SIA — Sistema de Informações Ambulatoriais (Produção Ambulatorial)
# ---------------------------------------------------------------------------
registrar!(FonteDATASUS(
    id = :SIA_PA,
    nome = "SIA — Produção Ambulatorial (arquivo PA)",
    periodicidade = :mensal,
    urls = (uf, ano, mes) -> ano >= 2008 ?
        ["$FTP_RAIZ/SIASUS/200801_/Dados/PA$(uf)$(aa(ano))$(mm(mes)).dbc"] :
        ["$FTP_RAIZ/SIASUS/199407_200712/Dados/PA$(uf)$(aa(ano))$(mm(mes)).dbc"],
    # Meses volumosos são particionados em PAxxaamma, ...b, ...c
    sufixos = ["", "a", "b", "c", "d", "e"],
    anos = 1994:2100,
))

# ---------------------------------------------------------------------------
# CNES — Cadastro Nacional de Estabelecimentos de Saúde
# ---------------------------------------------------------------------------
registrar!(FonteDATASUS(
    id = :CNES_ST,
    nome = "CNES — Estabelecimentos (arquivo ST)",
    periodicidade = :mensal,
    urls = (uf, ano, mes) ->
        ["$FTP_RAIZ/CNES/200508_/Dados/ST/ST$(uf)$(aa(ano))$(mm(mes)).dbc"],
    anos = 2005:2100,
))

registrar!(FonteDATASUS(
    id = :CNES_PF,
    nome = "CNES — Profissionais (arquivo PF)",
    periodicidade = :mensal,
    urls = (uf, ano, mes) ->
        ["$FTP_RAIZ/CNES/200508_/Dados/PF/PF$(uf)$(aa(ano))$(mm(mes)).dbc"],
    anos = 2005:2100,
))

# ---------------------------------------------------------------------------
# SINAN — Agravos de notificação (arquivos nacionais)
# ---------------------------------------------------------------------------
function _sinan(id::Symbol, prefixo::String, nome::String, anos::UnitRange{Int})
    registrar!(FonteDATASUS(
        id = id,
        nome = "SINAN — $nome",
        periodicidade = :anual,
        abrangencia = :br,
        urls = (_, ano, _) -> [
            "$FTP_RAIZ/SINAN/DADOS/FINAIS/$(prefixo)BR$(aa(ano)).dbc",
            "$FTP_RAIZ/SINAN/DADOS/PRELIM/$(prefixo)BR$(aa(ano)).dbc",
        ],
        anos = anos,
    ))
end

_sinan(:SINAN_DENGUE,      "DENG", "Dengue",                        2000:2100)
_sinan(:SINAN_CHIKUNGUNYA, "CHIK", "Chikungunya",                   2015:2100)
_sinan(:SINAN_ZIKA,        "ZIKA", "Zika",                          2016:2100)
_sinan(:SINAN_MALARIA,     "MALA", "Malária",                       2004:2100)
_sinan(:SINAN_TUBERCULOSE, "TUBE", "Tuberculose",                   2001:2100)
_sinan(:SINAN_VIOLENCIA,   "VIOL", "Violência interpessoal/autoprovocada", 2009:2100)

"""
    fontes() -> Vector{NamedTuple}

Lista as fontes de microdados disponíveis no pacote, com identificador,
descrição, periodicidade, abrangência e faixa de anos.

# Exemplo
```julia
using MicroSUS, DataFrames
DataFrame(fontes())
```
"""
function fontes()
    fs = sort!(collect(values(FONTES)); by = f -> string(f.id))
    return [(id = f.id, nome = f.nome, periodicidade = f.periodicidade,
             abrangencia = f.abrangencia, ano_inicial = first(f.anos))
            for f in fs]
end

function fonte(id::Symbol)
    haskey(FONTES, id) || throw(ArgumentError(
        "fonte desconhecida: :$id. Fontes disponíveis: " *
        join(sort!(string.(keys(FONTES))), ", ")))
    return FONTES[id]
end

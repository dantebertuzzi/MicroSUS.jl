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

# Recortes nacionais do SIM (um arquivo por ano, Brasil inteiro, ano com dois
# dígitos): óbitos fetais, infantis, por causas externas e maternos. O PRELIM
# vem primeiro: o DATASUS põe o preliminar também em CID10/DOFET (DOFET25
# idêntico nas duas pastas, com DOPE2025 só no PRELIM), e a ordem inversa o
# daria como consolidado. Consolidado o ano, ele sai do PRELIM (2024 já saiu).
for (id, pref, nome) in ((:SIM_DOFET, "DOFET", "óbitos fetais"),
                         (:SIM_DOINF, "DOINF", "óbitos infantis (menores de 1 ano)"),
                         (:SIM_DOEXT, "DOEXT", "óbitos por causas externas"),
                         (:SIM_DOMAT, "DOMAT", "óbitos maternos"))
    registrar!(FonteDATASUS(
        id = id,
        nome = "SIM — $nome (arquivo nacional)",
        periodicidade = :anual,
        abrangencia = :br,
        urls = (_, ano, _) -> [
            "$FTP_RAIZ/SIM/PRELIM/DOFET/$pref$(aa(ano)).dbc",
            "$FTP_RAIZ/SIM/CID10/DOFET/$pref$(aa(ano)).dbc",
        ],
        anos = 1996:2100,
    ))
end

# ---------------------------------------------------------------------------
# SINASC — Sistema de Informações sobre Nascidos Vivos
# ---------------------------------------------------------------------------
registrar!(FonteDATASUS(
    id = :SINASC,
    nome = "SINASC — Declarações de Nascido Vivo",
    periodicidade = :anual,
    urls = (uf, ano, _) -> [
        # 1996_ é a pasta canônica: é a única com 2023 em diante e onde o
        # DATASUS republica (DNPE2016, julho de 2025). NOV é uma cópia que
        # parou em 2022 e, em 2016, ficou com a versão de 2020.
        "$FTP_RAIZ/SINASC/1996_/Dados/DNRES/DN$(uf)$(ano).dbc",
        "$FTP_RAIZ/SINASC/NOV/DNRES/DN$(uf)$(ano).dbc",
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

# Os outros arquivos da AIH, na mesma pasta do RD. Início conferido no FTP
# (PE): SP em 06/1997, RJ em 04/2006, ER em 2011.
for (id, pref, nome, anos) in (
        (:SIH_SP, "SP", "Serviços profissionais da AIH (arquivo SP)", 1997:2100),
        (:SIH_RJ, "RJ", "AIHs rejeitadas (arquivo RJ)", 2006:2100),
        (:SIH_ER, "ER", "AIHs rejeitadas, com o código do erro (arquivo ER)", 2011:2100))
    registrar!(FonteDATASUS(
        id = id,
        nome = "SIH — $nome",
        periodicidade = :mensal,
        urls = (uf, ano, mes) -> ano >= 2008 ?
            ["$FTP_RAIZ/SIHSUS/200801_/Dados/$pref$(uf)$(aa(ano))$(mm(mes)).dbc"] :
            ["$FTP_RAIZ/SIHSUS/199201_200712/Dados/$pref$(uf)$(aa(ano))$(mm(mes)).dbc"],
        anos = anos,
    ))
end

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

# As demais tabelas do CNES, uma pasta cada. Início conferido no FTP (PE):
# LT em 10/2005, EQ e SR em 08/2005, as outras em 2007; EE parou em 12/2018.
for (id, pref, nome, anos) in (
        (:CNES_LT, "LT", "Leitos", 2005:2100),
        (:CNES_EQ, "EQ", "Equipamentos", 2005:2100),
        (:CNES_SR, "SR", "Serviços especializados", 2005:2100),
        (:CNES_HB, "HB", "Habilitações", 2007:2100),
        (:CNES_EP, "EP", "Equipes de saúde", 2007:2100),
        (:CNES_RC, "RC", "Regras contratuais", 2007:2100),
        (:CNES_IN, "IN", "Incentivos", 2007:2100),
        (:CNES_EE, "EE", "Estabelecimentos de ensino", 2007:2018),
        (:CNES_EF, "EF", "Estabelecimentos filantrópicos", 2007:2100),
        (:CNES_GM, "GM", "Gestão e metas", 2007:2100))
    registrar!(FonteDATASUS(
        id = id,
        nome = "CNES — $nome (arquivo $pref)",
        periodicidade = :mensal,
        urls = (uf, ano, mes) ->
            ["$FTP_RAIZ/CNES/200508_/Dados/$pref/$pref$(uf)$(aa(ano))$(mm(mes)).dbc"],
        anos = anos,
    ))
end

# Prefixo do nome do arquivo mensal → fonte, para reconhecer arquivos do cache
const _FONTE_MENSAL_DO_PREFIXO = Dict(
    "RD" => :SIH_RD, "SP" => :SIH_SP, "RJ" => :SIH_RJ, "ER" => :SIH_ER,
    "PA" => :SIA_PA, "ST" => :CNES_ST, "PF" => :CNES_PF, "LT" => :CNES_LT,
    "EQ" => :CNES_EQ, "SR" => :CNES_SR, "HB" => :CNES_HB, "EP" => :CNES_EP,
    "RC" => :CNES_RC, "IN" => :CNES_IN, "EE" => :CNES_EE, "EF" => :CNES_EF,
    "GM" => :CNES_GM)

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

# uma fonte por agravo do catálogo único (agravos.jl): :SINAN_DENGUE,
# :SINAN_SIFILIS_CONGENITA, …
for a in AGRAVOS_SINAN
    _sinan(_fonte_sinan(a.agravo), a.prefixo, a.nome, a.inicio:2100)
end

"""
    fontes() -> Vector{NamedTuple}

Lista as fontes de microdados disponíveis no pacote, com identificador,
descrição, periodicidade, abrangência e faixa de anos (`ano_final` é
`missing` para fontes ainda publicadas).

# Exemplo
```julia
using MicroSUS, DataFrames
DataFrame(fontes())
```
"""
function fontes()
    fs = sort!(collect(values(FONTES)); by = f -> string(f.id))
    return [(id = f.id, nome = f.nome, periodicidade = f.periodicidade,
             abrangencia = f.abrangencia, ano_inicial = first(f.anos),
             ano_final = last(f.anos) ≥ 2100 ? missing : last(f.anos))
            for f in fs]
end

"""
    fonte(id::Symbol) -> FonteDATASUS

Devolve a especificação registrada da fonte `id` (ver [`fontes`](@ref) para
a lista de identificadores disponíveis). Lança `ArgumentError` para um
identificador desconhecido.
"""
function fonte(id::Symbol)
    haskey(FONTES, id) || throw(ArgumentError(
        "fonte desconhecida: :$id. Fontes disponíveis: " *
        join(sort!(string.(keys(FONTES))), ", ")))
    return FONTES[id]
end

# agravos.jl — Catálogo único dos agravos do SINAN.
#
# O SINAN publica um arquivo nacional por agravo e ano, AGRAVOBR{aa}.dbc,
# em SINAN/DADOS/FINAIS/ ou, enquanto não consolida, SINAN/DADOS/PRELIM/.
# Esta tabela é a única fonte de verdade sobre eles: dela derivam o
# `baixar_sinan`/`url_sinan` (ftp.jl), as fontes `:SINAN_*` de
# `fetch_datasus` (sources.jl) e o reconhecimento do arquivo por
# `detecta_sistema` (schema.jl). Eram três listas mantidas à mão, e
# divergiam: a malária estava no catálogo mas não era reconhecida como
# SINAN, e 10 dos 16 agravos de `baixar_sinan` não existiam em `fontes()`.
#
# `inicio` é o primeiro ano publicado no FTP do DATASUS, verificado em
# 2026-10-03 (FINAIS ou PRELIM). Anos no meio da série podem faltar para
# alguns agravos; `fetch_datasus` avisa e segue.

const AGRAVOS_SINAN = [
    (agravo = :acidente_biologico,       prefixo = "ACBI", inicio = 2006,
     nome = "Acidente de trabalho com exposição a material biológico"),
    (agravo = :acidente_trabalho,        prefixo = "ACGR", inicio = 2006,
     nome = "Acidente de trabalho grave"),
    (agravo = :acidente_animais,         prefixo = "ANIM", inicio = 2007,
     nome = "Acidente por animais peçonhentos"),
    (agravo = :atendimento_antirrabico,  prefixo = "ANTR", inicio = 2006,
     nome = "Atendimento antirrábico"),
    (agravo = :botulismo,                prefixo = "BOTU", inicio = 2007,
     nome = "Botulismo"),
    (agravo = :cancer_trabalho,          prefixo = "CANC", inicio = 2007,
     nome = "Câncer relacionado ao trabalho"),
    (agravo = :chagas,                   prefixo = "CHAG", inicio = 2000,
     nome = "Doença de Chagas aguda"),
    (agravo = :chikungunya,              prefixo = "CHIK", inicio = 2014,
     nome = "Chikungunya"),
    (agravo = :colera,                   prefixo = "COLE", inicio = 2007,
     nome = "Cólera"),
    (agravo = :coqueluche,               prefixo = "COQU", inicio = 2007,
     nome = "Coqueluche"),
    (agravo = :dengue,                   prefixo = "DENG", inicio = 2000,
     nome = "Dengue"),
    (agravo = :dermatoses_ocupacionais,  prefixo = "DERM", inicio = 2006,
     nome = "Dermatoses ocupacionais"),
    (agravo = :difteria,                 prefixo = "DIFT", inicio = 2007,
     nome = "Difteria"),
    (agravo = :esquistossomose,          prefixo = "ESQU", inicio = 2007,
     nome = "Esquistossomose"),
    (agravo = :exantematicas,            prefixo = "EXAN", inicio = 2007,
     nome = "Doenças exantemáticas (sarampo e rubéola)"),
    (agravo = :febre_maculosa,           prefixo = "FMAC", inicio = 2007,
     nome = "Febre maculosa"),
    (agravo = :febre_tifoide,            prefixo = "FTIF", inicio = 2007,
     nome = "Febre tifoide"),
    (agravo = :hanseniase,               prefixo = "HANS", inicio = 2001,
     nome = "Hanseníase"),
    (agravo = :hantavirose,              prefixo = "HANT", inicio = 2000,
     nome = "Hantavirose"),
    (agravo = :hepatites,                prefixo = "HEPA", inicio = 2007,
     nome = "Hepatites virais"),
    (agravo = :intoxicacao_exogena,      prefixo = "IEXO", inicio = 2006,
     nome = "Intoxicação exógena"),
    (agravo = :leishmaniose_visceral,    prefixo = "LEIV", inicio = 2000,
     nome = "Leishmaniose visceral"),
    (agravo = :leptospirose,             prefixo = "LEPT", inicio = 2000,
     nome = "Leptospirose"),
    (agravo = :ler_dort,                 prefixo = "LERD", inicio = 2006,
     nome = "LER/DORT"),
    (agravo = :leishmaniose_tegumentar,  prefixo = "LTAN", inicio = 2000,
     nome = "Leishmaniose tegumentar americana"),
    (agravo = :malaria,                  prefixo = "MALA", inicio = 2004,
     nome = "Malária"),
    (agravo = :meningite,                prefixo = "MENI", inicio = 2007,
     nome = "Meningite"),
    (agravo = :transtornos_mentais_trabalho, prefixo = "MENT", inicio = 2006,
     nome = "Transtornos mentais relacionados ao trabalho"),
    (agravo = :tracoma,                  prefixo = "NTRA", inicio = 2010,
     nome = "Tracoma (notificação)"),
    (agravo = :pair,                     prefixo = "PAIR", inicio = 2006,
     nome = "Perda auditiva induzida por ruído relacionada ao trabalho"),
    (agravo = :peste,                    prefixo = "PEST", inicio = 2007,
     nome = "Peste"),
    (agravo = :paralisia_flacida,        prefixo = "PFAN", inicio = 2007,
     nome = "Paralisia flácida aguda"),
    (agravo = :pneumoconioses,           prefixo = "PNEU", inicio = 2006,
     nome = "Pneumoconioses relacionadas ao trabalho"),
    (agravo = :raiva,                    prefixo = "RAIV", inicio = 2007,
     nome = "Raiva humana"),
    (agravo = :surto_dta,                prefixo = "SDTA", inicio = 2007,
     nome = "Surtos de doenças transmitidas por alimentos"),
    (agravo = :sifilis_adquirida,        prefixo = "SIFA", inicio = 2010,
     nome = "Sífilis adquirida"),
    (agravo = :sifilis_congenita,        prefixo = "SIFC", inicio = 2007,
     nome = "Sífilis congênita"),
    (agravo = :sifilis_gestante,         prefixo = "SIFG", inicio = 2007,
     nome = "Sífilis em gestante"),
    (agravo = :rubeola_congenita,        prefixo = "SRC",  inicio = 2007,
     nome = "Síndrome da rubéola congênita"),
    (agravo = :tetano_acidental,         prefixo = "TETA", inicio = 2007,
     nome = "Tétano acidental"),
    (agravo = :tetano_neonatal,          prefixo = "TETN", inicio = 2014,
     nome = "Tétano neonatal"),
    (agravo = :toxoplasmose_congenita,   prefixo = "TOXC", inicio = 2019,
     nome = "Toxoplasmose congênita"),
    (agravo = :toxoplasmose_gestacional, prefixo = "TOXG", inicio = 2019,
     nome = "Toxoplasmose gestacional"),
    (agravo = :tracoma_inquerito,        prefixo = "TRAC", inicio = 2009,
     nome = "Tracoma (inquérito)"),
    (agravo = :tuberculose,              prefixo = "TUBE", inicio = 2001,
     nome = "Tuberculose"),
    (agravo = :varicela,                 prefixo = "VARC", inicio = 2007,
     nome = "Varicela"),
    (agravo = :violencia,                prefixo = "VIOL", inicio = 2009,
     nome = "Violência interpessoal/autoprovocada"),
    (agravo = :zika,                     prefixo = "ZIKA", inicio = 2015,
     nome = "Zika"),
]

# nomes alternativos aceitos por `baixar_sinan`/`url_sinan`
const _ALIASES_AGRAVO = Dict(:chik => :chikungunya)

"""
    agravos_sinan() -> Vector{NamedTuple}

Agravos do SINAN disponíveis no pacote: `agravo` (o símbolo aceito por
[`baixar_sinan`](@ref) e [`url_sinan`](@ref)), `fonte` (o identificador
em [`fetch_datasus`](@ref)), `prefixo` do arquivo nacional
(`DENG` → `DENGBR24.dbc`), `nome` e `ano_inicial` publicado no FTP.

```julia
using DataFrames
DataFrame(agravos_sinan())
```
"""
agravos_sinan() =
    [(agravo = a.agravo, fonte = _fonte_sinan(a.agravo), prefixo = a.prefixo,
      nome = a.nome, ano_inicial = a.inicio) for a in AGRAVOS_SINAN]

_fonte_sinan(agravo::Symbol) = Symbol("SINAN_", uppercase(string(agravo)))

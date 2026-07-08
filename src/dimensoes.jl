# ─────────────────────────────────────────────────────────────────────
# Dimensões auxiliares: códigos de município IBGE (6↔7 dígitos com
# dígito verificador) e capítulos da CID-10.
# ─────────────────────────────────────────────────────────────────────

"""
    dv_ibge(cod6) -> Int

Dígito verificador do código de município IBGE (algoritmo módulo 10 com
pesos alternados 1,2 e redução de produtos ≥ 10). Aceita `Integer` ou
string de 6 dígitos. Ex.: `dv_ibge(261110) == 1` (Petrolina → 2611101).
"""
function dv_ibge(cod6::Integer)
    0 ≤ cod6 ≤ 999_999 || throw(ArgumentError("código de 6 dígitos esperado"))
    soma = 0
    peso = 1
    div = 100_000
    for _ in 1:6
        d = (cod6 ÷ div) % 10
        p = d * peso
        soma += p ≥ 10 ? p - 9 : p
        peso = peso == 1 ? 2 : 1
        div ÷= 10
    end
    return (10 - soma % 10) % 10
end
dv_ibge(cod6::AbstractString) = dv_ibge(parse(Int, cod6))

"""
    codigo7_ibge(cod6) -> Int

Código de 7 dígitos a partir do de 6 (SIM/SINASC usam 6; IBGE moderno
usa 7). `codigo7_ibge(261110) == 2611101`.
"""
codigo7_ibge(cod6::Integer) = cod6 * 10 + dv_ibge(cod6)
codigo7_ibge(cod6::AbstractString) = codigo7_ibge(parse(Int, cod6))

"""
    codigo6_ibge(cod7; validar = true) -> Int

Código de 6 dígitos a partir do de 7, opcionalmente validando o dígito
verificador.
"""
function codigo6_ibge(cod7::Integer; validar::Bool = true)
    c6 = cod7 ÷ 10
    if validar && dv_ibge(c6) != cod7 % 10
        throw(ArgumentError("dígito verificador inválido em $cod7"))
    end
    return c6
end
codigo6_ibge(cod7::AbstractString; kwargs...) =
    codigo6_ibge(parse(Int, cod7); kwargs...)

# ── CID-10 ───────────────────────────────────────────────────────────

# (início, fim, numeral, nome) — fim inclusivo, comparação (letra, nn)
const _CAPITULOS_CID10 = [
    ("A00", "B99", "I", "Doenças infecciosas e parasitárias"),
    ("C00", "D48", "II", "Neoplasias"),
    ("D50", "D89", "III", "Doenças do sangue e transtornos imunitários"),
    ("E00", "E90", "IV", "Doenças endócrinas, nutricionais e metabólicas"),
    ("F00", "F99", "V", "Transtornos mentais e comportamentais"),
    ("G00", "G99", "VI", "Doenças do sistema nervoso"),
    ("H00", "H59", "VII", "Doenças do olho e anexos"),
    ("H60", "H95", "VIII", "Doenças do ouvido e da apófise mastóide"),
    ("I00", "I99", "IX", "Doenças do aparelho circulatório"),
    ("J00", "J99", "X", "Doenças do aparelho respiratório"),
    ("K00", "K93", "XI", "Doenças do aparelho digestivo"),
    ("L00", "L99", "XII", "Doenças da pele e do tecido subcutâneo"),
    ("M00", "M99", "XIII", "Doenças do sistema osteomuscular"),
    ("N00", "N99", "XIV", "Doenças do aparelho geniturinário"),
    ("O00", "O99", "XV", "Gravidez, parto e puerpério"),
    ("P00", "P96", "XVI", "Afecções do período perinatal"),
    ("Q00", "Q99", "XVII", "Malformações congênitas e anomalias cromossômicas"),
    ("R00", "R99", "XVIII", "Sintomas e achados anormais não classificados"),
    ("S00", "T98", "XIX", "Lesões, envenenamentos e causas externas (natureza)"),
    ("V01", "Y98", "XX", "Causas externas de morbidade e mortalidade"),
    ("Z00", "Z99", "XXI", "Fatores que influenciam o estado de saúde"),
    ("U00", "U99", "XXII", "Códigos para propósitos especiais"),
]

@inline function _chave_cid(cod::AbstractString)
    length(cod) ≥ 3 || return nothing
    l = uppercase(cod[1])
    ('A' ≤ l ≤ 'Z') || return nothing
    d1 = cod[2]; d2 = cod[3]
    (isdigit(d1) && isdigit(d2)) || return nothing
    return (l, 10 * (d1 - '0') + (d2 - '0'))
end

"""
    capitulo_cid10(cod) -> Union{Nothing,NamedTuple}

Capítulo CID-10 de um código como `"X954"` ou `"I219"`:
`(numeral = "XX", nome = "Causas externas ...")`, ou `nothing` se o
código for inválido/vazio.
"""
function capitulo_cid10(cod::AbstractString)
    k = _chave_cid(cod)
    k === nothing && return nothing
    for (ini, fim, num, nome) in _CAPITULOS_CID10
        ki = _chave_cid(ini)
        kf = _chave_cid(fim)
        if ki ≤ k ≤ kf
            return (numeral = num, nome = nome)
        end
    end
    return nothing
end

"""
    eh_agressao(cid) -> Bool

`true` se a causa básica é agressão (homicídio): X85–Y09, mais Y87.1
(sequelas de agressões) — o recorte usual de CVLI a partir do SIM.
"""
function eh_agressao(cid::AbstractString)
    startswith(uppercase(cid), "Y871") && return true
    k = _chave_cid(cid)
    k === nothing && return false
    return (('X', 85) ≤ k ≤ ('X', 99)) || (('Y', 0) ≤ k ≤ ('Y', 9))
end
eh_agressao(::Missing) = false

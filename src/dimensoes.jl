# ─────────────────────────────────────────────────────────────────────
# Dimensões auxiliares: códigos de município IBGE (6↔7 dígitos com
# dígito verificador), UF/região/município e busca de códigos CID-10.
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

# Nove municípios têm um dígito verificador oficial que não segue o
# algoritmo de `dv_ibge` (p. ex. Quixaba-PE é 2611533, não 2611531).
# O DV oficial vem da tabela de `municipios`; o algoritmo é o fallback
# para códigos fora dela.
function _dv_oficial(cod6::Int)
    i = get(_MUNICIPIO_POR_COD6, cod6, nothing)
    i === nothing && (_carrega_municipios();
                      i = get(_MUNICIPIO_POR_COD6, cod6, nothing))
    return i === nothing ? dv_ibge(cod6) : _MUNICIPIOS[][i].codigo7 % 10
end

"""
    codigo7_ibge(cod6) -> Int

Código de 7 dígitos a partir do de 6 (SIM/SINASC usam 6; IBGE moderno
usa 7). `codigo7_ibge(261110) == 2611101`. O dígito verificador vem da
tabela oficial ([`municipios`](@ref)) — nove municípios fogem do
algoritmo de [`dv_ibge`](@ref) — e do algoritmo para códigos fora dela.
"""
codigo7_ibge(cod6::Integer) = cod6 * 10 + _dv_oficial(Int(cod6))
codigo7_ibge(cod6::AbstractString) = codigo7_ibge(parse(Int, cod6))

"""
    codigo6_ibge(cod7; validar = true) -> Int

Código de 6 dígitos a partir do de 7, opcionalmente validando o dígito
verificador (contra a tabela oficial, como em [`codigo7_ibge`](@ref)).
"""
function codigo6_ibge(cod7::Integer; validar::Bool = true)
    c6 = cod7 ÷ 10
    if validar && _dv_oficial(Int(c6)) != cod7 % 10
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
    normaliza_cid(cid) -> String

Forma canônica de um código CID-10: maiúsculas, sem ponto, espaço, `*` ou
`-`. `normaliza_cid(" a81.0 ") == "A810"`; `missing` vira `""`.
"""
normaliza_cid(cid::AbstractString) =
    uppercase(filter(c -> !(c in ('.', ' ', '*', '-')), String(cid)))
normaliza_cid(::Missing) = ""

# Um alvo é um prefixo (`"A81"`, `"Y871"`) ou uma faixa inclusiva
# `"X85" => "Y09"`, comparada nos primeiros `length(ini)` caracteres.
_casa_alvo(c::String, a::AbstractString) = startswith(c, a)
function _casa_alvo(c::String, (ini, fim)::Pair{<:AbstractString,<:AbstractString})
    n = length(ini)
    length(fim) == n ||
        throw(ArgumentError("faixa de CID com extremos de tamanhos diferentes: $ini => $fim"))
    length(c) ≥ n || return false
    return ini ≤ first(c, n) ≤ fim
end

const _Alvo = Union{AbstractString,Pair{<:AbstractString,<:AbstractString}}

"""
    cid_casa(cid, alvos) -> Bool

`true` se o código `cid` (um campo como `CAUSABAS` ou `DIAG_PRINC`) cai em
algum dos `alvos`. Cada alvo é um prefixo (`"A81"` pega A81.0–A81.9;
`"A810"` só A81.0) ou uma faixa inclusiva de categorias (`"X85" => "Y09"`).
O código é normalizado antes ([`normaliza_cid`](@ref)); `missing` e vazio
dão `false`.

Feito para o `filtro` de [`ler`](@ref):

```julia
dcj = ["A810", "F021"]
ler(caminho; filtro = r -> cid_casa(r[:CAUSABAS], dcj))
```
"""
cid_casa(cid, alvo::_Alvo) = cid_casa(cid, (alvo,))
function cid_casa(cid, alvos)
    c = normaliza_cid(cid)
    isempty(c) && return false
    return any(a -> _casa_alvo(c, a), alvos)
end

const _RE_CID = r"[A-Z][0-9]{2}[0-9X]?"

"""
    cids_em(texto) -> Vector{String}

Códigos CID-10 contidos num campo de texto livre com vários códigos, como
as linhas da Declaração de Óbito do SIM (`LINHAA`…`LINHAD`, `LINHAII`),
onde vêm concatenados: `cids_em("*I219*E149") == ["I219", "E149"]`.
"""
cids_em(texto::AbstractString) =
    [String(m.match) for m in eachmatch(_RE_CID, uppercase(String(texto)))]
cids_em(::Missing) = String[]

"""
    menciona_cid(texto, alvos) -> Bool

`true` se algum código de [`cids_em`](@ref)`(texto)` casa com `alvos`
(mesmas regras de [`cid_casa`](@ref)). Serve para causas múltiplas: um
óbito em que a doença aparece na cadeia de causas, mas não como causa
básica.

```julia
linhas = (:LINHAA, :LINHAB, :LINHAC, :LINHAD, :LINHAII)
ler(caminho; colunas = [:CAUSABAS, linhas...],
    filtro = r -> cid_casa(r[:CAUSABAS], dcj) ||
                  any(l -> menciona_cid(r[l], dcj), linhas))
```

Os códigos são separados um a um antes de comparar: um alvo nunca casa
com um pedaço formado pela junção de dois códigos vizinhos.
"""
menciona_cid(texto, alvo::_Alvo) = menciona_cid(texto, (alvo,))
menciona_cid(texto, alvos) = any(c -> cid_casa(c, alvos), cids_em(texto))

const CID_AGRESSAO = ("X85" => "Y09", "Y871")

"""
    eh_agressao(cid) -> Bool

`true` se a causa básica é agressão (homicídio): X85–Y09, mais Y87.1
(sequelas de agressões) — o recorte usual de CVLI a partir do SIM.
Equivale a `cid_casa(cid, ("X85" => "Y09", "Y871"))`.
"""
eh_agressao(cid) = cid_casa(cid, CID_AGRESSAO)

# ── UF, região e municípios ──────────────────────────────────────────

# código IBGE da UF (os dois primeiros dígitos do município) → (sigla, região)
const _UFS = Dict{Int,Tuple{String,String}}(
    11 => ("RO", "Norte"), 12 => ("AC", "Norte"), 13 => ("AM", "Norte"),
    14 => ("RR", "Norte"), 15 => ("PA", "Norte"), 16 => ("AP", "Norte"),
    17 => ("TO", "Norte"),
    21 => ("MA", "Nordeste"), 22 => ("PI", "Nordeste"), 23 => ("CE", "Nordeste"),
    24 => ("RN", "Nordeste"), 25 => ("PB", "Nordeste"), 26 => ("PE", "Nordeste"),
    27 => ("AL", "Nordeste"), 28 => ("SE", "Nordeste"), 29 => ("BA", "Nordeste"),
    31 => ("MG", "Sudeste"), 32 => ("ES", "Sudeste"), 33 => ("RJ", "Sudeste"),
    35 => ("SP", "Sudeste"),
    41 => ("PR", "Sul"), 42 => ("SC", "Sul"), 43 => ("RS", "Sul"),
    50 => ("MS", "Centro-Oeste"), 51 => ("MT", "Centro-Oeste"),
    52 => ("GO", "Centro-Oeste"), 53 => ("DF", "Centro-Oeste"),
)
const _REGIAO_DA_SIGLA = Dict(s => r for (s, r) in values(_UFS))

# Códigos de município chegam como texto ("261160", " 2611606"), inteiro,
# ou vazios/ignorados. Devolve o inteiro, ou `nothing` se não for número.
_cod_mun(c::Integer) = Int(c)
_cod_mun(c::AbstractString) = tryparse(Int, strip(c))
_cod_mun(::Missing) = nothing

_cod_uf(cod::Int) = cod ≥ 1_000_000 ? cod ÷ 100_000 :
                    cod ≥ 100_000   ? cod ÷ 10_000  : cod

"""
    uf_de(cod) -> Union{String,Missing}

Sigla da UF de um código IBGE — município de 6 ou 7 dígitos, ou o próprio
código de 2 dígitos da UF. `uf_de("261160") == "PE"`, `uf_de(53) == "DF"`.
Código vazio, não numérico ou de UF inexistente dá `missing`.
"""
function uf_de(cod)
    c = _cod_mun(cod)
    c === nothing && return missing
    u = get(_UFS, _cod_uf(c), nothing)
    return u === nothing ? missing : u[1]
end

"""
    regiao(x) -> Union{String,Missing}

Grande região (`"Norte"`, `"Nordeste"`, `"Sudeste"`, `"Sul"`,
`"Centro-Oeste"`) a partir da sigla da UF (`regiao("PE")`) ou de um código
IBGE de UF ou município (`regiao(2611606)`). Desconhecido dá `missing`.
"""
function regiao(x)
    if x isa AbstractString
        r = get(_REGIAO_DA_SIGLA, uppercase(strip(x)), nothing)
        r === nothing || return r
    end
    uf = uf_de(x)
    return uf === missing ? missing : _REGIAO_DA_SIGLA[uf]
end
regiao(::Missing) = missing

const _Municipio = @NamedTuple{codigo7::Int, codigo6::Int, nome::String,
                               uf::String, regiao::String,
                               codigo_regiao_imediata::Int, regiao_imediata::String,
                               codigo_regiao_intermediaria::Int, regiao_intermediaria::String,
                               codigo_regiao_saude::Int, regiao_saude::String,
                               codigo_macrorregiao_saude::Int, macrorregiao_saude::String}

const _MUNICIPIOS = Ref{Vector{_Municipio}}()
const _MUNICIPIO_POR_COD6 = Dict{Int,Int}()
const _TRAVA_MUNICIPIOS = ReentrantLock()

# Carga preguiçosa e sob trava: `municipio` pode ser chamado de dentro do
# `filtro` de `ler`, que roda em tarefas concorrentes.
_carrega_municipios() = isassigned(_MUNICIPIOS) ? _MUNICIPIOS[] :
    lock(_le_municipios, _TRAVA_MUNICIPIOS)

function _le_municipios()
    isassigned(_MUNICIPIOS) && return _MUNICIPIOS[]
    v = _Municipio[]
    arq = joinpath(pkgdir(@__MODULE__), "data", "municipios.csv")
    for (i, linha) in enumerate(eachline(arq))
        i == 1 && continue                       # cabeçalho
        c7, nome, uf, reg, cim, im, cin, int, crs, rs, cms, ms = split(linha, ';')
        cod7 = parse(Int, c7)
        push!(v, (codigo7 = cod7, codigo6 = cod7 ÷ 10, nome = String(nome),
                  uf = String(uf), regiao = String(reg),
                  codigo_regiao_imediata = parse(Int, cim), regiao_imediata = String(im),
                  codigo_regiao_intermediaria = parse(Int, cin), regiao_intermediaria = String(int),
                  codigo_regiao_saude = parse(Int, crs), regiao_saude = String(rs),
                  codigo_macrorregiao_saude = parse(Int, cms), macrorregiao_saude = String(ms)))
    end
    empty!(_MUNICIPIO_POR_COD6)
    for (i, m) in enumerate(v)
        _MUNICIPIO_POR_COD6[m.codigo6] = i
    end
    return _MUNICIPIOS[] = v
end

"""
    municipios() -> Vector{NamedTuple}

Tabela dos municípios brasileiros embarcada no pacote (IBGE, 5.571 linhas
contando Brasília e Fernando de Noronha), sem acesso à rede: colunas
`codigo7`, `codigo6`, `nome`, `uf`, `regiao` e as divisões abaixo da UF,
cada uma com código e nome:

- `codigo_regiao_saude`, `regiao_saude` — a região de saúde (CIR) do SUS,
  onde se pactua a rede de atenção (439, com o Distrito Federal como uma só);
- `codigo_macrorregiao_saude`, `macrorregiao_saude` — a macrorregião de
  saúde, que agrupa regiões de saúde (121);
- `codigo_regiao_imediata`, `regiao_imediata` e `codigo_regiao_intermediaria`,
  `regiao_intermediaria` — a divisão regional do IBGE de 2017 (510 e 133),
  que substituiu micro e mesorregiões.

Nomes se repetem entre UFs (há região de saúde "Norte" e "Central" em várias,
e região imediata "Valença" na BA e no RJ): agrupe pelo código. É uma
tabela Tables.jl — `DataFrame(municipios())` — pronta para `leftjoin` com
`codigo6` contra `CODMUNRES` (SIM, SINASC) ou `MUNIC_RES` (SIH) convertidos
para inteiro:

```julia
mun = DataFrame(municipios())
df.codigo6 = parse.(Int, df.CODMUNRES)
leftjoin!(df, mun[:, [:codigo6, :codigo_regiao_saude, :regiao_saude]]; on = :codigo6)
obitos = combine(groupby(df, [:codigo_regiao_saude, :regiao_saude]), nrow => :obitos)
```

e [`populacao`](@ref) dá o denominador no mesmo nível
(`nivel = :regiao_saude`).

Fontes: IBGE (API de localidades) para nomes e regiões geográficas;
DATASUS (as tabelas territoriais do TabNet) para regiões e macrorregiões de
saúde, que mudam por pactuação nas CIBs — a tabela é a de outubro de 2026.

Reflete a divisão territorial atual: municípios extintos ou desmembrados
em anos antigos, e os códigos "ignorado" do DATASUS (`"260000"`, `"000000"`),
não estão nela.
"""
municipios() = copy(_carrega_municipios())

"""
    municipio(cod) -> Union{NamedTuple,Nothing}

Município do código IBGE `cod`, de 6 dígitos (como no SIM, SINASC e SIH)
ou de 7 (com dígito verificador), inteiro ou texto:

```julia
m = municipio("261160")   # (codigo7 = 2611606, codigo6 = 261160, nome = "Recife",
                         #  uf = "PE", regiao = "Nordeste", …)
m.regiao_saude           # "I Região de Saúde"
m.regiao_imediata        # "Recife"
```

Devolve `nothing` para código vazio, ignorado ou fora da tabela (ver
[`municipios`](@ref)). Um código de 7 dígitos com dígito verificador
errado também dá `nothing`.
"""
function municipio(cod)
    c = _cod_mun(cod)
    c === nothing && return nothing
    v = _carrega_municipios()
    c6 = c ≥ 1_000_000 ? c ÷ 10 : c
    i = get(_MUNICIPIO_POR_COD6, c6, nothing)
    i === nothing && return nothing
    m = v[i]
    c ≥ 1_000_000 && m.codigo7 != c && return nothing
    return m
end

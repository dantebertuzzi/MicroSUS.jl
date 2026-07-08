# ─────────────────────────────────────────────────────────────────────
# Schemas por sistema: como tipar cada campo. Tipos lógicos:
#   :texto, :pool, :inteiro, :float,
#   :data_ddmmyyyy (SIM/SINASC), :data_yyyymmdd (SIH, tipo 'D' do DBF),
#   :idade_sim (codificação unidade+valor do SIM → anos)
# ─────────────────────────────────────────────────────────────────────

"""
    decodifica_idade_sim(s) -> Union{Missing,Float64}

Idade do SIM (campo `IDADE`, 3 dígitos: 1º = unidade, 2º–3º = valor)
convertida para **anos**:

| 1º dígito | unidade        |
|-----------|----------------|
| 0         | minutos        |
| 1         | horas          |
| 2         | dias           |
| 3         | meses          |
| 4         | anos (0–99)    |
| 5         | 100 + valor    |
| 9         | ignorada       |

Ex.: `"425"` → 25.0; `"501"` → 101.0; `"310"` → 10/12; `"999"` → missing.
"""
function decodifica_idade_sim(s::AbstractString)
    t = strip(s)
    (isempty(t) || length(t) != 3 || !all(isdigit, t)) && return missing
    u = t[1] - '0'
    v = 10 * (t[2] - '0') + (t[3] - '0')
    u == 9 && return missing
    u == 0 && return v / 525_960.0        # minutos → anos (365,25 d)
    u == 1 && return v / 8_766.0          # horas
    u == 2 && return v / 365.25           # dias
    u == 3 && return v / 12.0             # meses
    u == 4 && return Float64(v)
    u == 5 && return 100.0 + v
    return missing
end
decodifica_idade_sim(::Missing) = missing

# ── parsers de bytes (sem alocar String) ─────────────────────────────

function _parse_int(b::AbstractVector{UInt8}, lo::Int, hi::Int)
    while lo ≤ hi && (b[lo] == 0x20); lo += 1; end
    while hi ≥ lo && (b[hi] == 0x20 || b[hi] == 0x00); hi -= 1; end
    hi < lo && return missing
    neg = false
    if b[lo] == UInt8('-')
        neg = true; lo += 1
    elseif b[lo] == UInt8('+')
        lo += 1
    end
    hi < lo && return missing
    val = 0
    @inbounds for i in lo:hi
        c = b[i]
        (0x30 ≤ c ≤ 0x39) || return missing
        val = 10val + Int(c - 0x30)
    end
    return neg ? -Int32(val) : Int32(val)
end

function _parse_float(b::AbstractVector{UInt8}, lo::Int, hi::Int)
    while lo ≤ hi && b[lo] == 0x20; lo += 1; end
    while hi ≥ lo && (b[hi] == 0x20 || b[hi] == 0x00); hi -= 1; end
    hi < lo && return missing
    s = String(b[lo:hi])
    x = tryparse(Float64, s)
    return x === nothing ? missing : x
end

function _digitos(b, lo, n)
    val = 0
    @inbounds for i in lo:(lo + n - 1)
        c = b[i]
        (0x30 ≤ c ≤ 0x39) || return -1
        val = 10val + Int(c - 0x30)
    end
    return val
end

function _parse_data(b::AbstractVector{UInt8}, lo::Int, hi::Int,
                     formato::Symbol)
    while hi ≥ lo && (b[hi] == 0x20 || b[hi] == 0x00); hi -= 1; end
    (hi - lo + 1) == 8 || return missing
    if formato === :ddmmyyyy
        d = _digitos(b, lo, 2); m = _digitos(b, lo + 2, 2)
        a = _digitos(b, lo + 4, 4)
    else # :yyyymmdd
        a = _digitos(b, lo, 4); m = _digitos(b, lo + 4, 2)
        d = _digitos(b, lo + 6, 2)
    end
    (a ≤ 0 || m < 1 || m > 12 || d < 1 || d > 31) && return missing
    try
        return Date(a, m, d)
    catch
        return missing
    end
end

# ── registro de schemas ──────────────────────────────────────────────

const SCHEMAS = Dict{Symbol,Dict{Symbol,Symbol}}(
    :sim => Dict(
        :DTOBITO => :data_ddmmyyyy, :DTNASC => :data_ddmmyyyy,
        :IDADE => :idade_sim,
        :SEXO => :pool, :RACACOR => :pool, :ESTCIV => :pool, :ESC => :pool,
        :OCUP => :pool, :CODMUNRES => :pool, :CODMUNOCOR => :pool,
        :LOCOCOR => :pool, :CAUSABAS => :pool, :CIRCOBITO => :pool,
        :ASSISTMED => :pool, :NECROPSIA => :pool,
    ),
    :sinasc => Dict(
        :DTNASC => :data_ddmmyyyy,
        :IDADEMAE => :inteiro, :QTDFILVIVO => :inteiro,
        :QTDFILMORT => :inteiro, :SEMAGESTAC => :inteiro,
        :PESO => :inteiro, :APGAR1 => :inteiro, :APGAR5 => :inteiro,
        :SEXO => :pool, :RACACOR => :pool, :ESCMAE => :pool,
        :GESTACAO => :pool, :GRAVIDEZ => :pool, :PARTO => :pool,
        :CONSULTAS => :pool, :CODMUNRES => :pool, :CODMUNNASC => :pool,
        :LOCNASC => :pool, :ESTCIVMAE => :pool,
    ),
    :sih => Dict(
        :DT_INTER => :data_yyyymmdd, :DT_SAIDA => :data_yyyymmdd,
        :NASC => :data_yyyymmdd,
        :IDADE => :inteiro, :DIAS_PERM => :inteiro, :QT_DIARIAS => :inteiro,
        :VAL_TOT => :float, :VAL_SH => :float, :VAL_SP => :float,
        :US_TOT => :float,
        :SEXO => :pool, :MUNIC_RES => :pool, :MUNIC_MOV => :pool,
        :DIAG_PRINC => :pool, :PROC_REA => :pool, :ESPEC => :pool,
        :COBRANCA => :pool, :MORTE => :pool, :CAR_INT => :pool,
    ),
    :sia => Dict(
        :PA_QTDAPR => :inteiro, :PA_QTDPRO => :inteiro,
        :PA_VALAPR => :float, :PA_VALPRO => :float,
        :PA_SEXO => :pool, :PA_MUNPCN => :pool, :PA_UFMUN => :pool,
        :PA_PROC_ID => :pool, :PA_CIDPRI => :pool, :PA_CBOCOD => :pool,
    ),
    :cnes => Dict(
        :CODUFMUN => :pool, :TP_UNID => :pool, :NIV_HIER => :pool,
        :ESFERA_A => :pool, :NATUREZA => :pool,
    ),
)

# prefixo do arquivo → sistema
const _PREFIXO_SISTEMA = Dict(
    "DO" => :sim, "DN" => :sinasc, "RD" => :sih, "SP" => :sih,
    "PA" => :sia, "ST" => :cnes, "LT" => :cnes, "PF" => :cnes,
)

"""
    detecta_sistema(caminho) -> Union{Nothing,Symbol}

Deduz o sistema pelo prefixo do nome do arquivo (`DOPE2023.dbc` → :sim,
`DNPE2023.dbc` → :sinasc, `RDPE2301.dbc` → :sih, ...).
"""
function detecta_sistema(caminho::AbstractString)
    nome = uppercase(basename(caminho))
    length(nome) ≥ 2 || return nothing
    return get(_PREFIXO_SISTEMA, nome[1:2], nothing)
end

# tipo lógico de um campo, dado o schema resolvido
function _tipo_logico(c::CampoDBF, schema::Union{Nothing,Dict{Symbol,Symbol}})
    if schema !== nothing && haskey(schema, c.nome)
        return schema[c.nome]
    end
    c.tipo == 'D' && return :data_yyyymmdd
    c.tipo == 'N' && return c.decimais > 0 ? :float : :inteiro
    c.tipo == 'F' && return :float
    return :texto
end

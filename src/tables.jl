# ─────────────────────────────────────────────────────────────────────
# Interface Tables.jl. `ler` devolve uma TabelaDBC preguiçosa; as
# partições (lotes de `tamanho_lote` linhas) são produzidas por uma
# task que consome o streaming de registros — do `.dbc` ao sink a
# memória é O(tamanho_lote), nunca O(arquivo).
# ─────────────────────────────────────────────────────────────────────

# tipo InlineString com capacidade p/ o pior caso da transcodificação
# (cada byte não-ASCII pode virar 2–3 bytes em UTF-8)
function _tipo_texto(largura::Int)
    cap = 3 * largura
    cap ≤ 3 && return String3
    cap ≤ 7 && return String7
    cap ≤ 15 && return String15
    cap ≤ 31 && return String31
    cap ≤ 63 && return String63
    cap ≤ 127 && return String127
    cap ≤ 255 && return String255
    return String
end

"""
    TabelaDBC

Tabela **preguiçosa** sobre um `.dbc`/`.dbf`, criada por [`ler`](@ref).
Nada é lido do disco até a iteração. Implementa a interface Tables.jl:
`Tables.partitions` produz lotes de `tamanho_lote` linhas (cada lote é
um `NamedTuple` de vetores) e `Tables.columns` materializa tudo via
[`materializar`](@ref) — então `DataFrame(t)`, `Arrow.write(io, t)` e
afins funcionam diretamente.
"""
struct TabelaDBC
    caminho::String
    cab::CabecalhoDBF
    campos::Vector{CampoDBF}       # selecionados, na ordem pedida
    tipos::Vector{Symbol}          # tipo lógico de cada campo
    filtro::Union{Nothing,Function}
    tamanho_lote::Int
    encoding::Symbol
end

"""
    ler(caminho; colunas = nothing, filtro = nothing,
        tamanho_lote = 100_000, schema = :auto, encoding = :auto,
        pool = true, ignorar_ausentes = false) -> TabelaDBC

Abre um `.dbc` ou `.dbf` do DATASUS como tabela preguiçosa
(Tables.jl, com `Tables.partitions`). Nada é lido até a iteração.

- `colunas`: `Vector{Symbol}` com os campos desejados — os demais nem
  são materializados. `nothing` = todos.
- `filtro`: função `RegistroDBF -> Bool` aplicada **antes** do parse
  das colunas; `r[:CAMPO]` devolve o texto do campo sob demanda.
  Ex.: `r -> r[:CODMUNRES] == "261110"`.
- `schema`: `:auto` (deduz pelo prefixo do arquivo: DO→SIM, DN→SINASC,
  RD→SIH, PA→SIA, ST→CNES), um `Symbol` (`:sim`, ...), um
  `Dict{Symbol,Symbol}` próprio, ou `nothing` (só a tipagem do DBF).
- `encoding`: `:auto` (language driver do cabeçalho; DATASUS ⇒ cp850),
  ou `:cp850`, `:latin1`, `:cp1252`, `:utf8`.
- `ignorar_ausentes`: quando `true`, colunas de `colunas` que não existem no
  layout deste arquivo são descartadas em vez de lançar `ArgumentError`. É o
  que torna prática a leitura multi-ano do SIH, cujo layout ganhou campos em
  2011, 2013 e 2014 — sem isso, pedir `:DIAGSEC1` derruba a leitura de 2010.
  As colunas descartadas saem por `@debug`; se **nenhuma** das pedidas existir,
  ainda assim é erro, porque aí o problema é outro (arquivo errado ou nome
  digitado errado);
- `pool`: usa `PooledArray` nas colunas categóricas do schema
  (equivalente ao factor do R, opt-in).

Uso: `DataFrame(ler(caminho))` materializa tudo;
`for lote in Tables.partitions(ler(caminho))` processa em lotes;
`Arrow.write(saida, ler(caminho))` converte em streaming.
"""
function ler(caminho::AbstractString;
             colunas::Union{Nothing,Vector{Symbol}} = nothing,
             filtro::Union{Nothing,Function} = nothing,
             tamanho_lote::Int = 100_000,
             schema = :auto,
             encoding::Symbol = :auto,
             pool::Bool = true,
             ignorar_ausentes::Bool = false)
    isfile(caminho) || throw(ArgumentError("arquivo não encontrado: $caminho"))
    tamanho_lote ≥ 1 || throw(ArgumentError("tamanho_lote deve ser ≥ 1"))

    cab = cabecalho(caminho)

    sch = if schema === :auto
        sis = detecta_sistema(caminho)
        sis === nothing ? nothing : SCHEMAS[sis]
    elseif schema isa Symbol
        haskey(SCHEMAS, schema) ||
            throw(ArgumentError("schema desconhecido: $schema"))
        SCHEMAS[schema]
    else
        schema   # Dict próprio ou nothing
    end

    campos = if colunas === nothing
        copy(cab.campos)
    elseif ignorar_ausentes
        presentes = filter(c -> haskey(cab.indice, c), colunas)
        faltando = setdiff(colunas, presentes)
        isempty(faltando) ||
            @debug "colunas ausentes neste layout, ignoradas" arquivo = basename(caminho) faltando
        isempty(presentes) && throw(ArgumentError(
            "nenhuma das colunas pedidas existe em $(basename(caminho)); " *
            "disponíveis: " * join([f.nome for f in cab.campos], ", ")))
        [cab.indice[c] for c in presentes]
    else
        [haskey(cab.indice, c) ? cab.indice[c] :
         throw(ArgumentError("coluna $c não existe; disponíveis: " *
                             join([f.nome for f in cab.campos], ", ")))
         for c in colunas]
    end

    tipos = [_tipo_logico(c, sch) for c in campos]
    pool || (tipos = [t === :pool ? :texto : t for t in tipos])

    enc = encoding === :auto ? encoding_do_ldid(cab.ldid) : encoding

    return TabelaDBC(String(caminho), cab, campos, tipos, filtro,
                     tamanho_lote, enc)
end

# ── construção de vetores por tipo lógico ────────────────────────────

function _novo_vetor(tl::Symbol, c::CampoDBF)
    tl === :inteiro && return Vector{Union{Missing,Int32}}()
    tl === :float && return Vector{Union{Missing,Float64}}()
    (tl === :idade_sim || tl === :idade_sinan) &&
        return Vector{Union{Missing,Float64}}()
    (tl === :data_ddmmyyyy || tl === :data_yyyymmdd) &&
        return Vector{Union{Missing,Date}}()
    T = _tipo_texto(c.largura)
    # pool de String, não de InlineString: o Arrow não grava dicionário de
    # InlineString em mais de um record batch ("fatal error writing arrow
    # data"), e o pool guarda só os valores distintos — custo desprezível.
    tl === :pool && return PooledArray(String[])
    return T[]
end

# ── conversão por coluna ─────────────────────────────────────────────
#
# Um lote é convertido coluna a coluna: o tipo lógico é resolvido uma vez
# por coluna e o laço sobre as linhas fica estável em tipo. Antes era
# linha a linha, com `_push_valor!` despachado em tempo de execução para
# cada campo (os vetores do lote viviam num Vector{Any}): 29 milhões de
# despachos no DOSP2023 (334 mil registros × 87 campos).

# Texto do campo como `T`, sem String intermediária no caso ASCII (a
# imensa maioria: códigos, datas, dígitos). Mesma semântica de
# `decodifica_texto`: espaços e NULs à direita são removidos.
@inline function _texto(::Type{T}, d::Vector{UInt8}, lo::Int, hi::Int,
                        enc::Symbol) where {T<:AbstractString}
    @inbounds while hi ≥ lo && (d[hi] == 0x20 || d[hi] == 0x00)
        hi -= 1
    end
    hi < lo && return T("")
    ascii = true
    @inbounds for i in lo:hi
        if d[i] ≥ 0x80
            ascii = false
            break
        end
    end
    if ascii || enc === :utf8 || enc === :raw
        return T <: InlineString ? T(d, lo, hi - lo + 1) : T(view(d, lo:hi))
    end
    return convert(T, decodifica_texto(d, lo, hi, enc))
end

function _preenche(f::F, ::Type{T}, regs) where {F,T}
    v = Vector{T}(undef, length(regs))
    @inbounds for i in eachindex(regs, v)
        v[i] = f(regs[i])
    end
    return v
end

# Categórica montada direto como PooledArray: cada valor distinto vira
# String uma vez por lote; as linhas só guardam o índice. Antes, toda
# linha criava uma String para procurá-la no dicionário.
function _coluna_pool(::Type{K}, regs, lo, hi, enc) where {K}
    pool = String[]
    invpool = Dict{String,UInt32}()
    vistos = Dict{K,UInt32}()
    refs = Vector{UInt32}(undef, length(regs))
    @inbounds for i in eachindex(regs, refs)
        k = _texto(K, regs[i], lo, hi, enc)
        r = get(vistos, k, UInt32(0))
        if r == 0
            s = String(k)
            push!(pool, s)
            r = UInt32(length(pool))
            vistos[k] = r
            invpool[s] = r
        end
        refs[i] = r
    end
    return PooledArray(PooledArrays.RefArray(refs), invpool, pool)
end

function _coluna(tl::Symbol, c::CampoDBF, regs, enc::Symbol)
    lo = c.offset + 1
    hi = c.offset + c.largura
    tl === :inteiro &&
        return _preenche(d -> _parse_int(d, lo, hi), Union{Missing,Int32}, regs)
    tl === :float &&
        return _preenche(d -> _parse_float(d, lo, hi), Union{Missing,Float64}, regs)
    tl === :data_ddmmyyyy &&
        return _preenche(d -> _parse_data(d, lo, hi, :ddmmyyyy), Union{Missing,Date}, regs)
    tl === :data_yyyymmdd &&
        return _preenche(d -> _parse_data(d, lo, hi, :yyyymmdd), Union{Missing,Date}, regs)
    T = _tipo_texto(c.largura)
    tl === :idade_sim && return _preenche(Union{Missing,Float64}, regs) do d
        decodifica_idade_sim(_texto(T, d, lo, hi, enc))
    end
    tl === :idade_sinan && return _preenche(Union{Missing,Float64}, regs) do d
        decodifica_idade_sinan(_texto(T, d, lo, hi, enc))
    end
    tl === :pool && return _coluna_pool(T, regs, lo, hi, enc)
    return _preenche(d -> _texto(T, d, lo, hi, enc), T, regs)   # :texto
end

_converte_lote(t::TabelaDBC, regs) =
    _fecha_lote(t, Any[_coluna(t.tipos[j], t.campos[j], regs, t.encoding)
                       for j in eachindex(t.campos)])

_nomes(t::TabelaDBC) = Tuple(c.nome for c in t.campos)

_fecha_lote(t::TabelaDBC, vets) = NamedTuple{_nomes(t)}(Tuple(vets))

# ── produção de partições ────────────────────────────────────────────

function _canal_lotes(t::TabelaDBC)
    Channel{NamedTuple}(1; spawn = true) do saida
        regs = canal_registros(t.caminho, t.cab;
                               lote = min(t.tamanho_lote, 8_192))
        # os registros são vetores novos (copy no canal_registros): dá para
        # guardá-los até fechar o lote e converter coluna a coluna
        pendentes = Vector{Vector{UInt8}}()
        sizehint!(pendentes, t.tamanho_lote)
        for lote in regs
            for dados in lote
                if t.filtro !== nothing
                    t.filtro(RegistroDBF(dados, t.cab, t.encoding)) || continue
                end
                push!(pendentes, dados)
                if length(pendentes) ≥ t.tamanho_lote
                    put!(saida, _converte_lote(t, pendentes))
                    pendentes = Vector{Vector{UInt8}}()
                    sizehint!(pendentes, t.tamanho_lote)
                end
            end
        end
        isempty(pendentes) || put!(saida, _converte_lote(t, pendentes))
    end
end

# ── Tables.jl ────────────────────────────────────────────────────────

Tables.istable(::Type{TabelaDBC}) = true
Tables.columnaccess(::Type{TabelaDBC}) = true
Tables.partitions(t::TabelaDBC) = _canal_lotes(t)
# As colunas são vetores novos, de ninguém: CopiedColumns diz isso ao
# DataFrame, que de outro modo copiaria tudo de novo (DataFrame(t) ia a
# 3,6× o tamanho do resultado no DOSP2023).
Tables.columns(t::TabelaDBC) = Tables.CopiedColumns(materializar(t))

# Acumula os lotes com append! em vez de guardá-los todos e concatenar no
# fim: cada lote é liberado assim que é anexado, e o pico fica perto do
# tamanho do resultado em vez do dobro. Os vetores do primeiro lote são
# nossos (cada lote é alocado do zero), então crescer neles é seguro.
#
# `capacidade` é o total de registros quando não há filtro (o cabeçalho
# diz exatamente quantos são): reservado de antemão, o append! não deixa
# folga. Com filtro o total é desconhecido, e a folga é devolvida no fim.
# sizehint! em PooledArray só existe a partir do Julia 1.11 (pelo fallback
# genérico de AbstractVector); a capacidade que importa é a dos índices
_reserva!(v::PooledArray, n) = (sizehint!(v.refs, n); v)
_reserva!(v, n) = sizehint!(v, n)

function _acumula(lotes, capacidade::Union{Nothing,Int})
    acc = nothing
    for l in lotes
        if acc === nothing
            acc = l
            capacidade === nothing || foreach(v -> _reserva!(v, capacidade), values(acc))
        else
            foreach(append!, values(acc), values(l))
        end
    end
    acc === nothing || capacidade !== nothing ||
        foreach(v -> _reserva!(v, length(v)), values(acc))
    return acc
end

"""
    materializar(t::TabelaDBC) -> NamedTuple

Consome todas as partições e concatena as colunas. É o que
`DataFrame(t)` chama por baixo via `Tables.columns`.
"""
function materializar(t::TabelaDBC)
    acc = _acumula(_canal_lotes(t), t.filtro === nothing ? t.cab.n_registros : nothing)
    return acc === nothing ? _converte_lote(t, Vector{UInt8}[]) : acc
end

function Base.show(io::IO, ::MIME"text/plain", t::TabelaDBC)
    printstyled(io, "TabelaDBC"; bold = true)
    println(io, " — ", basename(t.caminho))
    println(io, "  registros (cabeçalho): ", t.cab.n_registros,
            "   encoding: ", t.encoding,
            "   lote: ", t.tamanho_lote)
    println(io, "  colunas (", length(t.campos), "):")
    for (c, tl) in zip(t.campos, t.tipos)
        println(io, "    ", rpad(String(c.nome), 12),
                rpad(string(c.tipo, "(", c.largura, ")"), 8), " → ", tl)
    end
    t.filtro !== nothing && println(io, "  filtro: ativo")
    eh_preliminar(t.caminho) &&
        printstyled(io, "  dados PRELIMINARES (pasta PRELIM/ do DATASUS)\n"; color = :yellow)
end

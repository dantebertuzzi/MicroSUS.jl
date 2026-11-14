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
  Ex.: `r -> r[:CODMUNRES] == "261110"`. `haskey(r, :CAMPO)` diz se o
  campo existe neste arquivo — útil em leituras de vários anos, em que
  `r[:LINHAA]` daria `KeyError` nos layouts sem as linhas da DO.
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

    # nomes de campo são maiúsculos (ver le_cabecalho_dbf); o pedido vale
    # em qualquer caixa
    colunas === nothing || (colunas = _nome_campo.(colunas))
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

    enc = if encoding === :auto
        sis = schema isa Symbol && schema !== :auto ? schema : detecta_sistema(caminho)
        encoding_do_ldid(cab.ldid, sis)
    else
        encoding
    end

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

# `f(dados, base)` converte o campo do registro que começa em dados[base + 1]
function _preenche(f::F, ::Type{T}, regs::LoteRegistros) where {F,T}
    v = Vector{T}(undef, regs.n)
    d = regs.dados
    @inbounds for i in 1:regs.n
        v[i] = f(d, _base(regs, i))
    end
    return v
end

# Categórica montada direto como PooledArray: cada valor distinto vira
# String uma vez por lote; as linhas só guardam o índice. Antes, toda
# linha criava uma String para procurá-la no dicionário.
function _coluna_pool(::Type{K}, regs::LoteRegistros, lo, hi, enc) where {K}
    pool = String[]
    invpool = Dict{String,UInt32}()
    vistos = Dict{K,UInt32}()
    refs = Vector{UInt32}(undef, regs.n)
    d = regs.dados
    @inbounds for i in 1:regs.n
        b = _base(regs, i)
        k = _texto(K, d, b + lo, b + hi, enc)
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

function _coluna(tl::Symbol, c::CampoDBF, regs::LoteRegistros, enc::Symbol)
    lo = c.offset + 1
    hi = c.offset + c.largura
    tl === :inteiro &&
        return _preenche((d, b) -> _parse_int(d, b + lo, b + hi), Union{Missing,Int32}, regs)
    tl === :float &&
        return _preenche((d, b) -> _parse_float(d, b + lo, b + hi), Union{Missing,Float64}, regs)
    tl === :data_ddmmyyyy &&
        return _preenche((d, b) -> _parse_data(d, b + lo, b + hi, :ddmmyyyy), Union{Missing,Date}, regs)
    tl === :data_yyyymmdd &&
        return _preenche((d, b) -> _parse_data(d, b + lo, b + hi, :yyyymmdd), Union{Missing,Date}, regs)
    T = _tipo_texto(c.largura)
    tl === :idade_sim && return _preenche(Union{Missing,Float64}, regs) do d, b
        decodifica_idade_sim(_texto(T, d, b + lo, b + hi, enc))
    end
    tl === :idade_sinan && return _preenche(Union{Missing,Float64}, regs) do d, b
        decodifica_idade_sinan(_texto(T, d, b + lo, b + hi, enc))
    end
    tl === :pool && return _coluna_pool(T, regs, lo, hi, enc)
    return _preenche((d, b) -> _texto(T, d, b + lo, b + hi, enc), T, regs)   # :texto
end

# As colunas de um lote são independentes: cada uma lê os mesmos registros
# (só leitura) e aloca o próprio vetor. Com mais de uma thread, cada
# coluna vira uma tarefa. Lotes pequenos ficam na thread atual, onde o
# custo de criar as tarefas pesaria mais que a conversão.
const _MIN_LINHAS_PARALELO = 2_000

function _converte_lote(t::TabelaDBC, regs::LoteRegistros)
    col(j) = _coluna(t.tipos[j], t.campos[j], regs, t.encoding)
    js = eachindex(t.campos)
    cols = if Threads.nthreads() > 1 && length(js) > 1 &&
              regs.n ≥ _MIN_LINHAS_PARALELO
        tarefas = [Threads.@spawn col(j) for j in js]
        Any[fetch(x) for x in tarefas]
    else
        Any[col(j) for j in js]
    end
    return _fecha_lote(t, cols)
end

_nomes(t::TabelaDBC) = Tuple(c.nome for c in t.campos)

_fecha_lote(t::TabelaDBC, vets) = NamedTuple{_nomes(t)}(Tuple(vets))

# ── produção de partições ────────────────────────────────────────────

# Junta os lotes brutos do `canal_registros` (até 8 192 registros) em lotes
# de `tamanho` registros que passaram no filtro, num buffer contíguo, e
# entrega cada um a `entrega`. Os registros aceitos são copiados em bloco:
# sem filtro, um `copyto!` por lote do canal; com filtro, um por sequência
# de registros aceitos seguidos. O buffer cresce sob demanda — um filtro
# seletivo não reserva `tamanho × tamanho_registro` bytes à toa.
mutable struct _Juntador{E}
    entrega::E
    rsize::Int
    tamanho::Int     # registros por lote entregue
    inicial::Int     # capacidade inicial (em registros) de cada buffer
    restam::Int      # registros que ainda devem chegar (sem filtro); senão typemax
    buf::Vector{UInt8}
    n::Int
end

# anexa k registros de `src`, a partir do de-ésimo; entrega se encheu
function _anexa!(j::_Juntador, src::Vector{UInt8}, de::Int, k::Int)
    if (j.n + k) * j.rsize > length(j.buf)
        resize!(j.buf, min(j.tamanho, max(2j.n, j.n + k)) * j.rsize)
    end
    copyto!(j.buf, j.n * j.rsize + 1, src, (de - 1) * j.rsize + 1, k * j.rsize)
    j.n += k
    if j.n == j.tamanho
        j.entrega(LoteRegistros(j.buf, j.n, j.rsize))
        j.restam -= j.n
        j.buf = Vector{UInt8}(undef, clamp(j.restam, 1, j.inicial) * j.rsize)
        j.n = 0
    end
    return nothing
end

function _junta_lotes(entrega, regs, cab::CabecalhoDBF, filtro, encoding::Symbol,
                      tamanho::Int)
    rsize = cab.tamanho_registro
    inicial = min(tamanho, filtro === nothing ? max(cab.n_registros, 1) : 8_192)
    restam = filtro === nothing ? cab.n_registros : typemax(Int)
    j = _Juntador(entrega, rsize, tamanho, inicial, restam,
                  Vector{UInt8}(undef, inicial * rsize), 0)
    for lote in regs
        i = 1
        while i ≤ lote.n
            if filtro === nothing
                k = min(lote.n - i + 1, tamanho - j.n)
                _anexa!(j, lote.dados, i, k)
                i += k
                continue
            end
            if !filtro(RegistroDBF(lote.dados, _base(lote, i), cab, encoding))
                i += 1
                continue
            end
            # i foi aceito; estende a sequência de aceitos seguidos (cada
            # registro passa pelo filtro uma vez só)
            k = 1
            rejeitado = false
            while i + k ≤ lote.n && j.n + k < tamanho
                if filtro(RegistroDBF(lote.dados, _base(lote, i + k), cab, encoding))
                    k += 1
                else
                    rejeitado = true
                    break
                end
            end
            _anexa!(j, lote.dados, i, k)
            i += k + rejeitado
        end
    end
    j.n > 0 && entrega(LoteRegistros(j.buf, j.n, rsize))
    return nothing
end

function _canal_lotes(t::TabelaDBC)
    Channel{NamedTuple}(1; spawn = true) do saida
        regs = canal_registros(t.caminho, t.cab;
                               lote = min(t.tamanho_lote, 8_192))
        _junta_lotes(regs, t.cab, t.filtro, t.encoding, t.tamanho_lote) do lote
            put!(saida, _converte_lote(t, lote))
        end
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
    return acc === nothing ?
        _converte_lote(t, LoteRegistros(UInt8[], 0, t.cab.tamanho_registro)) : acc
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

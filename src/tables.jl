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
        pool = true) -> TabelaDBC

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
             pool::Bool = true)
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
    tl === :idade_sim && return Vector{Union{Missing,Float64}}()
    (tl === :data_ddmmyyyy || tl === :data_yyyymmdd) &&
        return Vector{Union{Missing,Date}}()
    T = _tipo_texto(c.largura)
    tl === :pool && return PooledArray(T[])
    return T[]
end

_novos_vetores(t::TabelaDBC) =
    Any[_novo_vetor(t.tipos[j], t.campos[j]) for j in eachindex(t.campos)]

@inline function _push_valor!(v, tl::Symbol, c::CampoDBF,
                              dados::Vector{UInt8}, enc::Symbol)
    lo = c.offset + 1
    hi = c.offset + c.largura
    if tl === :inteiro
        push!(v, _parse_int(dados, lo, hi))
    elseif tl === :float
        push!(v, _parse_float(dados, lo, hi))
    elseif tl === :data_ddmmyyyy
        push!(v, _parse_data(dados, lo, hi, :ddmmyyyy))
    elseif tl === :data_yyyymmdd
        push!(v, _parse_data(dados, lo, hi, :yyyymmdd))
    elseif tl === :idade_sim
        push!(v, decodifica_idade_sim(decodifica_texto(dados, lo, hi, enc)))
    else # :texto, :pool
        s = decodifica_texto(dados, lo, hi, enc)
        push!(v, convert(eltype(v), s))
    end
    return nothing
end

_nomes(t::TabelaDBC) = Tuple(c.nome for c in t.campos)

_fecha_lote(t::TabelaDBC, vets) = NamedTuple{_nomes(t)}(Tuple(vets))

# ── produção de partições ────────────────────────────────────────────

function _canal_lotes(t::TabelaDBC)
    Channel{NamedTuple}(1; spawn = true) do saida
        regs = canal_registros(t.caminho, t.cab;
                               lote = min(t.tamanho_lote, 8_192))
        vets = _novos_vetores(t)
        n = 0
        for lote in regs
            for dados in lote
                if t.filtro !== nothing
                    r = RegistroDBF(dados, t.cab, t.encoding)
                    t.filtro(r) || continue
                end
                for j in eachindex(t.campos)
                    _push_valor!(vets[j], t.tipos[j], t.campos[j],
                                 dados, t.encoding)
                end
                n += 1
                if n ≥ t.tamanho_lote
                    put!(saida, _fecha_lote(t, vets))
                    vets = _novos_vetores(t)
                    n = 0
                end
            end
        end
        n > 0 && put!(saida, _fecha_lote(t, vets))
    end
end

# ── Tables.jl ────────────────────────────────────────────────────────

Tables.istable(::Type{TabelaDBC}) = true
Tables.columnaccess(::Type{TabelaDBC}) = true
Tables.partitions(t::TabelaDBC) = _canal_lotes(t)
Tables.columns(t::TabelaDBC) = materializar(t)

"""
    materializar(t::TabelaDBC) -> NamedTuple

Consome todas as partições e concatena as colunas. É o que
`DataFrame(t)` chama por baixo via `Tables.columns`.
"""
function materializar(t::TabelaDBC)
    partes = collect(_canal_lotes(t))
    isempty(partes) && return _fecha_lote(t, _novos_vetores(t))
    length(partes) == 1 && return partes[1]
    nomes = _nomes(t)
    return NamedTuple{nomes}(Tuple(
        reduce(vcat, (p[nome] for p in partes)) for nome in nomes))
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
end

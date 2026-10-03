# ─────────────────────────────────────────────────────────────────────
# Vários arquivos como uma tabela só. `ler(caminhos)` encadeia as
# partições de cada `.dbc` em sequência, sem materializar nada: a
# memória continua O(tamanho_lote), seja um arquivo ou trinta anos.
#
# O que dá trabalho é o schema. Arrow exige que todo record batch tenha
# os mesmos tipos, mas entre anos o DATASUS alarga campos (C(10) → C(12)
# muda String15 para String31), troca o tipo DBF de um campo (N ↔ C) e
# acrescenta colunas. Cada coluna recebe um tipo de destino comum a
# todos os arquivos, e cada lote é ajustado a ele antes de sair.
# ─────────────────────────────────────────────────────────────────────

# destino de uma coluna: tipo do elemento (com Missing se preciso) e se é
# PooledArray
struct _Destino
    T::Type
    pooled::Bool
end

"""
    TabelaConcatenada

Vários `.dbc`/`.dbf` lidos como uma tabela preguiçosa só, criada por
[`ler`](@ref) com um vetor de caminhos. Mesma interface Tables.jl de
[`TabelaDBC`](@ref): `Tables.partitions` produz os lotes de cada arquivo
em sequência, todos com as mesmas colunas e os mesmos tipos, e
`DataFrame(t)` materializa tudo.
"""
struct TabelaConcatenada
    tabelas::Vector{TabelaDBC}
    nomes::Vector{Symbol}             # colunas dos arquivos
    destinos::Vector{_Destino}
    # colunas constantes por arquivo (`origem`): nome, tipo e o valor de
    # cada arquivo, na ordem de `tabelas`
    extras::Vector{Symbol}
    extras_T::Vector{Type}
    extras_val::Vector{Tuple}
end

_eltipo_base(tl::Symbol, c::CampoDBF) = eltype(_novo_vetor(tl, c))

function _destino(nome::Symbol, pares, falta_em_algum::Bool)
    tls = unique(first.(pares))
    tl = if length(tls) == 1
        only(tls)
    elseif all(in((:inteiro, :float)), tls)
        :float
    elseif all(in((:texto, :pool)), tls)
        :pool
    else
        @warn "coluna $nome muda de tipo entre os arquivos ($(join(tls, ", "))); " *
              "lida como texto em todos"
        :texto_livre
    end
    T = if tl === :texto_livre || tl === :pool
        String                    # o pool é sempre de String (ver _novo_vetor)
    elseif tl === :texto
        # a mais larga das InlineStrings (promote_type(String7, String15) == String15)
        reduce(promote_type, (_eltipo_base(:texto, c) for (_, c) in pares))
    else
        _eltipo_base(tl, last(first(pares)))
    end
    falta_em_algum && (T = Union{Missing,T})
    return _Destino(T, tl === :pool)
end

# `origem` → colunas constantes por arquivo. Um Symbol é o atalho para o
# nome do arquivo; uma função recebe o caminho e devolve um NamedTuple,
# com as mesmas chaves para todo arquivo.
function _metadados(tabelas, origem)
    origem === nothing && return Symbol[], Type[], Tuple[() for _ in tabelas]
    f = origem isa Symbol ? (c -> NamedTuple{(origem,)}((basename(c),))) : origem
    nts = [f(t.caminho) for t in tabelas]
    ks = keys(first(nts))
    for (t, nt) in zip(tabelas, nts)
        nt isa NamedTuple && keys(nt) == ks || throw(ArgumentError(
            "`origem` deve devolver um NamedTuple com as mesmas chaves para todo " *
            "arquivo; $(basename(t.caminho)) deu $(repr(nt))"))
    end
    Ts = Type[reduce(promote_type, (typeof(nt[k]) for nt in nts)) for k in ks]
    return collect(Symbol, ks), Ts, Tuple[Tuple(nt) for nt in nts]
end

# valor constante de um arquivo, n vezes; texto vai como categórico
_coluna_constante(::Type{T}, v, n) where {T<:AbstractString} = PooledArray(fill(convert(T, v), n))
_coluna_constante(::Type{T}, v, n) where {T} = fill(convert(T, v), n)

_lista_curta(v; n = 8) = length(v) ≤ n ? join(v, ", ") :
    join(first(v, n), ", ") * " e mais $(length(v) - n)"

function _concatena(tabelas::Vector{TabelaDBC}, uniao::Bool, origem,
                    ordem::Union{Nothing,Vector{Symbol}} = nothing)
    nomes = Symbol[]
    for t in tabelas, n in _nomes(t)
        n in nomes || push!(nomes, n)
    end
    # com `colunas` pedidas, a ordem é a do pedido, não a da 1ª aparição
    ordem === nothing || sort!(nomes; by = n -> something(findfirst(==(n), ordem), 0))
    if !uniao
        for t in tabelas
            faltam = setdiff(nomes, _nomes(t))
            isempty(faltam) && continue
            throw(ArgumentError(
                "os arquivos não têm as mesmas colunas — faltam em " *
                "$(basename(t.caminho)): $(_lista_curta(faltam)). Peça só as " *
                "comuns com `colunas`, ou use `uniao = true` para preencher " *
                "com missing as que faltam."))
        end
    end
    extras, extras_T, extras_val = _metadados(tabelas, origem)
    for e in extras
        e in nomes && throw(ArgumentError(
            "a coluna de origem :$e já existe nos arquivos; escolha outro nome"))
    end

    destinos = map(nomes) do n
        pares = Tuple{Symbol,CampoDBF}[]
        for t in tabelas
            j = findfirst(c -> c.nome === n, t.campos)
            j === nothing || push!(pares, (t.tipos[j], t.campos[j]))
        end
        _destino(n, pares, length(pares) < length(tabelas))
    end
    return TabelaConcatenada(tabelas, nomes, destinos, extras, extras_T, extras_val)
end

_converte(::Type, ::Missing) = missing
_converte(::Type{T}, x) where {T} = _converte_base(nonmissingtype(T), x)
_converte_base(::Type{S}, x::AbstractString) where {S<:AbstractString} = convert(S, x)
_converte_base(::Type{S}, x) where {S<:AbstractString} = convert(S, string(x))
_converte_base(::Type{S}, x) where {S} = convert(S, x)

function _ajusta(v, d::_Destino)
    (v isa PooledArray) == d.pooled && eltype(v) === d.T && return v
    return _ajusta(v, d.T, d.pooled)
end

# barreira de função: d.T é um campo ::Type, abstrato — sem ela o
# _converte era despachado em tempo de execução, elemento por elemento
# (3,2 s em 12 s no SIM de PE 2014–2023)
function _ajusta(v, ::Type{T}, pooled::Bool) where {T}
    if pooled && v isa PooledArray
        # categórico → categórico: converte só o dicionário
        pool = T[_converte(T, x) for x in v.pool]
        return PooledArray(PooledArrays.RefArray(copy(v.refs)), Dict{T,eltype(v.refs)}(
            p => eltype(v.refs)(i) for (i, p) in enumerate(pool)))
    end
    w = Vector{T}(undef, length(v))
    @inbounds for i in eachindex(v, w)
        w[i] = _converte(T, v[i])
    end
    return pooled ? PooledArray(w) : w
end

_vazia(d::_Destino, n::Int) =
    d.pooled ? PooledArray(Vector{d.T}(fill(missing, n))) : Vector{d.T}(fill(missing, n))

_nomes(t::TabelaConcatenada) = Tuple([t.nomes; t.extras])

function _lote_ajustado(t::TabelaConcatenada, i::Int, lote)
    n = length(first(lote))
    cols = Any[haskey(lote, nome) ? _ajusta(lote[nome], d) : _vazia(d, n)
               for (nome, d) in zip(t.nomes, t.destinos)]
    for (T, v) in zip(t.extras_T, t.extras_val[i])
        push!(cols, _coluna_constante(T, v, n))
    end
    return NamedTuple{_nomes(t)}(Tuple(cols))
end

# Quantos arquivos à frente do atual ficam abertos. Cada arquivo roda em
# duas tarefas (descompressão e conversão), então metade das threads; com
# uma thread só, nada é aberto à frente e a leitura é a sequencial de
# sempre. Cada arquivo aberto segura no máximo dois lotes prontos (o do
# canal e o que espera para entrar), então a memória continua O(lote).
_arquivos_adiante() = clamp(Threads.nthreads() ÷ 2, 0, 8)

function _canal_lotes(t::TabelaConcatenada; adiante::Int = _arquivos_adiante())
    Channel{NamedTuple}(1; spawn = true) do saida
        n = length(t.tabelas)
        canais = Dict{Int,Channel{NamedTuple}}()
        abre(i) = (i ≤ n && !haskey(canais, i)) && (canais[i] = _canal_lotes(t.tabelas[i]))
        foreach(abre, 1:min(1 + adiante, n))
        for i in 1:n
            abre(i)
            for lote in canais[i]
                put!(saida, _lote_ajustado(t, i, lote))
            end
            delete!(canais, i)
            abre(i + 1 + adiante)     # mantém `adiante` arquivos à frente, em ordem
        end
    end
end

"""
    ler(caminhos::AbstractVector; uniao = false, origem = :ARQUIVO,
        kwargs...) -> TabelaConcatenada

Lê vários arquivos como uma tabela só, em streaming: os lotes saem de um
arquivo depois do outro e a memória continua O(`tamanho_lote`). Os demais
kwargs (`colunas`, `filtro`, `schema`, `ignorar_ausentes`, …) valem para
cada arquivo como em `ler(caminho)`.

```julia
caminhos = baixar(:sim, "PE"; anos = 2014:2023)
t = ler(caminhos; colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES],
        filtro = r -> eh_agressao(r[:CAUSABAS]))
DataFrame(t)                    # uma linha por óbito, coluna :ARQUIVO = "DOPE2014.dbc", …
Arrow.write("cvli_pe.arrow", t) # um record batch por lote, schema único
```

- `uniao`: com `false`, todos os arquivos precisam produzir as mesmas
  colunas — layouts diferentes entre anos são erro, com a lista do que
  difere. Com `true`, a saída tem a união das colunas, e as que faltam num
  arquivo vêm como `missing` nas linhas dele.
- `origem`: nome da coluna acrescentada ao fim com o nome do arquivo de
  cada linha (`"DOPE2023.dbc"`); `nothing` para não acrescentar. Também
  pode ser uma função `caminho -> NamedTuple`, que vira uma coluna
  constante por chave — é assim que [`fetch_datasus`](@ref) acrescenta
  `UF_ARQUIVO`, `ANO_ARQUIVO` e `PRELIMINAR`:
  `origem = c -> (ANO = parse(Int, basename(c)[5:8]),)`.

Os tipos são unificados por coluna: texto de larguras diferentes vira a
`InlineString` mais larga, inteiro e decimal viram `Float64`, texto e
categórico viram categórico. Uma coluna que mude de tipo de outro jeito
entre os arquivos (data num ano, texto noutro) vira `String` em todos,
com um aviso.
"""
function ler(caminhos::AbstractVector{<:AbstractString};
             uniao::Bool = false,
             origem::Union{Nothing,Symbol,Function} = :ARQUIVO,
             kwargs...)
    isempty(caminhos) && throw(ArgumentError("nenhum arquivo para ler"))
    tabelas = [ler(c; kwargs...) for c in caminhos]
    return _concatena(tabelas, uniao, origem, get(kwargs, :colunas, nothing))
end

Tables.istable(::Type{TabelaConcatenada}) = true
Tables.columnaccess(::Type{TabelaConcatenada}) = true
Tables.partitions(t::TabelaConcatenada) = _canal_lotes(t)
Tables.columns(t::TabelaConcatenada) = Tables.CopiedColumns(materializar(t))

"""
    materializar(t::TabelaConcatenada) -> NamedTuple

Consome as partições de todos os arquivos e concatena as colunas.
"""
function materializar(t::TabelaConcatenada)
    sem_filtro = all(tab -> tab.filtro === nothing, t.tabelas)
    acc = _acumula(_canal_lotes(t),
                   sem_filtro ? sum(tab.cab.n_registros for tab in t.tabelas) : nothing)
    acc === nothing || return acc
    vazias = Any[d.pooled ? PooledArray(d.T[]) : d.T[] for d in t.destinos]
    for T in t.extras_T
        push!(vazias, T <: AbstractString ? PooledArray(T[]) : T[])
    end
    return NamedTuple{_nomes(t)}(Tuple(vazias))
end

function Base.show(io::IO, ::MIME"text/plain", t::TabelaConcatenada)
    printstyled(io, "TabelaConcatenada"; bold = true)
    println(io, " — ", length(t.tabelas), " arquivos")
    total = sum(tab.cab.n_registros for tab in t.tabelas)
    println(io, "  registros (cabeçalhos): ", total,
            "   lote: ", first(t.tabelas).tamanho_lote)
    for tab in first(t.tabelas, 5)
        println(io, "    ", basename(tab.caminho), "  ", tab.cab.n_registros)
    end
    length(t.tabelas) > 5 && println(io, "    … e mais ", length(t.tabelas) - 5)
    println(io, "  colunas (", length(t.nomes), "):")
    for (n, d) in zip(t.nomes, t.destinos)
        println(io, "    ", rpad(String(n), 12), d.pooled ? "pool " : "", d.T)
    end
    isempty(t.extras) || println(io, "  por arquivo: ", join((":" * string(e) for e in t.extras), ", "))
    first(t.tabelas).filtro !== nothing && println(io, "  filtro: ativo")
end

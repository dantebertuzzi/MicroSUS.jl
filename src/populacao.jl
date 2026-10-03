# ─────────────────────────────────────────────────────────────────────
# Denominadores populacionais do IBGE, pela API SIDRA (HTTP + JSON, sem
# dependência nova: o JSON da SIDRA é uma lista de objetos planos de
# strings, que regex resolve).
#
# Não existe uma série única. Cada ano vem de uma tabela diferente —
# estimativa anual, Censo ou Contagem — e elas não são comparáveis entre
# si: as estimativas de 2011–2021 projetavam o Censo 2010 e o Censo 2022
# mostrou que superestimavam (Brasil: 213,3 milhões estimados para 2021,
# 203,1 milhões recenseados em 2022; Recife: −10,4%). Por isso cada linha
# carrega a `fonte`, e 2023 — ano sem publicação do IBGE — só sai por
# interpolação pedida explicitamente.
# ─────────────────────────────────────────────────────────────────────

const _SIDRA = "https://apisidra.ibge.gov.br/values"

const _NIVEL_SIDRA = Dict(:municipio => "n6", :uf => "n3", :brasil => "n1")

# Níveis que a SIDRA não tem: saem da soma dos municípios, pela tabela
# embarcada (`municipios()`), com as colunas `codigo_<nivel>`, `nome`, `uf`.
const _NIVEIS_REGIONAIS = (:regiao_saude, :macrorregiao_saude, :regiao_imediata,
                           :regiao_intermediaria)

function _confere_nivel(nivel::Symbol)
    (haskey(_NIVEL_SIDRA, nivel) || nivel in _NIVEIS_REGIONAIS) || throw(ArgumentError(
        "nivel deve ser :municipio, :uf, :brasil, :regiao_saude, :macrorregiao_saude, " *
        ":regiao_imediata ou :regiao_intermediaria (recebi :$nivel)"))
    return nivel in _NIVEIS_REGIONAIS ? :municipio : nivel   # o nível consultado
end

# (codigo, nome, uf) da região de `nivel` que contém o município `cod7`
function _regiao_do_municipio(nivel::Symbol, cod7::Int)
    m = municipio(cod7)
    m === nothing && return nothing
    return (getfield(m, Symbol(:codigo_, nivel)), getfield(m, nivel), m.uf)
end

# Troca o município de cada linha pela sua região, somando `populacao` por
# (região, demais chaves). Município fora da tabela embarcada não some em
# silêncio: avisa quanto da população ficou de fora.
function _agrega_regiao(linhas, nivel::Symbol)
    soma = Dict{Any,Int}(); info = Dict{Int,Tuple{String,String}}()
    perdidos = Dict{Int,Int}()
    for l in linhas
        r = _regiao_do_municipio(nivel, l.codigo)
        if r === nothing
            perdidos[l.codigo] = get(perdidos, l.codigo, 0) + l.populacao
            continue
        end
        cod, nome, uf = r
        info[cod] = (nome, uf)
        k = merge(Base.structdiff(l, NamedTuple{(:codigo, :nome, :populacao)}), (codigo = cod,))
        soma[k] = get(soma, k, 0) + l.populacao
    end
    isempty(perdidos) || @warn "$(length(perdidos)) município(s) da SIDRA fora da tabela " *
        "de municípios, deixados fora da soma por $nivel: $(sum(values(perdidos))) " *
        "habitantes" codigos = sort!(collect(keys(perdidos)))
    return [merge(k, (nome = info[k.codigo][1], uf = info[k.codigo][2], populacao = v))
            for (k, v) in soma]
end

# ano → (tabela, variável, sufixo de classificações, descrição da fonte)
function _fonte_pop(ano::Int)
    ano == 2000 && return ("202", "93", "/c1/0/c2/0", "IBGE — Censo 2000 (SIDRA 202)")
    ano == 2007 && return ("793", "93", "", "IBGE — Contagem da População 2007 (SIDRA 793)")
    ano == 2010 && return ("202", "93", "/c1/0/c2/0", "IBGE — Censo 2010 (SIDRA 202)")
    ano == 2022 && return ("4709", "93", "", "IBGE — Censo 2022 (SIDRA 4709)")
    (2001 ≤ ano ≤ 2021 || ano ≥ 2024) &&
        return ("6579", "9324", "", "IBGE — estimativa (SIDRA 6579)")
    return nothing   # 2023 e antes de 2000
end

_dir_pop() = @get_scratch!("populacao")

const _RE_OBJ  = r"\{[^{}]*\}"
const _RE_COD  = r"\"D1C\"\s*:\s*\"(\d+)\""
const _RE_VAL  = r"\"V\"\s*:\s*\"(\d+)\""          # "-" e "..." não casam
const _RE_NOME = r"\"D1N\"\s*:\s*\"((?:[^\"\\]|\\.)*)\""

const _LinhaPop = NamedTuple{(:codigo, :nome, :populacao),Tuple{Int,String,Int}}

# linhas do JSON da SIDRA; o cabeçalho (D1C = "Município (Código)") e os
# valores sem dado ("-", "...": município ainda não criado) ficam de fora
function _parse_sidra(json::AbstractString)
    linhas = _LinhaPop[]
    for m in eachmatch(_RE_OBJ, json)
        b = m.match
        c = match(_RE_COD, b); p = match(_RE_VAL, b); n = match(_RE_NOME, b)
        (c === nothing || p === nothing) && continue
        push!(linhas, (codigo = parse(Int, c[1]),
                       nome = n === nothing ? "" : replace(n[1], "\\\"" => "\""),
                       populacao = parse(Int, p[1])))
    end
    return linhas
end

# P(t) = P0 · (P1/P0)^((t − t0)/(t1 − t0)), só para quem existe nos dois anos
function _interpola_geom(l0, l1, frac)
    p1 = Dict(l.codigo => l for l in l1)
    return _LinhaPop[(codigo = l.codigo, nome = p1[l.codigo].nome,
                      populacao = round(Int, l.populacao * (p1[l.codigo].populacao / l.populacao)^frac))
                     for l in l0 if haskey(p1, l.codigo)]
end

# (codigo, nome, populacao) de um nível e ano, do cache ou da SIDRA
function _pop_bruta(nivel::Symbol, ano::Int; cache::Bool)
    arq = joinpath(_dir_pop(), "$(nivel)_$(ano).tsv")
    if cache && isfile(arq)
        return [let (c, n, p) = split(l, '\t')
                    (codigo = parse(Int, c), nome = String(n), populacao = parse(Int, p))
                end for l in eachline(arq)]
    end
    t, v, cl, _ = _fonte_pop(ano)
    url = "$_SIDRA/t/$t/$(_NIVEL_SIDRA[nivel])/all/v/$v/p/$ano$cl"
    linhas = _parse_sidra(sprint(io -> Downloads.download(url, io)))
    isempty(linhas) && error("a SIDRA não devolveu população para $nivel/$ano " *
                             "(o IBGE pode ainda não ter publicado): $url")
    open(arq * ".part", "w") do io
        for l in linhas
            println(io, l.codigo, '\t', l.nome, '\t', l.populacao)
        end
    end
    mv(arq * ".part", arq; force = true)
    return linhas
end

function _interpola(nivel, ano; cache)
    a0 = findlast(a -> _fonte_pop(a) !== nothing, 2000:ano-1)
    a1 = findfirst(a -> _fonte_pop(a) !== nothing, ano+1:ano+10)
    (a0 === nothing || a1 === nothing) && throw(ArgumentError(
        "não há anos publicados dos dois lados de $ano para interpolar"))
    a0 = (2000:ano-1)[a0]; a1 = (ano+1:ano+10)[a1]
    fonte = "interpolação geométrica entre $a0 ($(last(_fonte_pop(a0)))) e " *
            "$a1 ($(last(_fonte_pop(a1))))"
    return _interpola_geom(_pop_bruta(nivel, a0; cache), _pop_bruta(nivel, a1; cache),
                           (ano - a0) / (a1 - a0)), fonte
end

"""
    populacao(anos; nivel = :municipio, interpolar = false, cache = true)
        -> Vector{NamedTuple}

População residente do IBGE, por município (`nivel = :municipio`), UF
(`:uf`) ou Brasil (`:brasil`), para um ano ou coleção de anos — o
denominador para transformar contagens em taxas. Vem da API SIDRA na
primeira chamada e fica em cache local.

Colunas: `codigo7` e `codigo6` (município; o de 6 dígitos casa com
`CODMUNRES` do SIM/SINASC e `MUNIC_RES` do SIH) ou `codigo_uf` (UF), mais
`nome`, `ano`, `populacao` e `fonte`. É uma tabela Tables.jl:
`DataFrame(populacao(2019:2021))`.

Também por região de saúde (`:regiao_saude`), macrorregião de saúde
(`:macrorregiao_saude`) e regiões imediata e intermediária do IBGE
(`:regiao_imediata`, `:regiao_intermediaria`), somando os municípios pela
tabela de [`municipios`](@ref): a coluna de código tem o mesmo nome que lá
(`codigo_regiao_saude`…), para o join, e vem com `nome` e `uf`. A
composição das regiões é a atual em qualquer ano pedido.

```julia
pop = DataFrame(populacao(2021))
obitos = combine(groupby(df, :CODMUNRES), nrow => :obitos)
obitos.codigo6 = parse.(Int, obitos.CODMUNRES)
t = innerjoin(obitos, pop; on = :codigo6)
t.taxa = 100_000 .* t.obitos ./ t.populacao
```

# A série não é homogênea

Cada ano vem da fonte que o IBGE publicou para ele, registrada na coluna
`fonte`: Censo (2000, 2010, 2022), Contagem (2007) ou estimativa anual (os
demais). As estimativas de 2011–2021 superestimaram a população — o Censo
2022 achou 203,1 milhões contra 213,3 milhões estimados para 2021, e −10,4%
em Recife —, então uma taxa calculada com elas cai artificialmente de 2021
para 2022 sem que nada tenha mudado no numerador. Séries longas pedem
retroprojeção (que o IBGE ainda não publicou para os municípios) ou, no
mínimo, uma nota.

# 2023

O IBGE não publicou população para 2023. Com `interpolar = false` (padrão)
pedir 2023 é erro; com `true`, sai a interpolação geométrica entre os anos
publicados vizinhos (Censo 2022 e estimativa 2024), com a `fonte` dizendo
isso. Atenção: a estimativa de 2024 não está na mesma base que o Censo
2022 (Brasil: 203,1 → 212,6 milhões em dois anos), e a interpolação herda
a diferença.

Anos antes de 2000 não estão disponíveis. `cache = false` consulta a SIDRA
de novo (o IBGE revisa estimativas de tempos em tempos).
"""
function populacao(anos; nivel::Symbol = :municipio, interpolar::Bool = false,
                   cache::Bool = true)
    nivel_sidra = _confere_nivel(nivel)
    anos_ = anos isa Integer ? [Int(anos)] : collect(Int, anos)
    for a in anos_
        a ≥ 2000 || throw(ArgumentError("população por $nivel só a partir de 2000 (pedido: $a)"))
        _fonte_pop(a) === nothing && !interpolar && throw(ArgumentError(
            "o IBGE não publicou população para $a. Use `interpolar = true` para " *
            "interpolação geométrica entre os anos vizinhos (fica registrada na " *
            "coluna `fonte`), ou traga o seu denominador."))
    end
    saida = NamedTuple[]
    for a in anos_
        linhas, fonte = _fonte_pop(a) === nothing ? _interpola(nivel_sidra, a; cache) :
                        (_pop_bruta(nivel_sidra, a; cache), last(_fonte_pop(a)))
        if nivel in _NIVEIS_REGIONAIS
            col = Symbol(:codigo_, nivel)
            for l in sort!(_agrega_regiao(linhas, nivel); by = l -> l.codigo)
                push!(saida, NamedTuple{(col, :nome, :uf, :ano, :populacao, :fonte)}(
                    (l.codigo, l.nome, l.uf, a, l.populacao,
                     "soma dos municípios — " * fonte)))
            end
            continue
        end
        for l in linhas
            r = nivel === :municipio ?
                (codigo7 = l.codigo, codigo6 = l.codigo ÷ 10, nome = l.nome, ano = a,
                 populacao = l.populacao, fonte = fonte) :
                nivel === :uf ?
                (codigo_uf = l.codigo, nome = l.nome, ano = a,
                 populacao = l.populacao, fonte = fonte) :
                (nome = l.nome, ano = a, populacao = l.populacao, fonte = fonte)
            push!(saida, r)
        end
    end
    return identity.(saida)   # vetor concretamente tipado
end

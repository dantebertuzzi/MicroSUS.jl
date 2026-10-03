# ─────────────────────────────────────────────────────────────────────
# População por sexo e idade, e taxas padronizadas por idade.
#
# A estimativa anual do IBGE (SIDRA 6579, a de `populacao`) só traz o
# total. Por sexo e idade, o que a SIDRA publica é:
#
#   Censo 2010 (1378) e Censo 2022 (9514) — até o município;
#   projeção da população, revisão 2018 (7358) — Brasil e UFs, 2000–2060.
#
# A projeção é anterior ao Censo 2022 e carrega a mesma superestimação das
# estimativas de 2011–2021 (ver `populacao`): serve para padronizar, com a
# ressalva na coluna `fonte`, não para contar habitantes.
#
# As tabelas agrupam as idades de jeitos diferentes (o Censo 2010 parte
# 15–19 em "15 a 17" e "18 ou 19", e tem "60 a 69" ao lado de "60 a 64"),
# então a consulta é por idade simples, agregada aqui em faixas. A soma de
# idade × sexo bate com o total oficial (Brasil: 190.755.799 em 2010,
# 203.080.756 em 2022).
# ─────────────────────────────────────────────────────────────────────

const _FONTES_IDADE = Dict(
    :censo2010 => (tabela = "1378", variavel = "93", periodo = "2010",
                   extra = "/c1/0/c455/0", fonte = "IBGE — Censo 2010 (SIDRA 1378)"),
    :censo2022 => (tabela = "9514", variavel = "93", periodo = "2022",
                   extra = "/c286/113635", fonte = "IBGE — Censo 2022 (SIDRA 9514)"),
    :projecao  => (tabela = "7358", variavel = "606", periodo = "2018",
                   extra = "", fonte = "IBGE — projeção da população, revisão 2018, " *
                                       "anterior ao Censo 2022 (SIDRA 7358)"),
)

function _fonte_idade(ano::Int, nivel::Symbol)
    ano == 2010 && return :censo2010
    ano == 2022 && return :censo2022
    nivel === :municipio && throw(ArgumentError(
        "por sexo e idade, o IBGE só publica município nos Censos (2010 e 2022); " *
        "para $ano use nivel = :uf ou :brasil (projeção da população)"))
    2000 ≤ ano ≤ 2060 || throw(ArgumentError(
        "a projeção da população do IBGE cobre 2000–2060 (pedido: $ano)"))
    return :projecao
end

# Linhas da API de valores da SIDRA como dicionários, com as dimensões
# renomeadas pelo cabeçalho ("Sexo (Código)" → "Sexo"): a posição de cada
# classificação (D4C, D5C…) muda de tabela para tabela.
function _linhas_sidra(json::AbstractString)
    objs = [Dict(m[1] => replace(m[2], "\\\"" => "\"")
                 for m in eachmatch(r"\"(\w+)\"\s*:\s*\"((?:[^\"\\]|\\.)*)\"", o.match))
            for o in eachmatch(r"\{[^{}]*\}", json)]
    isempty(objs) && return Dict{String,String}[]
    cab = popfirst!(objs)
    nomes = Dict{String,String}()
    usados = Dict{String,Int}()
    # em ordem (D1, D2, …): na projeção, o período e a classificação do ano
    # projetado se chamam ambos "Ano" — o segundo vira "Ano [2]"
    for k in sort!([k for k in keys(cab) if occursin(r"^D\dC$", k)])
        base = replace(cab[k], r" \(Código\)$" => "")
        usados[base] = get(usados, base, 0) + 1
        nome = usados[base] == 1 ? base : "$base [$(usados[base])]"
        nomes[k] = nome
        nomes["D$(k[2])N"] = nome * " (nome)"
    end
    return [Dict(get(nomes, k, k) => v for (k, v) in o) for o in objs]
end

_baixa_texto(url) = String(take!(Downloads.download(url, IOBuffer())))

# id da categoria → idade simples (0, 1, …) e o grupo aberto do topo
# ("90 anos ou mais" na projeção, "100 anos ou mais" nos Censos), que vale
# como sua idade mínima. As categorias em meses (subdivisões de "Menos de 1
# ano") e as faixas ficam de fora.
const _IDADES_SIDRA = Dict{String,Dict{String,Int}}()

function _idades_sidra(f)
    get!(_IDADES_SIDRA, f.tabela) do
        url = "$_SIDRA/t/$(f.tabela)/n1/all/v/$(f.variavel)/p/$(f.periodo)/c287/all"
        cats = Dict(l["Idade"] => l["Idade (nome)"] for l in _linhas_sidra(_baixa_texto(url)))
        ids = Dict{String,Int}()
        for (id, nome) in cats
            m = match(r"^(\d+) anos?$", nome)
            m === nothing || (ids[id] = parse(Int, m[1]))
            nome in ("Menos de 1 ano", "0 ano") && (ids[id] = 0)
        end
        topo = maximum(values(ids))
        aberto = findfirst(==("$(topo + 1) anos ou mais"), cats)
        aberto === nothing && error("SIDRA $(f.tabela): sem o grupo \"$(topo + 1) anos ou mais\"")
        ids[aberto] = topo + 1
        ids
    end
end

const _ANOS_PROJECAO = Dict{Int,String}()

function _id_ano_projecao(ano::Int)
    if isempty(_ANOS_PROJECAO)
        f = _FONTES_IDADE[:projecao]
        url = "$_SIDRA/t/$(f.tabela)/n1/all/v/$(f.variavel)/p/$(f.periodo)/c2/6794/c287/100362/c1933/all"
        for l in _linhas_sidra(_baixa_texto(url))
            _ANOS_PROJECAO[parse(Int, l["Ano [2] (nome)"])] = l["Ano [2]"]
        end
    end
    return _ANOS_PROJECAO[ano]
end

const _LinhaIdade = NamedTuple{(:codigo, :nome, :sexo, :idade, :populacao),
                               Tuple{Int,String,String,Int,Int}}

# A SIDRA recusa (HTTP 400) consultas com mais de ~50 mil valores. Com
# 2 sexos × ~100 idades, a Bahia (417 municípios) já passa disso: as
# idades vão em blocos dimensionados pelo número de territórios.
const _MAX_VALORES_SIDRA = 40_000

# Consultas de um nível e um recorte territorial. `territorio` é o trecho
# da URL, como "n3/all" ou "n6/in n3 26"; `n_territorios`, quantos ele tem.
function _consulta_idade(f, territorio::AbstractString, ano::Int, fonte_id::Symbol;
                         n_territorios::Int = 30)
    ids = _idades_sidra(f)
    extra = fonte_id === :projecao ? "/c1933/$(_id_ano_projecao(ano))" : f.extra
    por_bloco = max(1, _MAX_VALORES_SIDRA ÷ (2 * n_territorios))
    linhas = _LinhaIdade[]
    for bloco in Iterators.partition(sort!(collect(keys(ids))), por_bloco)
        url = "$_SIDRA/t/$(f.tabela)/$(replace(territorio, ' ' => "%20"))/v/$(f.variavel)" *
              "/p/$(f.periodo)/c2/4,5/c287/$(join(bloco, ','))$extra"
        _acumula_idade!(linhas, url, ids)
    end
    isempty(linhas) && error("a SIDRA não devolveu população por idade: $territorio, $ano")
    return linhas
end

function _acumula_idade!(linhas, url, ids)
    for l in _linhas_sidra(_baixa_texto(url))
        v = get(l, "V", "")
        all(isdigit, v) && !isempty(v) || continue          # "-" e "...": sem dado
        terr = first(k for k in keys(l) if k in ("Brasil", "Unidade da Federação", "Município"))
        push!(linhas, (codigo = parse(Int, l[terr]), nome = l[terr * " (nome)"],
                       sexo = l["Sexo (nome)"] == "Homens" ? "Masculino" : "Feminino",
                       idade = ids[l["Idade"]], populacao = parse(Int, v)))
    end
    return linhas
end

function _pop_idade_bruta(nivel::Symbol, ano::Int; cache::Bool)
    fonte_id = _fonte_idade(ano, nivel)
    f = _FONTES_IDADE[fonte_id]
    arq = joinpath(_dir_pop(), "idade_$(nivel)_$(ano).tsv")
    if cache && isfile(arq)
        return [let (c, n, s, i, p) = split(l, '\t')
                    _LinhaIdade((parse(Int, c), String(n), String(s), parse(Int, i), parse(Int, p)))
                end for l in eachline(arq)], fonte_id
    end
    linhas = if nivel === :municipio
        # a SIDRA limita a 100 mil valores por consulta: uma UF por vez
        n_mun = Dict{Int,Int}()
        for m in municipios()
            k = m.codigo7 ÷ 100_000
            n_mun[k] = get(n_mun, k, 0) + 1
        end
        reduce(vcat, (_consulta_idade(f, "n6/in n3 $cod", ano, fonte_id; n_territorios = n_mun[cod])
                      for cod in sort!(collect(keys(_UFS)))))
    else
        _consulta_idade(f, nivel === :uf ? "n3/all" : "n1/all", ano, fonte_id)
    end
    open(arq * ".part", "w") do io
        for l in linhas
            println(io, l.codigo, '\t', l.nome, '\t', l.sexo, '\t', l.idade, '\t', l.populacao)
        end
    end
    mv(arq * ".part", arq; force = true)
    return linhas, fonte_id
end

"""
    faixa_etaria(idade; largura = 5, aberta = 80) -> Union{String,Missing}

Faixa etária de uma idade em anos completos, no formato de
[`populacao_por_idade`](@ref): `"0 a 4 anos"`, `"5 a 9 anos"`, …,
`"80 anos ou mais"`. Use as mesmas `largura` e `aberta` dos dois lados para
que o numerador (os casos) e o denominador (a população) casem.

```julia
faixa_etaria(37)                  # "35 a 39 anos"
faixa_etaria(91)                  # "80 anos ou mais"
faixa_etaria.(df.IDADE_ANOS)      # a coluna IDADE_ANOS de process_sim/sih/sinan
```
"""
function faixa_etaria(idade::Real; largura::Int = 5, aberta::Int = 80)
    (largura ≥ 1 && aberta ≥ 0 && aberta % largura == 0) ||
        throw(ArgumentError("`aberta` deve ser múltiplo de `largura`"))
    idade < 0 && return missing
    idade ≥ aberta && return "$aberta anos ou mais"
    lo = largura * fld(floor(Int, idade), largura)
    return "$lo a $(lo + largura - 1) anos"
end
faixa_etaria(::Missing; kwargs...) = missing

"""
    populacao_por_idade(ano; nivel = :uf, largura = 5, aberta = 80, cache = true)
        -> Vector{NamedTuple}

População residente do IBGE por sexo e faixa etária — o denominador das
taxas específicas por idade e da padronização (ver
[`taxa_padronizada`](@ref)).

| ano | nível | fonte |
|---|---|---|
| 2010, 2022 | `:municipio`, `:uf`, `:brasil` e os regionais | Censo |
| demais, 2000–2060 | `:uf`, `:brasil` | projeção da população, revisão 2018 |

Os níveis regionais — `:regiao_saude`, `:macrorregiao_saude`,
`:regiao_imediata`, `:regiao_intermediaria` — somam os municípios, como em
[`populacao`](@ref), e por isso só existem nos anos de Censo.

Colunas: o código do território (`codigo7`/`codigo6`, `codigo_uf`,
`codigo_regiao_saude` e afins com `uf`, ou nenhum), `nome`, `ano`, `sexo` (`"Masculino"`/`"Feminino"`), `faixa`
(`"0 a 4 anos"` … `"80 anos ou mais"`, como em [`faixa_etaria`](@ref)),
`idade_min`, `populacao` e `fonte`.

!!! warning "A projeção é anterior ao Censo 2022"
    Fora dos anos de Censo, os números vêm da projeção do IBGE revista em
    2018, que superestima a população como as estimativas de 2011–2021
    (Brasil: 213,3 milhões projetados para 2021 contra 203,1 milhões
    recenseados em 2022). Para padronizar — onde importam as proporções
    entre faixas — o efeito é menor que para contar habitantes; a coluna
    `fonte` registra de onde veio cada número.

`largura` e `aberta` definem as faixas; `aberta` não pode passar do grupo
aberto da fonte (90 na projeção, 100 nos Censos). A consulta à SIDRA é por
idade simples e fica em cache; no nível municipal, uma UF por vez.
"""
function populacao_por_idade(ano::Integer; nivel::Symbol = :uf, largura::Int = 5,
                             aberta::Int = 80, cache::Bool = true)
    nivel_sidra = _confere_nivel(nivel)
    nivel in _NIVEIS_REGIONAIS && ano ∉ (2010, 2022) && throw(ArgumentError(
        "nivel = :$nivel soma municípios, que o IBGE só publica por sexo e idade " *
        "nos Censos (2010 e 2022); para $ano use nivel = :uf ou :brasil"))
    linhas, fonte_id = _pop_idade_bruta(nivel_sidra, Int(ano); cache)
    regional = nivel in _NIVEIS_REGIONAIS
    regional && (linhas = _agrega_regiao(linhas, nivel))
    topo = maximum(l.idade for l in linhas)
    aberta ≤ topo || throw(ArgumentError(
        "`aberta = $aberta` passa do grupo aberto da fonte ($topo anos ou mais)"))
    soma = Dict{Tuple{Int,String,String},Int}()
    nomes = Dict{Int,String}(); ufs = Dict{Int,String}()
    for l in linhas
        k = (l.codigo, l.sexo, faixa_etaria(l.idade; largura, aberta))
        soma[k] = get(soma, k, 0) + l.populacao
        nomes[l.codigo] = l.nome
        regional && (ufs[l.codigo] = l.uf)
    end
    fonte = _FONTES_IDADE[fonte_id].fonte
    regional && (fonte = "soma dos municípios — " * fonte)
    idade_min(fx) = parse(Int, match(r"^(\d+)", fx)[1])
    chaves = sort!(collect(keys(soma)); by = k -> (k[1], k[2], idade_min(k[3])))
    return map(chaves) do k
        cod, sexo, fx = k
        base = (nome = nomes[cod], ano = Int(ano), sexo = sexo, faixa = fx,
                idade_min = idade_min(fx), populacao = soma[k], fonte = fonte)
        nivel === :municipio ? (codigo7 = cod, codigo6 = cod ÷ 10, base...) :
        nivel === :uf ? (codigo_uf = cod, base...) :
        regional ? merge(NamedTuple{(Symbol(:codigo_, nivel),)}((cod,)),
                         (nome = base.nome, uf = ufs[cod]), base) : base
    end
end

"""
    taxa_padronizada(casos, populacao, padrao; por = 100_000) -> NamedTuple

Taxa padronizada por idade pelo método direto: a taxa que a população
estudada teria se tivesse a estrutura etária de `padrao`. Os três vetores
são por faixa, na mesma ordem: `casos` (eventos), `populacao` (a do
denominador) e `padrao` (a população-padrão, ou só os seus pesos).

Devolve `taxa` (padronizada), `bruta` (casos/população), `erro_padrao`
(aproximação de Poisson: por² · Σ wᵢ² · casosᵢ / populaçãoᵢ²) e `pesos`.

```julia
pop = DataFrame(populacao_por_idade(2022; nivel = :uf))
br  = DataFrame(populacao_por_idade(2022; nivel = :brasil))   # padrão: Brasil, Censo 2022
# casos por faixa (com faixa_etaria nos microdados), alinhados às faixas de `pop`…
taxa_padronizada(casos, pe.populacao, br.populacao)
```

Para eventos raros, com poucos casos por faixa, o erro-padrão de Poisson
subestima a incerteza; intervalos exatos (gama, Fay & Feuer 1997) pedem
outra ferramenta.
"""
function taxa_padronizada(casos::AbstractVector, populacao::AbstractVector,
                          padrao::AbstractVector; por::Real = 100_000)
    # depois de um leftjoin as colunas vêm Union{Missing,…} mesmo sem
    # missing; só um missing de fato é erro
    for (nome, v) in (("casos", casos), ("populacao", populacao), ("padrao", padrao))
        any(ismissing, v) && throw(ArgumentError(
            "`$nome` tem faixa sem valor (missing) — confira o join das faixas"))
    end
    casos, populacao, padrao = Float64.(casos), Float64.(populacao), Float64.(padrao)
    n = length(casos)
    (length(populacao) == n && length(padrao) == n) || throw(DimensionMismatch(
        "casos, populacao e padrao precisam ter uma entrada por faixa ($n, " *
        "$(length(populacao)), $(length(padrao)))"))
    any(≤(0), populacao) && throw(ArgumentError("populacao com faixa zerada ou negativa"))
    w = padrao ./ sum(padrao)
    especificas = casos ./ populacao
    return (taxa = por * sum(w .* especificas),
            bruta = por * sum(casos) / sum(populacao),
            erro_padrao = por * sqrt(sum(w .^ 2 .* casos ./ populacao .^ 2)),
            pesos = w)
end

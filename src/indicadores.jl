# ─────────────────────────────────────────────────────────────────────
# Indicadores de mortalidade com método documentado (RIPSA).
#
# Todos por local de residência (CODMUNRES) e ano do evento (DTOBITO,
# DTNASC), como a RIPSA define, em qualquer nível territorial do pacote.
# São as taxas pelo método direto — sem os fatores de correção de
# sub-registro que o Ministério da Saúde aplica a parte das UFs —, e por
# isso podem ficar abaixo dos números oficiais onde a cobertura do SIM e do
# SINASC é incompleta.
# ─────────────────────────────────────────────────────────────────────

const _NIVEIS_INDICADOR = (:brasil, :uf, :municipio, :regiao_saude, :macrorregiao_saude,
                           :regiao_imediata, :regiao_intermediaria)

# coluna de código e de nome de cada nível, na saída
_colunas_territorio(nivel) =
    nivel === :brasil    ? (nothing, nothing) :
    nivel === :uf        ? (:codigo_uf, :uf) :
    nivel === :municipio ? (:codigo6, :nome) :
                           (Symbol(:codigo_, nivel), :nome)

function _confere_nivel_indicador(nivel)
    nivel in _NIVEIS_INDICADOR || throw(ArgumentError(
        "nivel deve ser um de $(join(_NIVEIS_INDICADOR, ", ", " ou ")) (recebi :$nivel)"))
end

# (código, nome) do território de residência; `nothing` se o código não
# permite atribuir (município ignorado num nível abaixo da UF)
function _territorio(cod, nivel::Symbol)
    nivel === :brasil && return (0, "Brasil")
    c = _cod_mun(cod)
    c === nothing && return nothing
    if nivel === :uf
        u = _cod_uf(c)
        s = get(_UFS, u, nothing)
        return s === nothing ? nothing : (u, s[1])
    end
    m = municipio(c)
    m === nothing && return nothing
    nivel === :municipio && return (m.codigo6, m.nome)
    return (getfield(m, Symbol(:codigo_, nivel)), getfield(m, nivel))
end

# ano de cada registro: da data do evento, ou do arquivo
function _anos_evento(df, col_data::Symbol)
    if hasproperty(df, col_data) && eltype(df[!, col_data]) <: Union{Missing,Date}
        return [ismissing(d) ? missing : year(d) for d in df[!, col_data]]
    end
    hasproperty(df, :ANO_ARQUIVO) && return collect(Union{Missing,Int}, df.ANO_ARQUIVO)
    throw(ArgumentError("sem ano do evento: falta `$col_data` como data (use " *
                        "fetch_datasus/ler com o schema do sistema) ou `ANO_ARQUIVO`"))
end

_coluna(df, c) = hasproperty(df, c) ? df[!, c] : throw(ArgumentError(
    "falta a coluna `$c` — os indicadores pedem o layout do SIM/SINASC"))

# Conta, por (território, ano), quantos registros caem em cada uma das
# `k` categorias de `classe(i)` (um vetor de Bool por registro). Devolve
# também quantos registros não puderam ser atribuídos a um território.
function _conta_por_territorio(cods, anos, nivel, k, classe)
    memo = Dict{Any,Any}()
    acc = Dict{Tuple{Int,Int},Vector{Int}}()
    nomes = Dict{Int,String}()
    sem_territorio = 0
    for i in eachindex(cods)
        a = anos[i]
        ismissing(a) && continue
        t = get!(() -> _territorio(cods[i], nivel), memo, cods[i])
        if t === nothing
            sem_territorio += 1
            continue
        end
        nomes[t[1]] = t[2]
        v = get!(() -> zeros(Int, k), acc, (t[1], a))
        cl = classe(i)
        for j in 1:k
            cl[j] && (v[j] += 1)
        end
    end
    return acc, nomes, sem_territorio
end

function _tabela_indicador(nivel, nomes, linhas)
    cc, cn = _colunas_territorio(nivel)
    df = DataFrame(linhas)
    if cc !== nothing
        insertcols!(df, 1, cc => [l.codigo for l in linhas],
                    cn => [nomes[l.codigo] for l in linhas])
    end
    select!(df, Not(:codigo))
    sort!(df, [c for c in (cc, :ano) if c !== nothing])
    return df
end

function _aviso_sem_territorio(n, nivel, oque)
    n > 0 && @warn "$n $oque com município de residência ignorado ou fora da " *
                   "tabela ficaram fora do nível :$nivel (contam em :uf e :brasil)"
end

# idade em dias, do campo IDADE do SIM: decodificado em anos pelo schema,
# ou o código cru (unidade + valor)
_idade_dias(x::Real) = round(x * 365.25; digits = 6)
function _idade_dias(s::AbstractString)
    t = strip(s)
    (length(t) == 3 && all(isdigit, t)) || return missing
    u = t[1] - '0'; v = 10 * (t[2] - '0') + (t[3] - '0')
    u == 0 && return v / 1440
    u == 1 && return v / 24
    u == 2 && return Float64(v)
    u == 3 && return v * 365.25 / 12
    u == 4 && return v * 365.25
    u == 5 && return (100 + v) * 365.25
    return missing
end
_idade_dias(::Missing) = missing

function _nascidos_por_territorio(nascidos, nivel)
    acc, nomes, sem = _conta_por_territorio(_coluna(nascidos, :CODMUNRES),
                                            _anos_evento(nascidos, :DTNASC), nivel, 1, _ -> (true,))
    _aviso_sem_territorio(sem, nivel, "nascidos vivos")
    return Dict(k => v[1] for (k, v) in acc), nomes
end

_por(x, n, k) = n == 0 ? missing : round(k * x / n; digits = 2)

"""
    mortalidade_infantil(obitos, nascidos; nivel = :uf) -> DataFrame

Taxa de mortalidade infantil e seus componentes (RIPSA C.1 a C.1.3), por
1.000 nascidos vivos, por território de residência e ano:

- `obitos_infantis` / `taxa` — óbitos de menores de 1 ano;
- `neonatal_precoce` / `taxa_neonatal_precoce` — 0 a 6 dias;
- `neonatal_tardia` / `taxa_neonatal_tardia` — 7 a 27 dias;
- `pos_neonatal` / `taxa_pos_neonatal` — 28 dias a menos de 1 ano.

`obitos` vem do SIM (`fetch_datasus(:SIM_DO, …)` ou `:SIM_DOINF`) e
`nascidos` do SINASC (`fetch_datasus(:SINASC, …)`), com as mesmas UFs e
anos. `nivel`: `:brasil`, `:uf`, `:municipio`, `:regiao_saude`,
`:macrorregiao_saude`, `:regiao_imediata` ou `:regiao_intermediaria`.

```julia
do_ = fetch_datasus(:SIM_DO; uf = "PE", anos = 2022)
dn  = fetch_datasus(:SINASC; uf = "PE", anos = 2022)
mortalidade_infantil(do_, dn; nivel = :regiao_saude)
```

Método direto, sem os fatores de correção de sub-registro que o Ministério
da Saúde aplica onde a cobertura do SIM e do SINASC é incompleta (parte do
Norte e do Nordeste): ali a taxa fica abaixo da oficial. Óbitos com idade
ignorada ficam fora. Em município pequeno a taxa oscila muito de um ano
para o outro — a RIPSA recomenda agregar anos ou usar nível maior.
"""
function mortalidade_infantil(obitos::AbstractDataFrame, nascidos::AbstractDataFrame;
                              nivel::Symbol = :uf)
    _confere_nivel_indicador(nivel)
    dias = _idade_dias.(_coluna(obitos, :IDADE))
    classe(i) = (d = dias[i]; ismissing(d) ? (false, false, false, false) :
                 (d < 365.25, d < 7, 7 <= d < 28, 28 <= d < 365.25))
    acc, nomes, sem = _conta_por_territorio(_coluna(obitos, :CODMUNRES),
                                            _anos_evento(obitos, :DTOBITO), nivel, 4, classe)
    _aviso_sem_territorio(sem, nivel, "óbitos")
    nv, nomes_nv = _nascidos_por_territorio(nascidos, nivel)
    merge!(nomes, nomes_nv)
    linhas = map(collect(union(keys(nv), keys(acc)))) do k
        o = get(acc, k, zeros(Int, 4)); n = get(nv, k, 0)
        (codigo = k[1], ano = k[2], nascidos_vivos = n,
         obitos_infantis = o[1], neonatal_precoce = o[2], neonatal_tardia = o[3], pos_neonatal = o[4],
         taxa = _por(o[1], n, 1000), taxa_neonatal_precoce = _por(o[2], n, 1000),
         taxa_neonatal_tardia = _por(o[3], n, 1000), taxa_pos_neonatal = _por(o[4], n, 1000))
    end
    return _tabela_indicador(nivel, nomes, linhas)
end

# causas de morte materna pela CID-10 (capítulo XV menos O96–O97, que são
# mortes tardias e sequelas, mais o tétano obstétrico)
const CID_MATERNA = ("O00" => "O95", "O98" => "O99", "A34")

"""
    razao_mortalidade_materna(obitos, nascidos; nivel = :uf) -> DataFrame

Razão de mortalidade materna (RIPSA C.3): óbitos maternos por 100.000
nascidos vivos, por território de residência e ano. Óbito materno é o de
causa básica em O00–O95, O98–O99 ou A34 (tétano obstétrico) — o capítulo
XV da CID-10 sem as mortes maternas tardias e as sequelas (O96, O97).

```julia
razao_mortalidade_materna(do_, dn; nivel = :uf)
```

Como na [`mortalidade_infantil`](@ref): método direto, sem fatores de
correção — o Ministério da Saúde corrige a RMM pelo sub-registro e pela
má classificação das causas, e a razão oficial costuma ficar acima desta. A
RIPSA inclui ainda, sob condições (morte durante a gravidez ou o puerpério),
F53, M83.0, D39.2, E23.0 e B20–B24; elas não entram aqui. Com poucos óbitos
por território, a razão é instável: agregue anos.
"""
function razao_mortalidade_materna(obitos::AbstractDataFrame, nascidos::AbstractDataFrame;
                                   nivel::Symbol = :uf)
    _confere_nivel_indicador(nivel)
    causa = _coluna(obitos, :CAUSABAS)
    acc, nomes, sem = _conta_por_territorio(_coluna(obitos, :CODMUNRES),
                                            _anos_evento(obitos, :DTOBITO), nivel, 1,
                                            i -> (cid_casa(causa[i], CID_MATERNA),))
    _aviso_sem_territorio(sem, nivel, "óbitos")
    nv, nomes_nv = _nascidos_por_territorio(nascidos, nivel)
    merge!(nomes, nomes_nv)
    linhas = map(collect(union(keys(nv), keys(acc)))) do k
        o = get(acc, k, [0])[1]; n = get(nv, k, 0)
        (codigo = k[1], ano = k[2], nascidos_vivos = n, obitos_maternos = o,
         razao = _por(o, n, 100_000))
    end
    return _tabela_indicador(nivel, nomes, linhas)
end

"""
    proporcao_mal_definidas(obitos; nivel = :uf) -> DataFrame

Proporção de óbitos por causas mal definidas: causa básica no capítulo
XVIII da CID-10 (R00–R99), em % do total de óbitos, por território de
residência e ano. É a medida mais usada da qualidade da declaração da causa
de morte: onde ela é alta, qualquer análise por causa subestima as causas
de fato.
`auditar` mostra, além disso, os códigos que não valem como causa
básica.
"""
function proporcao_mal_definidas(obitos::AbstractDataFrame; nivel::Symbol = :uf)
    _confere_nivel_indicador(nivel)
    causa = _coluna(obitos, :CAUSABAS)
    acc, nomes, sem = _conta_por_territorio(_coluna(obitos, :CODMUNRES),
                                            _anos_evento(obitos, :DTOBITO), nivel, 2,
                                            i -> (true, startswith(normaliza_cid(causa[i]), 'R')))
    _aviso_sem_territorio(sem, nivel, "óbitos")
    linhas = [(codigo = k[1], ano = k[2], obitos = v[1], mal_definidas = v[2],
               proporcao = _por(v[2], v[1], 100)) for (k, v) in acc]
    return _tabela_indicador(nivel, nomes, linhas)
end

# as quatro DCNT do Plano de Ações Estratégicas (2021–2030) e da meta 3.4
# dos ODS: circulatórias, neoplasias, respiratórias crônicas e diabetes
const CID_DCNT = ("I00" => "I99", "C00" => "C97", "J30" => "J98", "E10" => "E14")

"""
    mortalidade_prematura_dcnt(obitos; nivel = :uf, populacao = nothing) -> DataFrame

Taxa de mortalidade prematura (30 a 69 anos) pelas quatro principais
doenças crônicas não transmissíveis — circulatórias (I00–I99), neoplasias
(C00–C97), respiratórias crônicas (J30–J98) e diabetes (E10–E14) —, por
100.000 habitantes de 30 a 69 anos: o indicador do Plano de DANT
2021–2030 e da meta 3.4 dos ODS. Por território de residência e ano.

O denominador vem de [`populacao_por_idade`](@ref) (SIDRA, com cache):
Censos de 2010 e 2022 em qualquer nível; nos demais anos, a projeção do
IBGE, só para `:uf` e `:brasil`. `populacao` aceita uma tabela pronta,
com a coluna de território do `nivel` (`codigo_uf`, `codigo6`,
`codigo_regiao_saude`…), `ano` e `populacao` (já de 30 a 69 anos).

Taxa bruta, como no Plano de DANT; para comparar lugares com estruturas
etárias diferentes, padronize ([`taxa_padronizada`](@ref)).
"""
function mortalidade_prematura_dcnt(obitos::AbstractDataFrame; nivel::Symbol = :uf,
                                    populacao = nothing)
    _confere_nivel_indicador(nivel)
    causa = _coluna(obitos, :CAUSABAS)
    dias = _idade_dias.(_coluna(obitos, :IDADE))
    acc, nomes, sem = _conta_por_territorio(_coluna(obitos, :CODMUNRES),
                                            _anos_evento(obitos, :DTOBITO), nivel, 1,
        i -> (d = dias[i];
              (!ismissing(d) && 30 * 365.25 <= d < 70 * 365.25 && cid_casa(causa[i], CID_DCNT),)))
    _aviso_sem_territorio(sem, nivel, "óbitos")
    pop = populacao === nothing ? _pop_30_69(nivel, sort!(unique(k[2] for k in keys(acc)))) :
                                  _pop_de_tabela(populacao, nivel)
    linhas = map(collect(keys(acc))) do k
        o = acc[k][1]; p = get(pop, k, missing)
        (codigo = k[1], ano = k[2], obitos_dcnt_30_69 = o, populacao_30_69 = p,
         taxa = ismissing(p) ? missing : _por(o, p, 100_000))
    end
    return _tabela_indicador(nivel, nomes, linhas)
end

function _pop_30_69(nivel, anos)
    out = Dict{Tuple{Int,Int},Int}()
    cc, _ = _colunas_territorio(nivel)
    nivel_pop = nivel
    for a in anos
        for r in populacao_por_idade(a; nivel = nivel_pop)
            30 <= r.idade_min <= 65 || continue
            cod = cc === nothing ? 0 : getproperty(r, cc === :codigo6 ? :codigo6 : cc)
            out[(cod, a)] = get(out, (cod, a), 0) + r.populacao
        end
    end
    return out
end

function _pop_de_tabela(t, nivel)
    cc, _ = _colunas_territorio(nivel)
    out = Dict{Tuple{Int,Int},Int}()
    for r in Tables.rows(t)
        cod = cc === nothing ? 0 : Int(Tables.getcolumn(r, cc))
        out[(cod, Int(r.ano))] = Int(r.populacao)
    end
    return out
end

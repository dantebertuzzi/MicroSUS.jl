# ─────────────────────────────────────────────────────────────────────
# Auditoria de qualidade dos microdados: o que olhar antes de analisar.
#
# O DATASUS não usa `missing`: ausência vem codificada, campos param de ser
# preenchidos no meio de uma série, layouts mudam entre anos, e uma parte
# das causas básicas declaradas não informa a causa de fato. Nada disso
# aparece num `describe`. `auditar` reúne as checagens que o notebook do
# Colab faz à mão.
# ─────────────────────────────────────────────────────────────────────

"""
Resultado de [`auditar`](@ref). Cada campo é um `DataFrame`:

- `completude` — por coluna e ano: `n`, `preenchidos`, `pct_preenchido`;
- `descontinuidades` — colunas cujo preenchimento muda de um ano para o
  seguinte em `limiar` pontos percentuais ou mais (campo que parou ou
  começou a ser preenchido, ou mudança de layout);
- `causas` — por ano, só com `CAUSABAS` (SIM): causas mal definidas
  (capítulo XVIII, R00–R99), códigos que não valem como causa básica e
  códigos fora da CID-10;
- `implausiveis` — por regra: quantos registros, a fração e alguns
  exemplos.
"""
struct Auditoria
    n::Int
    coluna_ano::Union{Symbol,Nothing}
    completude::DataFrame
    descontinuidades::DataFrame
    causas::Union{DataFrame,Nothing}
    implausiveis::DataFrame
end

const _COLUNAS_DE_ORIGEM = (:UF_ARQUIVO, :ANO_ARQUIVO, :MES_ARQUIVO, :PRELIMINAR, :ARQUIVO)
const _COLUNAS_DE_DATA = (:DTOBITO, :DTNASC, :DT_NOTIFIC, :DT_INTER, :DT_SAIDA)

_ausente(x) = ismissing(x)
_ausente(x::AbstractString) = all(isspace, x)

# o ano de cada registro: a coluna pedida, a de origem do fetch_datasus, ou
# o ano da primeira data de evento presente
function _anos_registros(df, ano)
    ano === false && return nothing, fill(missing, nrow(df))
    i = findfirst(c -> hasproperty(df, c) && eltype(df[!, c]) <: Union{Missing,Date},
                  collect(_COLUNAS_DE_DATA))
    col = ano isa Symbol ? ano :
          hasproperty(df, :ANO_ARQUIVO) ? :ANO_ARQUIVO :
          i === nothing ? nothing : _COLUNAS_DE_DATA[i]
    col === nothing && return nothing, fill(missing, nrow(df))
    v = df[!, col]
    anos = eltype(v) <: Union{Missing,Date} ? [ismissing(x) ? missing : year(x) for x in v] :
           [ismissing(x) ? missing : Int(x) for x in v]
    return col, anos
end

"""
    auditar(df; ano = nothing, limiar = 20) -> MicroSUS.Auditoria

Checagens de qualidade de um resultado de [`fetch_datasus`](@ref) (ou de
[`ler`](@ref)) — o que olhar antes de analisar. Mostra um resumo; os
detalhes ficam nos campos de [`MicroSUS.Auditoria`](@ref).

```julia
df = fetch_datasus(:SIM_DO; uf = "PE", anos = 2014:2023)
a = auditar(df)
a.descontinuidades                 # campos que pararam (ou começaram) a ser preenchidos
a.causas                           # % de causas mal definidas por ano
filter(r -> r.ano == 2023, a.completude)
```

- **Completude** por coluna e ano. Ausente é `missing` ou texto vazio. Os
  códigos de "ignorado" (`9`, `0`…) só contam como ausência nos dados
  **padronizados** (`processar = true`, o padrão), onde viram `missing`; nos
  brutos, são um código como outro.
- **Descontinuidades**: o preenchimento muda `limiar` pontos percentuais
  (padrão 20) ou mais entre um ano e o seguinte — um campo que deixa de
  existir no layout aparece aqui como queda para 0%. Anos com menos de 10%
  dos registros do maior (as notificações de 2024 dentro do arquivo do
  SINAN de 2023) ficam fora da comparação.
- **Causas básicas** (SIM): mal definidas (R00–R99) e códigos que a CID-10
  marca como não utilizáveis como causa básica — medidas clássicas da
  qualidade da declaração de óbito ([`cid10`](@ref)) —, e códigos que nem
  estão na CID-10.
- **Valores implausíveis**: idade acima de 120 anos ou negativa, datas de
  evento no futuro ou antes de 1900 (de nascimento, só no futuro),
  nascimento depois do óbito, peso fora de 100–7.000 g, idade da mãe fora
  de 10–60, semanas de gestação fora de 20–45 (o 99 de "ignorado" não
  conta), causa básica incompatível com o sexo. São marcas para revisar, não
  erros certos: `exemplos` traz as primeiras linhas de cada regra.

O ano vem de `ano` (uma coluna), de `ANO_ARQUIVO` ou da primeira data de
evento tipada (`DTOBITO`, `DTNASC`, `DT_NOTIFIC`…); `ano = false` audita
tudo junto.
"""
function auditar(df::AbstractDataFrame; ano = nothing, limiar::Real = 20)
    col_ano, anos = _anos_registros(df, ano)
    colunas = [c for c in propertynames(df) if !(c in _COLUNAS_DE_ORIGEM) && c !== col_ano]
    completude = _completude(df, colunas, anos)
    return Auditoria(nrow(df), col_ano, completude,
                     _descontinuidades(completude, limiar),
                     hasproperty(df, :CAUSABAS) ? _causas(df, anos) : nothing,
                     _implausiveis(df))
end

function _completude(df, colunas, anos)
    grupos = Dict{Any,Vector{Int}}()
    for (i, a) in enumerate(anos)
        push!(get!(Vector{Int}, grupos, a), i)
    end
    chaves = sort!(collect(keys(grupos)); by = a -> ismissing(a) ? typemax(Int) : a)
    linhas = NamedTuple[]
    for c in colunas, a in chaves
        idx = grupos[a]
        v = view(df[!, c], idx)
        p = count(!_ausente, v)
        push!(linhas, (coluna = c, ano = a, n = length(idx), preenchidos = p,
                       pct_preenchido = round(100 * p / max(length(idx), 1); digits = 1)))
    end
    return DataFrame(linhas)
end

# Anos com poucos registros não entram na comparação: um arquivo do SINAN
# de 2023 traz centenas de notificações datadas de 2024, e uma porcentagem
# sobre elas não diz nada do campo.
function _descontinuidades(comp::DataFrame, limiar)
    out = NamedTuple[]
    nmax = isempty(comp) ? 0 : maximum(comp.n)
    for g in groupby(comp, :coluna; sort = false)
        g = filter(r -> !ismissing(r.ano) && r.n >= 0.1 * nmax, g)
        for i in 2:nrow(g)
            a, b = g.pct_preenchido[i-1], g.pct_preenchido[i]
            abs(b - a) ≥ limiar || continue
            push!(out, (coluna = g.coluna[i], ano_antes = g.ano[i-1], ano = g.ano[i],
                        pct_antes = a, pct = b, salto = round(b - a; digits = 1)))
        end
    end
    isempty(out) && return DataFrame(coluna = Symbol[], ano_antes = Int[], ano = Int[],
                                     pct_antes = Float64[], pct = Float64[], salto = Float64[])
    return sort!(DataFrame(out), [:coluna, :ano])
end

function _causas(df, anos)
    acc = Dict{Any,Vector{Int}}()     # ano => [n, mal_definidas, nao_basica, fora_da_cid]
    for (c, a) in zip(df.CAUSABAS, anos)
        v = get!(() -> zeros(Int, 4), acc, a)
        cod = normaliza_cid(c)
        isempty(cod) && continue
        v[1] += 1
        startswith(cod, 'R') && (v[2] += 1)
        r = cid10(cod)
        if r === nothing
            v[4] += 1
        elseif !r.causa_basica_valida
            v[3] += 1
        end
    end
    pct(x, n) = round(100 * x / max(n, 1); digits = 2)
    linhas = [(ano = a, n = v[1], mal_definidas = v[2], pct_mal_definidas = pct(v[2], v[1]),
               nao_causa_basica = v[3], pct_nao_causa_basica = pct(v[3], v[1]),
               fora_da_cid10 = v[4])
              for (a, v) in acc]
    return sort!(DataFrame(linhas), :ano; by = a -> ismissing(a) ? typemax(Int) : a)
end

# ── valores implausíveis ─────────────────────────────────────────────

_num(x::Real) = Float64(x)
_num(x::AbstractString) = (v = tryparse(Float64, strip(x)); v === nothing ? missing : v)
_num(::Missing) = missing

_sexo_de(x::AbstractString) = (s = uppercase(strip(x));
    s in ("1", "M", "MASCULINO") ? 'M' : s in ("2", "3", "F", "FEMININO") ? 'F' : missing)
_sexo_de(::Missing) = missing

# cada regra: (descrição, coluna, marcas) — `marcas` é um vetor de Bool,
# calculado sobre a coluna inteira (função barreira: o tipo da coluna é
# conhecido dentro de `_marca`)
_marca(f, v::AbstractVector) = BitVector(map(x -> !ismissing(x) && f(x), v))

function _implausiveis(df)
    hoje = today()
    regras = Tuple{String,Symbol,BitVector}[]
    for c in (:IDADE_ANOS, :IDADE)
        if hasproperty(df, c) && eltype(df[!, c]) <: Union{Missing,Real}
            push!(regras, ("idade acima de 120 anos ou negativa", c,
                           _marca(x -> x > 120 || x < 0, df[!, c])))
            break
        end
    end
    _eh_data(c) = hasproperty(df, c) && eltype(df[!, c]) <: Union{Missing,Date}
    for c in _COLUNAS_DE_DATA
        _eh_data(c) || continue
        # nascimento antes de 1900 é o de quem morre com mais de 120 anos,
        # que a regra da idade já pega; para ele, só o futuro
        c === :DTNASC ? push!(regras, ("data no futuro", c, _marca(>(hoje), df[!, c]))) :
                        push!(regras, ("data no futuro ou antes de 1900", c,
                                       _marca(x -> x > hoje || x < Date(1900), df[!, c])))
    end
    if _eh_data(:DTNASC) && _eh_data(:DTOBITO)
        push!(regras, ("nascimento depois do óbito", :DTNASC,
                       BitVector(map((n, o) -> !ismissing(n) && !ismissing(o) && n > o,
                                     df.DTNASC, df.DTOBITO))))
    end
    # 99 é "ignorado" em IDADEMAE e SEMAGESTAC; peso abaixo de 300 g é
    # comum entre os óbitos fetais do SIM, então o piso é 100 g
    for (c, lo, hi, ign, txt) in ((:PESO, 100, 7000, nothing, "peso fora de 100–7.000 g"),
                                  (:IDADEMAE, 10, 60, 99, "idade da mãe fora de 10–60 anos"),
                                  (:SEMAGESTAC, 20, 45, 99, "semanas de gestação fora de 20–45"))
        hasproperty(df, c) || continue
        push!(regras, (txt, c, _marca(df[!, c]) do x
            v = _num(x)
            !ismissing(v) && v != something(ign, -1) && (v < lo || v > hi)
        end))
    end
    if hasproperty(df, :CAUSABAS) && hasproperty(df, :SEXO)
        push!(regras, ("causa básica incompatível com o sexo", :CAUSABAS,
                       BitVector(map(df.CAUSABAS, df.SEXO) do c, sx
                           s = _sexo_de(sx); r = cid10(c)
                           !ismissing(s) && r !== nothing && !ismissing(r.sexo) && r.sexo != s
                       end)))
    end
    n = nrow(df)
    linhas = [(regra = txt, coluna = c, n = count(m),
               pct = round(100 * count(m) / max(n, 1); digits = 3),
               exemplos = findall(m)[1:min(5, count(m))])
              for (txt, c, m) in regras]
    isempty(linhas) && return DataFrame(regra = String[], coluna = Symbol[], n = Int[],
                                        pct = Float64[], exemplos = Vector{Int}[])
    return DataFrame(linhas)
end

# ── resumo ───────────────────────────────────────────────────────────

function Base.show(io::IO, ::MIME"text/plain", a::Auditoria)
    anos = sort!(unique(skipmissing(a.completude.ano)))
    println(io, "Auditoria — ", a.n, " registros",
            isempty(anos) ? "" : first(anos) == last(anos) ? ", $(first(anos))" :
                                 ", $(first(anos))–$(last(anos))",
            a.coluna_ano === nothing ? "" : " (ano de $(a.coluna_ano))")
    g = combine(groupby(a.completude, :coluna; sort = false),
                [:preenchidos, :n] => ((p, n) -> round(100 * sum(p) / max(sum(n), 1); digits = 1)) => :pct)
    vazias = count(==(0), g.pct)
    piores = first(sort(filter(r -> 0 < r.pct < 100, g), :pct), 5)
    println(io, "\n  Completude: ", nrow(g), " colunas; ", count(==(100), g.pct),
            " sempre preenchidas, ", vazias, " sempre vazias")
    for r in eachrow(piores)
        println(io, "    ", rpad(r.coluna, 12), lpad(string(r.pct, "%"), 7))
    end
    if !isempty(a.descontinuidades)
        println(io, "\n  Descontinuidades: ", nrow(a.descontinuidades),
                " (campo que muda de preenchimento entre anos)")
        for r in eachrow(first(sort(a.descontinuidades, :salto; by = abs, rev = true), 5))
            println(io, "    ", rpad(r.coluna, 12), r.ano_antes, "→", r.ano, ": ",
                    r.pct_antes, "% → ", r.pct, "%")
        end
    end
    if a.causas !== nothing && nrow(a.causas) > 0
        tot = sum(a.causas.n)
        println(io, "\n  Causas básicas: ",
                round(100 * sum(a.causas.mal_definidas) / max(tot, 1); digits = 1),
                "% mal definidas (R00–R99), ",
                round(100 * sum(a.causas.nao_causa_basica) / max(tot, 1); digits = 1),
                "% com código que não vale como causa básica")
    end
    achadas = filter(r -> r.n > 0, a.implausiveis)
    println(io, "\n  Valores implausíveis: ", isempty(achadas) ? "nenhum" : "")
    for r in eachrow(achadas)
        println(io, "    ", r.regra, " (", r.coluna, "): ", r.n)
    end
    print(io, "\n  Detalhes: .completude, .descontinuidades, .causas, .implausiveis")
end

Base.show(io::IO, a::Auditoria) = print(io, "Auditoria(", a.n, " registros)")

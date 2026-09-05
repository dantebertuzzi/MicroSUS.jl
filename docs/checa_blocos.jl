#!/usr/bin/env julia
#
# Verifica os blocos ```julia das páginas em docs/src.
#
# As páginas de exemplos são pipelines: os blocos compartilham estado e rodam
# na ordem em que aparecem. Isso é bom para o leitor e frágil para quem edita —
# mover um trecho ou renomear uma variável quebra a página sem quebrar o build,
# porque o Documenter não executa blocos ```julia. Três defeitos possíveis, e
# este script cobre os três:
#
#   1. bloco que não parseia;
#   2. nome usado antes de ser definido na própria página;
#   2b. nome que a página nunca define e que módulo nenhum exporta;
#   3. coluna acessada num DataFrame que não a carregou.
#
# (2) dispensa lista de nomes conhecidos: só acusa nomes que a página define em
# algum lugar. (2b) precisa saber o que vem de fora, e por isso resolve cada
# nome contra os módulos que a página declara em `using`. Se algum deles não
# estiver instalado no ambiente, (2b) é desligada naquela página inteira — vale
# perder cobertura, nunca acusar em falso e travar o CI.
#
# (2b) também só vale para as páginas de PIPELINE listadas abaixo. As do guia
# são trechos de referência, não uma sequência executável: usam marcadores como
# `caminho` de propósito, e exigir que cada nome exista seria cobrar delas um
# contrato que não têm.
#
# Uso: julia docs/checa_blocos.jl [arquivo.md ...]   (sem argumento: docs/src/**)

const BLOCO = r"```julia\n(.*?)```"s

"Páginas cujos blocos formam uma sequência executável de ponta a ponta."
const PIPELINES = ["exemplos.md", "exemplos-intermediarios.md"]

"Bloco que é transcrição de REPL (`julia> ...` com a saída junto)."
é_repl(código) = occursin(r"^julia> "m, código)

"Extrai (linha_inicial, código) de cada bloco ```julia do markdown."
function blocos(md::AbstractString)
    out = Tuple{Int,String}[]
    for m in eachmatch(BLOCO, md)
        é_repl(m.captures[1]) && continue
        linha = count(==('\n'), md[1:prevind(md, m.offset)]) + 2
        push!(out, (linha, m.captures[1]))
    end
    out
end

const IGNORA_EXPR = (:quote, :meta, :inert)

"Símbolos ligados dentro de `ex`: parâmetros, variáveis de laço, atribuições locais."
function ligados!(acc::Set{Symbol}, ex)
    ex isa Expr || return acc
    if ex.head === :function || (ex.head === :(=) && ex.args[1] isa Expr &&
                                 ex.args[1].head === :call)
        assinatura = ex.args[1]
        for a in assinatura.args[2:end]
            nomes_de!(acc, a)
        end
    elseif ex.head in (:for, :generator, :comprehension)
        for a in ex.args
            if a isa Expr && a.head === :(=)
                nomes_de!(acc, a.args[1])
            end
        end
    elseif ex.head === :do
        length(ex.args) ≥ 2 && ex.args[2] isa Expr && nomes_de!(acc, ex.args[2].args[1])
    elseif ex.head === :(=)
        nomes_de!(acc, ex.args[1])
    elseif ex.head === :(->)
        nomes_de!(acc, ex.args[1])
    end
    for a in ex.args
        a isa Expr && !(a.head in IGNORA_EXPR) && ligados!(acc, a)
    end
    acc
end

"Nomes ligados por um alvo de atribuição (`a`, `a, b`, `a::T`, `(a, b)`)."
function nomes_de!(acc::Set{Symbol}, alvo)
    if alvo isa Symbol
        push!(acc, alvo)
    elseif alvo isa Expr
        if alvo.head in (:tuple, :parameters)
            foreach(a -> nomes_de!(acc, a), alvo.args)
        elseif alvo.head in (:(::), :kw)
            nomes_de!(acc, alvo.args[1])
        end
    end
    acc
end

"Nomes definidos no nível superior de `ex` (o que o bloco passa adiante)."
function definidos(ex)
    acc = Set{Symbol}()
    ex isa Expr || return acc
    if ex.head === :macrocall                 # `"docstring" f(x) = ...`
        return definidos(last(ex.args))
    elseif ex.head === :const
        return definidos(ex.args[1])
    elseif ex.head === :function
        a = ex.args[1]
        a isa Expr && a.head === :call && a.args[1] isa Symbol && push!(acc, a.args[1])
    elseif ex.head === :(=)
        alvo = ex.args[1]
        if alvo isa Expr && alvo.head === :call        # f(x) = ...
            alvo.args[1] isa Symbol && push!(acc, alvo.args[1])
        else
            nomes_de!(acc, alvo)
        end
    end
    acc
end

"Símbolos usados em `ex`, fora os ligados localmente e os nomes de campo/kwarg."
function usados(ex, ligs::Set{Symbol})
    acc = Set{Symbol}()
    caminha(x) = begin
        if x isa Symbol
            x in ligs || push!(acc, x)
        elseif x isa Expr
            x.head in IGNORA_EXPR && return
            if x.head === :. && length(x.args) == 2      # df.COLUNA → só `df`
                caminha(x.args[1]); return
            elseif x.head === :kw                        # f(; k = v) → só `v`
                caminha(x.args[2]); return
            elseif x.head === :macrocall
                foreach(caminha, x.args[2:end]); return
            end
            foreach(caminha, x.args)
        end
    end
    caminha(ex)
    acc
end

"Conjunto de colunas de `DataFrame(ler(...; colunas = [...]))`, ou nothing."
function colunas_de(ex)
    achou = Ref{Any}(nothing)
    caminha(x) = begin
        x isa Expr || return
        if x.head === :call && x.args[1] === :ler
            achou[] = Set{Symbol}()                      # ler(...) sem `colunas`
            for a in x.args
                if a isa Expr && a.head === :parameters
                    for kw in a.args
                        if kw isa Expr && kw.head === :kw && kw.args[1] === :colunas
                            achou[] = colunas_literais(kw.args[2])
                        end
                    end
                elseif a isa Expr && a.head === :kw && a.args[1] === :colunas
                    achou[] = colunas_literais(a.args[2])
                end
            end
        end
        foreach(caminha, x.args)
    end
    caminha(ex)
    achou[]
end

"`[:A, :B]` → Set([:A, :B]); qualquer coisa não literal → nothing (desiste)."
function colunas_literais(ex)
    ex isa Expr && ex.head === :vect || return nothing
    cols = Set{Symbol}()
    for a in ex.args
        a isa QuoteNode && a.value isa Symbol ? push!(cols, a.value) : return nothing
    end
    cols
end

"Acessos `var.CAMPO` no nível superior de `ex`, ignorando corpos de função."
function acessos(ex)
    out = Tuple{Symbol,Symbol}[]
    caminha(x) = begin
        x isa Expr || return
        x.head === :function && return                   # escopo local: não é o `var` da página
        (x.head === :(=) && x.args[1] isa Expr && x.args[1].head === :call) && return
        if x.head === :. && length(x.args) == 2 && x.args[1] isa Symbol &&
           x.args[2] isa QuoteNode && x.args[2].value isa Symbol
            push!(out, (x.args[1], x.args[2].value))
        end
        foreach(caminha, x.args)
    end
    caminha(ex)
    out
end

"Módulos declarados em `using` nos blocos da página."
function módulos(bs)
    ms = Symbol[]
    for (_, código) in bs, m in eachmatch(r"^\s*using\s+([^\n#]+)", código, )
        for nome in split(m.captures[1], ',')
            nome = strip(nome)
            isempty(nome) || push!(ms, Symbol(nome))
        end
    end
    unique!(ms)
end

"Carrega o que der; devolve (módulos carregados, nomes que faltaram)."
function carrega(ms)
    ok, faltou = Module[], Symbol[]
    for m in ms
        try
            push!(ok, Base.eval(Main, :(import $m; $m)))
        catch
            push!(faltou, m)
        end
    end
    ok, faltou
end

"O nome existe fora da página?"
externo(n, mods) = isdefined(Base, n) || isdefined(Core, n) ||
                   any(m -> isdefined(m, n), mods)

function checa(arquivo)
    md = read(arquivo, String)
    bs = blocos(md)
    problemas = String[]
    pipeline = basename(arquivo) in PIPELINES
    mods, faltaram = pipeline ? carrega(módulos(bs)) : (Module[], Symbol[:guia])
    nomes_de_módulo = Set(Symbol.(string.(nameof.(mods))))

    # ── 1. sintaxe, e o inventário de tudo que a página define ──────────────
    exprs = Tuple{Int,Any}[]                              # (linha, expr)
    todos_defs = Set{Symbol}()
    for (linha0, código) in bs
        ast = Meta.parseall(código)
        for (i, a) in enumerate(ast.args)
            if a isa Expr && a.head === :error
                push!(problemas, "$arquivo:$linha0: bloco não parseia — $(a.args[1])")
                continue
            end
            a isa LineNumberNode && continue
            ln = linha0 + (i ≤ length(ast.args) ? 0 : 0)
            push!(exprs, (linha0, a))
            union!(todos_defs, definidos(a))
        end
    end

    # ── 2 e 2b. uso antes da definição, e nome que ninguém define ───────────
    vistos = Set{Symbol}()
    for (linha, ex) in exprs
        próprios = definidos(ex)          # o nome que a expressão define não
        ligs = ligados!(copy(próprios), ex)  # conta como uso dentro dela mesma
        for u in sort!(collect(usados(ex, ligs)))
            if u in todos_defs
                u in vistos || push!(problemas,
                    "$arquivo:$linha: `$u` é usado aqui, mas a página só o define depois")
            elseif isempty(faltaram) && Base.isidentifier(u) && !(u in (:end, :begin)) &&
                   !(u in nomes_de_módulo) && !externo(u, mods)
                push!(problemas,
                    "$arquivo:$linha: `$u` não é definido nesta página nem vem de " *
                    join(string.(nameof.(mods)), ", "))
            end
        end
        union!(vistos, definidos(ex))
    end
    if pipeline && !isempty(faltaram)
        println("checa_blocos: $arquivo — sem ", join(string.(faltaram), ", "),
                " no ambiente; pulei a checagem de nomes nunca definidos.")
    end

    # ── 3. coluna que o DataFrame não carregou ──────────────────────────────
    colunas = Dict{Symbol,Set{Symbol}}()
    for (linha, ex) in exprs
        for (v, c) in acessos(ex)
            if haskey(colunas, v) && !isempty(colunas[v]) && !(c in colunas[v]) &&
               all(isuppercase, string(c)[1:1])
                push!(problemas,
                      "$arquivo:$linha: `$v.$c` — `$v` foi carregado só com " *
                      string(sort!(collect(colunas[v]))))
            end
        end
        for nome in definidos(ex)
            cols = colunas_de(ex)
            cols === nothing ? delete!(colunas, nome) : (colunas[nome] = cols)
        end
    end
    problemas
end

alvos = isempty(ARGS) ?
    sort!([joinpath(r, f) for (r, _, fs) in walkdir(joinpath(@__DIR__, "src"))
           for f in fs if endswith(f, ".md")]) : ARGS

todos = String[]
for a in alvos
    append!(todos, checa(a))
end

if isempty(todos)
    println("checa_blocos: ", length(alvos), " páginas, nenhum problema.")
else
    for p in todos
        println("checa_blocos: ", p)
    end
    println("\n", length(todos), " problema(s). Os blocos ```julia de uma página ",
            "rodam em ordem e compartilham estado.")
    exit(1)
end

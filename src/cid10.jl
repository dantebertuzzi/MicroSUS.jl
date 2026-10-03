# ─────────────────────────────────────────────────────────────────────
# CID-10: descrições em português, embarcadas (data/cid10.tsv), sem rede.
#
# Fonte: as tabelas do DATASUS/CBCD, versão 2008 — a última publicada em
# CSV. Códigos criados depois pela OMS e adotados no Brasil não estão nela:
# nos 20,6 milhões de óbitos do SIM de 2010–2024 verificados, 7.110 (0,03%)
# têm causa básica fora da tabela. Para 71 desses 82 códigos a categoria
# está na tabela (I48 para I48.9, a fibrilação atrial subdividida em
# 2016), e a descrição sai do nível acima, marcado em `nivel`. A categoria
# A97 (dengue, 2016) — a maior parte do resto — vem num suplemento.
# ─────────────────────────────────────────────────────────────────────

const _Cid = NamedTuple{(:descricao, :sexo, :causa_obito, :origem),
                        Tuple{String,Union{Missing,Char},Bool,String}}

const _CID10 = Ref{Tuple{Dict{String,_Cid},Dict{String,_Cid},Vector{Tuple{String,String,String}}}}()
const _TRAVA_CID10 = ReentrantLock()

function _tabela_cid10()
    isassigned(_CID10) && return _CID10[]
    lock(_TRAVA_CID10) do
        isassigned(_CID10) && return _CID10[]
        sub = Dict{String,_Cid}(); cat = Dict{String,_Cid}()
        grupos = Tuple{String,String,String}[]
        for linha in eachline(joinpath(pkgdir(@__MODULE__), "data", "cid10.tsv"))
            (isempty(linha) || startswith(linha, '#')) && continue
            nivel, cod, fim, desc, sexo, obito, origem = split(linha, '\t')
            if nivel == "G"
                push!(grupos, (String(cod), String(fim), String(desc)))
            else
                reg = _Cid((String(desc), isempty(sexo) ? missing : sexo[1], obito != "N",
                            isempty(origem) ? "DATASUS 2008" : "OMS 2016 (suplemento)"))
                (nivel == "C" ? cat : sub)[String(cod)] = reg
            end
        end
        _CID10[] = (sub, cat, grupos)
    end
end

# "I21.9", " i219 ", "I10X" (o X que completa categorias de três caracteres)
function _chave_cid10(cod)
    c = normaliza_cid(cod)
    length(c) == 4 && c[4] == 'X' && (c = c[1:3])
    return c
end

# memorizado por código: uma coluna de um milhão de causas básicas tem só
# alguns milhares de códigos distintos
const _MEMO_CID10 = Dict{String,Any}()

"""
    cid10(cod) -> Union{NamedTuple,Nothing}

O registro da CID-10 de `cod` (`"I219"`, `"I21.9"`, `"I21"`, `"I10X"`):

- `codigo`, `descricao` — do código pedido ou, se ele não está na tabela,
  da sua categoria;
- `nivel` — `:subcategoria`, `:categoria`, ou `:categoria_da_subcategoria`
  quando o código é posterior à tabela e a descrição veio do nível acima;
- `categoria`, `descricao_categoria`, `grupo` (o agrupamento, como
  "Doenças isquêmicas do coração"), `capitulo` (algarismo romano);
- `sexo` — `'M'`/`'F'` para códigos restritos a um sexo, `missing` se não;
- `causa_basica_valida` — `false` para os 1.291 códigos que a tabela marca
  como não utilizáveis como causa básica de óbito (úteis para medir a
  qualidade da declaração);
- `origem` — `"DATASUS 2008"` ou, para a dengue (A97), o suplemento da OMS
  de 2016.

`nothing` para código vazio ou desconhecido.

```julia
cid10("I21.9").descricao          # "Infarto agudo do miocárdio não especificado"
cid10("I21.9").grupo              # "Doenças isquêmicas do coração"
cid10("R99").causa_basica_valida  # true — mas veja `capitulo`: XVIII, mal definidas
```

A tabela é a última publicada pelo DATASUS em CSV (versão 2008). Códigos
criados depois caem na descrição da categoria; ver [`descricao_cid`](@ref).
"""
function cid10(cod)
    cod === missing && return nothing
    c = _chave_cid10(cod)
    length(c) ≥ 3 || return nothing
    r = lock(_TRAVA_CID10) do
        get(_MEMO_CID10, c, missing)
    end
    r === missing || return r
    r = _cid10(c)
    lock(_TRAVA_CID10) do
        _MEMO_CID10[c] = r
    end
    return r
end

function _cid10(c::String)
    sub, cat, grupos = _tabela_cid10()
    c3 = c[1:3]
    rc = get(cat, c3, nothing)
    reg, nivel = if length(c) == 3
        rc, :categoria
    elseif haskey(sub, c)
        sub[c], :subcategoria
    else
        rc, :categoria_da_subcategoria
    end
    reg === nothing && return nothing
    k = _chave_cid(c3)
    g = findfirst(((ini, fim, _),) -> _chave_cid(ini) ≤ k ≤ _chave_cid(fim), grupos)
    cap = capitulo_cid10(c3)
    return (codigo = c, descricao = reg.descricao, nivel = nivel,
            categoria = c3, descricao_categoria = rc === nothing ? missing : rc.descricao,
            grupo = g === nothing ? missing : grupos[g][3],
            capitulo = cap === nothing ? missing : cap.numeral,
            sexo = reg.sexo, causa_basica_valida = reg.causa_obito, origem = reg.origem)
end

"""
    descricao_cid(cod) -> Union{String,Missing}

A descrição em português de um código da CID-10, para rotular tabelas:
`descricao_cid.(df.CAUSABAS)`. Códigos posteriores à tabela de 2008 do
DATASUS recebem a descrição da categoria (ver [`cid10`](@ref), campo
`nivel`); código vazio ou desconhecido dá `missing`.
"""
function descricao_cid(cod)
    r = cid10(cod)
    return r === nothing ? missing : r.descricao
end

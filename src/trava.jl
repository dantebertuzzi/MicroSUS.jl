# ─────────────────────────────────────────────────────────────────────
# Manifest dos dados: o Manifest.toml fixa o código; isto fixa os dados.
#
# O DATASUS republica bases sem aviso e sem guardar a versão anterior: o
# mesmo script, rodado meses depois, lê outros números. `travar_dados`
# grava de quais arquivos um resultado veio — URL, SHA-256, data da
# extração —, e `restaurar_dados` devolve ao cache exatamente esses bytes,
# do DATASUS ou de um espelho, conferindo cada um pelo hash. Restaurar
# também ativa a trava na sessão: um arquivo travado vem sempre dela, e
# não do FTP (sem isso, o consolidado de 2025 tomaria o lugar do
# preliminar travado assim que saísse).
# ─────────────────────────────────────────────────────────────────────

const _VERSAO_TRAVA = 1

# nome do arquivo → (caminho no cache, sha256), enquanto a trava está ativa
const _TRAVA_ATIVA = Dict{String,Tuple{String,String}}()
const _TRAVA_ATIVA_LOCK = ReentrantLock()

# o arquivo travado que responde por `url`, se a trava estiver ativa. Pelo
# nome: preliminar e consolidado têm o mesmo (DOPE2025.dbc nas duas pastas),
# e é o travado que vale, seja qual for a pasta pedida.
function _resolve_travado(url::AbstractString)
    lock(_TRAVA_ATIVA_LOCK) do
        isempty(_TRAVA_ATIVA) && return nothing
        e = get(_TRAVA_ATIVA, basename(url), nothing)
        e === nothing && return nothing
        caminho, sha = e
        (isfile(caminho) && _sha256(caminho) == sha) || error(
            "o arquivo travado $(basename(url)) não está mais no cache com o " *
            "SHA-256 da trava ($caminho); rode restaurar_dados de novo")
        return caminho
    end
end

_entradas_de(df::AbstractDataFrame) = proveniencia(df)
_entradas_de(v::AbstractVector) = v

"""
    travar_dados(arquivo, resultados...) -> Vector{NamedTuple}

Grava em `arquivo` (TOML) de quais arquivos do DATASUS vieram os
`resultados` — `DataFrame`s de [`fetch_datasus`](@ref), ou o que
[`proveniencia`](@ref) devolve: nome, URL, SHA-256, tamanho, data da
extração, se era preliminar e, se veio de um espelho, de onde. É o
`Manifest.toml` dos dados: versione-o junto com o script.

```julia
df  = fetch_datasus(:SIM_DO; uf = "PE", anos = 2019:2023)
pop = fetch_datasus(:SINASC; uf = "PE", anos = 2019:2023)
travar_dados("dados.toml", df, pop)

# meses depois, ou em outra máquina:
restaurar_dados("dados.toml")
df = fetch_datasus(:SIM_DO; uf = "PE", anos = 2019:2023)   # os mesmos bytes
```

Ver [`restaurar_dados`](@ref).
"""
function travar_dados(arquivo::AbstractString, resultados...)
    isempty(resultados) && throw(ArgumentError("nada a travar: passe os resultados de fetch_datasus"))
    por_nome = Dict{String,Any}()
    for r in resultados, e in _entradas_de(r)
        ant = get(por_nome, e.arquivo, nothing)
        if ant !== nothing && ant.sha256 != e.sha256
            throw(ArgumentError("dois arquivos $(e.arquivo) diferentes nos resultados " *
                                "($(ant.url) e $(e.url)); trave-os em arquivos separados"))
        end
        por_nome[e.arquivo] = e
    end
    entradas = sort!(collect(values(por_nome)); by = e -> e.arquivo)
    doc = Dict{String,Any}(
        "versao_formato" => _VERSAO_TRAVA,
        "arquivo" => [_dict_entrada(e) for e in entradas])
    open(arquivo, "w") do io
        println(io, "# Manifest dos dados — MicroSUS.jl $(pkgversion(@__MODULE__)).")
        println(io, "# Restaure com: using MicroSUS; restaurar_dados(\"$(basename(arquivo))\")")
        TOML.print(io, doc; sorted = true)
    end
    return entradas
end

function _dict_entrada(e)
    d = Dict{String,Any}("nome" => e.arquivo, "url" => e.url, "sha256" => e.sha256,
                         "bytes" => e.bytes, "baixado_em" => e.baixado_em,
                         "preliminar" => e.preliminar)
    o = get(e, :obtido_de, missing)
    o === missing || (d["obtido_de"] = o)
    return d
end

function _le_trava(arquivo::AbstractString)
    doc = TOML.parsefile(arquivo)
    v = get(doc, "versao_formato", nothing)
    v == _VERSAO_TRAVA || throw(ArgumentError(
        "$arquivo não é um manifest de dados do MicroSUS (versao_formato = $v)"))
    return [(nome = String(d["nome"]), url = String(d["url"]), sha256 = String(d["sha256"]),
             bytes = Int(d["bytes"]), baixado_em = DateTime(d["baixado_em"]),
             preliminar = Bool(d["preliminar"]))
            for d in get(doc, "arquivo", Any[])]
end

const _LinhaRestauro = NamedTuple{(:arquivo, :situacao, :origem, :sha256_obtido),
                                  Tuple{String,Symbol,Union{Missing,String},Union{Missing,String}}}

"""
    restaurar_dados(arquivo = "dados.toml"; estrito = true, ativar = true)
        -> Vector{NamedTuple}

Devolve ao cache os arquivos de um manifest de [`travar_dados`](@ref),
conferindo cada um pelo SHA-256, e ativa a trava na sessão. Para cada
arquivo, a `situacao`:

- `:no_cache` — já estava no cache com o mesmo hash; nada foi baixado;
- `:restaurado` — baixado de `origem` (o DATASUS ou um espelho de
  `MICROSUS_ESPELHOS`) com o mesmo hash;
- `:diferente` — o arquivo existe, mas nenhuma origem tem os mesmos bytes:
  o DATASUS o republicou e nenhum espelho guardou a versão travada
  (`sha256_obtido` é o hash do que existe hoje);
- `:indisponivel` — nenhuma origem respondeu com o arquivo.

O DATASUS não guarda versões antigas: a versão travada de um arquivo
republicado só volta de um espelho que a tenha (ver
[`exportar_espelho`](@ref)), ou não volta. Com `estrito = true` (padrão),
qualquer arquivo que não volte com o mesmo hash é erro — a análise não roda
sobre outros dados sem que você decida. Com `estrito = false`, a versão
atual do DATASUS entra no cache no lugar e a lista diz quais mudaram.

Com a trava ativa, um arquivo travado vem sempre do cache — `fetch_datasus`,
`baixar` e `baixar_sinan` não o buscam no FTP, nem trocam o preliminar
travado pelo consolidado — e a [`proveniencia`](@ref) traz a data da
extração original. [`soltar_dados`](@ref) desativa.
"""
function restaurar_dados(arquivo::AbstractString = "dados.toml"; estrito::Bool = true,
                         ativar::Bool = true, verbose::Bool = true)
    entradas = _le_trava(arquivo)
    res = _LinhaRestauro[_restaura_um(e, _origens(e.url); estrito, verbose) for e in entradas]
    falhas = [r for r in res if r.situacao in (:diferente, :indisponivel)]
    if estrito && !isempty(falhas)
        throw(ErrorException(
            "$(length(falhas)) arquivo(s) do manifest não voltaram com o mesmo SHA-256: " *
            join(("$(r.arquivo) ($(r.situacao))" for r in falhas), ", ") *
            ". O DATASUS não guarda versões antigas; um espelho que tenha a versão " *
            "travada resolve (MICROSUS_ESPELHOS). `estrito = false` segue com a versão atual."))
    end
    if ativar
        lock(_TRAVA_ATIVA_LOCK) do
            empty!(_TRAVA_ATIVA)
            for (e, r) in zip(entradas, res)
                r.situacao in (:no_cache, :restaurado) || continue
                _TRAVA_ATIVA[e.nome] = (_destino_cache(e.url), e.sha256)
            end
        end
    end
    if verbose
        n(s) = count(r -> r.situacao === s, res)
        @info "restaurar_dados: $(length(res)) arquivos" no_cache = n(:no_cache) restaurados = n(:restaurado) diferentes = n(:diferente) indisponiveis = n(:indisponivel) trava_ativa = ativar
        isempty(falhas) || @warn "arquivos que não voltaram com o hash travado" falhas
    end
    return res
end

"""
    soltar_dados()

Desativa a trava de [`restaurar_dados`](@ref): os downloads voltam a seguir
o FTP do DATASUS (e o cache) normalmente.
"""
soltar_dados() = (lock(() -> empty!(_TRAVA_ATIVA), _TRAVA_ATIVA_LOCK); nothing)

# Um arquivo do manifest: do cache, se o hash bate; senão, de cada origem
# em ordem, até uma ter os mesmos bytes. Aqui a ausência no DATASUS não
# encerra a busca: um preliminar que ele já trocou pelo consolidado pode
# estar num espelho.
function _restaura_um(e, origens; estrito::Bool, verbose::Bool)
    destino = _destino_cache(e.url)
    linha(s, origem = missing, sha = missing) = _LinhaRestauro((e.nome, s, origem, sha))
    isfile(destino) && _sha256(destino) == e.sha256 && return linha(:no_cache)
    tmp = destino * ".restauro"
    atual = nothing                     # o que o DATASUS tem hoje, se diferente
    try
        for u in origens
            try
                _baixa_retomando!(u, tmp)
            catch err
                err isa Downloads.RequestError || rethrow()
                verbose && @info "restaurar_dados: $(e.nome) indisponível em $u"
                continue
            end
            sha = _sha256(tmp)
            if sha == e.sha256
                mv(tmp, destino; force = true)
                _registra_origem(destino, e.url; baixado_em = e.baixado_em,
                                 obtido_de = u == e.url ? nothing : u)
                return linha(:restaurado, u, sha)
            end
            if u == e.url && atual === nothing
                atual = (sha, tmp * ".atual")
                mv(tmp, atual[2]; force = true)
            end
        end
        atual === nothing && return linha(:indisponivel)
        if !estrito
            mv(atual[2], destino; force = true)
            _registra_origem(destino, e.url)
        end
        return linha(:diferente, e.url, atual[1])
    finally
        rm(tmp; force = true)
        atual === nothing || rm(atual[2]; force = true)
    end
end

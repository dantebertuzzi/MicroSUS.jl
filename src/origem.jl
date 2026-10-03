# ─────────────────────────────────────────────────────────────────────
# Origem dos arquivos do cache e proveniência dos resultados.
#
# O DATASUS republica bases retroativamente, sem aviso: a mesma consulta em
# datas diferentes pode devolver números diferentes. Cada download grava,
# ao lado do arquivo, um registro `.origem` (URL, data, tamanho, SHA-256);
# `verificar_cache` compara o cache com o FTP, e `fetch_datasus` anexa ao
# resultado a lista de arquivos de que ele veio (`proveniencia`).
# ─────────────────────────────────────────────────────────────────────

const _CAMPOS_ORIGEM = (:url, :baixado_em, :bytes, :sha256)

_arquivo_origem(caminho::AbstractString) = caminho * ".origem"

function _sha256(caminho::AbstractString)
    return bytes2hex(open(SHA.sha256, caminho))
end

"""
Grava o registro de origem de `caminho`. `baixado_em` é o momento do
download; para um arquivo antigo do cache, sem registro, é a data de
modificação do arquivo.
"""
function _registra_origem(caminho::AbstractString, url::AbstractString;
                          baixado_em::DateTime = now(UTC))
    reg = (url = String(url), baixado_em = baixado_em,
           bytes = filesize(caminho), sha256 = _sha256(caminho))
    open(_arquivo_origem(caminho), "w") do io
        for k in _CAMPOS_ORIGEM
            println(io, k, '\t', getfield(reg, k))
        end
    end
    return reg
end

function _le_origem(caminho::AbstractString)
    arq = _arquivo_origem(caminho)
    isfile(arq) || return nothing
    d = Dict{String,String}()
    for linha in eachline(arq)
        k, v = split(linha, '\t'; limit = 2)
        d[k] = v
    end
    all(k -> haskey(d, string(k)), _CAMPOS_ORIGEM) || return nothing
    return (url = d["url"], baixado_em = DateTime(d["baixado_em"]),
            bytes = parse(Int, d["bytes"]), sha256 = d["sha256"])
end

_data_arquivo(caminho) = unix2datetime(mtime(caminho))

# o registro, criando-o se o arquivo veio de um cache antigo (sem registro)
function _origem_ou_registra(caminho::AbstractString, url::AbstractString)
    reg = _le_origem(caminho)
    reg !== nothing && reg.bytes == filesize(caminho) && return reg
    return _registra_origem(caminho, url; baixado_em = _data_arquivo(caminho))
end

# ── de qual URL veio um arquivo do cache ─────────────────────────────

# Para um arquivo sem registro de origem, as URLs candidatas são deduzidas
# do nome pelo catálogo de fontes. Devolve (consolidadas, preliminares).
function _urls_candidatas(caminho::AbstractString)
    nome = splitext(basename(caminho))[1]
    vazio = (String[], String[])
    urls, sufixo = if (m = match(r"^([A-Za-z]{3,4})BR(\d{2})$", nome)) !== nothing
        pref = uppercase(m[1])
        j = findfirst(a -> a.prefixo == pref, AGRAVOS_SINAN)
        j === nothing && return vazio
        f = fonte(_fonte_sinan(AGRAVOS_SINAN[j].agravo))
        (f.urls(nothing, 2000 + parse(Int, m[2]), nothing), "")
    elseif (m = match(r"^(DO|DN)([A-Za-z]{2})(\d{4})$"i, nome)) !== nothing
        f = fonte(uppercase(m[1]) == "DO" ? :SIM_DO : :SINASC)
        (f.urls(uppercase(m[2]), parse(Int, m[3]), nothing), "")
    elseif (m = match(r"^(RD|PA|ST|PF)([A-Za-z]{2})(\d{2})(\d{2})([a-z]?)$"i, nome)) !== nothing
        id = Dict("RD" => :SIH_RD, "PA" => :SIA_PA, "ST" => :CNES_ST, "PF" => :CNES_PF)[uppercase(m[1])]
        aa = parse(Int, m[3])
        (fonte(id).urls(uppercase(m[2]), aa ≥ 90 ? 1900 + aa : 2000 + aa, parse(Int, m[4])), m[5])
    else
        return vazio
    end
    urls = [_inserir_sufixo(u, sufixo) for u in urls]
    return (filter(!_eh_url_prelim, urls), filter(_eh_url_prelim, urls))
end

# Tamanho do arquivo no servidor sem baixá-lo (HEAD; no FTP, o tamanho vem
# pelo progresso da libcurl). `nothing` se o arquivo não existe; falha de
# rede vira ErroDeRede.
function _tamanho_remoto(url::AbstractString; tentativas::Int = 3)
    for k in 1:tentativas
        try
            return _tamanho_remoto_uma(url)
        catch e
            (e isa ErroDeRede && k < tentativas) || rethrow()
            # o FTP do DATASUS às vezes trava uma conexão e responde na seguinte
        end
    end
end

function _tamanho_remoto_uma(url::AbstractString)
    total = Ref{Union{Missing,Int}}(missing)
    # com throw = false o Downloads devolve o RequestError em vez de lançá-lo
    r = try
        Downloads.request(url; method = "HEAD", output = devnull, timeout = 20,
                          throw = false, progress = (t, _) -> (t > 0 && (total[] = t)))
    catch e
        e
    end
    if r isa Downloads.RequestError
        _eh_ausente(r) && return nothing
        throw(_erro_de_rede(url, r))
    end
    r isa Exception && throw(r)
    if ismissing(total[]) && startswith(url, "file://")
        local_ = url[8:end]
        return isfile(local_) ? filesize(local_) : nothing
    end
    return total[]
end

# primeira URL da lista que existe no servidor: (url, tamanho) ou nothing
function _primeira_existente(urls)
    for u in urls
        t = _tamanho_remoto(u)
        t === nothing || return (u, t)
    end
    return nothing
end

"""
    verificar_cache(; arquivos = nothing, verbose = true) -> Vector{NamedTuple}

Compara os arquivos do cache com o FTP do DATASUS, sem baixá-los, e diz o
que fazer com cada um. A `situacao` de cada arquivo:

- `:atualizado` — o FTP tem o mesmo arquivo (mesmo tamanho);
- `:mudou` — o DATASUS republicou o arquivo; `baixar(...; forcar = true)`
  ou `fetch_datasus(...; cache = false)` traz a versão nova;
- `:era_preliminar` — o arquivo está no cache como consolidado, mas o
  consolidado não existe no FTP e o preliminar sim: é um preliminar
  guardado por versões até a 0.3.1 do pacote, que o tratavam como
  definitivo. Rebaixe com `forcar = true`;
- `:consolidado_disponivel` — preliminar no cache, e o DATASUS já publicou
  o consolidado; o próximo `fetch_datasus` passa a usá-lo;
- `:ausente_no_ftp` — nenhuma URL candidata existe mais no servidor;
- `:sem_url` — o nome não corresponde a nenhuma fonte do catálogo;
- `:sem_resposta` — o servidor não respondeu (cada consulta é tentada três
  vezes); a verificação desse arquivo fica por fazer.

Colunas: `arquivo`, `situacao`, `bytes_cache`, `bytes_ftp`, `url`,
`baixado_em` (do registro de origem; para arquivos baixados antes desta
versão, a data do arquivo). `arquivos` restringe a verificação (vetor de
nomes ou `Regex`, como `r"^DOPE"`). Consulta dois arquivos por vez
pelo canal de controle do FTP, que responde mesmo onde o firewall bloqueia
as transferências.

A comparação é por tamanho: uma republicação que mantenha exatamente o
mesmo número de bytes passa como `:atualizado`. O FTP do DATASUS não
informa a data de modificação por esta via.

```julia
v = DataFrame(verificar_cache())
filter(r -> r.situacao in (:mudou, :era_preliminar), v)
```
"""
function verificar_cache(; arquivos = nothing, verbose::Bool = true)
    dir = _dir_cache()
    lista = String[]
    for d in (dir, joinpath(dir, "PRELIM"))
        isdir(d) || continue
        for f in readdir(d)
            occursin(r"\.(dbc|dbf)$"i, f) || continue
            arquivos === nothing ||
                (arquivos isa Regex ? occursin(arquivos, f) : f in arquivos) || continue
            push!(lista, joinpath(d, f))
        end
    end
    # duas consultas por vez: com mais, o FTP do DATASUS passa a deixar
    # conexões sem resposta
    res = _LinhaCache[x for x in asyncmap(_verifica_um, lista; ntasks = 2)]
    if verbose
        n(s) = count(r -> r.situacao === s, res)
        @info "verificar_cache: $(length(res)) arquivos" atualizados = n(:atualizado) mudaram = n(:mudou) era_preliminar = n(:era_preliminar) consolidado_disponivel = n(:consolidado_disponivel) ausentes_no_ftp = n(:ausente_no_ftp) sem_url = n(:sem_url) sem_resposta = n(:sem_resposta)
        acao = [r.arquivo for r in res if r.situacao in (:mudou, :era_preliminar)]
        isempty(acao) || @warn "arquivos do cache diferentes do FTP — rebaixe com `forcar = true`" acao
    end
    return res
end

const _LinhaCache = NamedTuple{(:arquivo, :situacao, :bytes_cache, :bytes_ftp, :url, :baixado_em),
                               Tuple{String,Symbol,Int,Union{Missing,Int},Union{Missing,String},DateTime}}

function _verifica_um(caminho::AbstractString)
    try
        return _verifica_um_sem_rede(caminho)
    catch e
        e isa ErroDeRede || rethrow()
        prelim = eh_preliminar(caminho)
        return _LinhaCache(((prelim ? "PRELIM/" : "") * basename(caminho), :sem_resposta,
                            filesize(caminho), missing, e.url, _data_arquivo(caminho)))
    end
end

function _verifica_um_sem_rede(caminho::AbstractString)
    reg = _le_origem(caminho)
    prelim = eh_preliminar(caminho)
    consolidadas, preliminares = _urls_candidatas(caminho)
    base = (arquivo = (prelim ? "PRELIM/" : "") * basename(caminho),
            bytes_cache = filesize(caminho),
            baixado_em = reg === nothing ? _data_arquivo(caminho) : reg.baixado_em)
    linha(s, bytes, url) = _LinhaCache((base.arquivo, s, base.bytes_cache, bytes,
                                        url === missing ? missing : String(url), base.baixado_em))
    if isempty(consolidadas) && isempty(preliminares) && reg === nothing
        return linha(:sem_url, missing, missing)
    end
    if prelim
        # o consolidado saiu? então o preliminar do cache está para ser trocado
        achado = _primeira_existente(consolidadas)
        achado === nothing ||
            return linha(:consolidado_disponivel, achado[2], achado[1])
        urls = reg === nothing ? preliminares : [reg.url]
    else
        urls = reg === nothing ? consolidadas : [reg.url]
    end
    achado = _primeira_existente(urls)
    if achado === nothing
        # consolidado ausente no FTP: se há preliminar, este arquivo era ele
        if !prelim && (p = _primeira_existente(preliminares)) !== nothing
            return linha(:era_preliminar, p[2], p[1])
        end
        return linha(:ausente_no_ftp, missing, isempty(urls) ? missing : first(urls))
    end
    u, t = achado
    s = ismissing(t) ? :atualizado : t == base.bytes_cache ? :atualizado : :mudou
    return linha(s, t, u)
end

# ── proveniência do resultado ────────────────────────────────────────

const _CHAVE_PROVENIENCIA = "MicroSUS.proveniencia"

"""
    proveniencia(df) -> Vector{NamedTuple}

Os arquivos de que um resultado de [`fetch_datasus`](@ref) veio: `arquivo`,
`url`, `baixado_em`, `bytes`, `sha256` e `preliminar`. É o que uma nota de
método precisa para que a análise possa ser refeita sobre os mesmos dados —
o DATASUS republica bases retroativamente, e a URL sozinha não identifica a
versão. Acompanha o `DataFrame` em cópias e recortes (metadado de estilo
`:note`).

```julia
df = fetch_datasus(:SIM_DO; uf = "PE", anos = 2019:2023)
DataFrame(proveniencia(df))
```

Para arquivos baixados antes da 0.4.1, sem registro de origem, `baixado_em`
é a data do arquivo no cache e o SHA-256 é calculado na primeira vez.
"""
function proveniencia(df::AbstractDataFrame)
    _CHAVE_PROVENIENCIA in metadatakeys(df) || throw(ArgumentError(
        "este DataFrame não traz proveniência — ela é anexada por fetch_datasus"))
    return metadata(df, _CHAVE_PROVENIENCIA)
end

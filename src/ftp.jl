# ─────────────────────────────────────────────────────────────────────
# FTP do DATASUS: construção de URLs por sistema/UF/período e download
# com cache local (Scratch.jl). Montar nome de arquivo do DATASUS é
# arqueologia — fica encapsulado aqui.
# ─────────────────────────────────────────────────────────────────────

const _FTP_BASE = "ftp://ftp.datasus.gov.br/dissemin/publicos"

"""
    UFS

Siglas das 27 unidades federativas aceitas por [`url_arquivo`](@ref) e
[`baixar`](@ref).
"""
const UFS = ["AC", "AL", "AP", "AM", "BA", "CE", "DF", "ES", "GO", "MA",
             "MT", "MS", "MG", "PA", "PB", "PR", "PE", "PI", "RJ", "RN",
             "RS", "RO", "RR", "SC", "SP", "SE", "TO"]

_valida_uf(uf) = uppercase(uf) in UFS ? uppercase(uf) :
                 throw(ArgumentError("UF inválida: $uf"))
_aamm(ano, mes) = string(lpad(ano % 100, 2, '0'), lpad(mes, 2, '0'))

"""
    url_arquivo(sistema, uf; ano = nothing, mes = nothing,
                prelim = false) -> String

URL FTP do arquivo `.dbc` no DATASUS. Sistemas anuais (`:sim`,
`:sinasc`) pedem `ano`; mensais (`:sih`, `:sia`, `:cnes`) pedem `ano`
e `mes`. `prelim = true` aponta para a pasta de dados preliminares
(anos ainda não consolidados; só :sim e :sinasc).

Ex.: `url_arquivo(:sim, "PE"; ano = 2023)` →
`.../SIM/CID10/DORES/DOPE2023.dbc`.
"""
function url_arquivo(sistema::Symbol, uf::AbstractString;
                     ano::Union{Nothing,Int} = nothing,
                     mes::Union{Nothing,Int} = nothing,
                     prelim::Bool = false)
    uf = _valida_uf(uf)
    if sistema === :sim
        ano === nothing && throw(ArgumentError(":sim requer ano"))
        pasta = prelim ? "SIM/PRELIM/DORES" : "SIM/CID10/DORES"
        return "$_FTP_BASE/$pasta/DO$uf$ano.dbc"
    elseif sistema === :sinasc
        ano === nothing && throw(ArgumentError(":sinasc requer ano"))
        ano ≥ 1996 || throw(ArgumentError(
            "SINASC via este helper cobre 1996+ (estrutura 1996_/Dados); " *
            "para 1994–1995 monte a URL manualmente em SINASC/1994_1995/"))
        pasta = prelim ? "SINASC/PRELIM/DNRES" : "SINASC/1996_/Dados/DNRES"
        return "$_FTP_BASE/$pasta/DN$uf$ano.dbc"
    elseif sistema === :sih
        (ano === nothing || mes === nothing) &&
            throw(ArgumentError(":sih requer ano e mes"))
        return "$_FTP_BASE/SIHSUS/200801_/Dados/RD$uf$(_aamm(ano, mes)).dbc"
    elseif sistema === :sia
        (ano === nothing || mes === nothing) &&
            throw(ArgumentError(":sia requer ano e mes"))
        return "$_FTP_BASE/SIASUS/200801_/Dados/PA$uf$(_aamm(ano, mes)).dbc"
    elseif sistema === :cnes
        (ano === nothing || mes === nothing) &&
            throw(ArgumentError(":cnes requer ano e mes"))
        return "$_FTP_BASE/CNES/200508_/Dados/ST/ST$uf$(_aamm(ano, mes)).dbc"
    end
    throw(ArgumentError("sistema desconhecido: $sistema " *
                        "(use :sim, :sinasc, :sih, :sia, :cnes)"))
end

# `MICROSUS_CACHE` troca o diretório do cache (outro disco, um cache por
# projeto — e os testes, que não devem escrever no cache de quem os roda)
function _dir_cache()
    d = get(ENV, "MICROSUS_CACHE", "")
    return isempty(d) ? @get_scratch!("dbc") : mkpath(d)
end

# Preliminar e consolidado têm o mesmo nome de arquivo (DOPE2024.dbc nas
# duas pastas). No mesmo lugar do cache, o preliminar baixado uma vez
# passava a ser devolvido para sempre — como se fosse definitivo e mesmo
# depois da consolidação. Por isso o preliminar mora em PRELIM/.
# separador / ou \: o FTP usa /, mas um file:// montado com joinpath no
# Windows usa \ (era o que fazia o teste falhar só lá)
_eh_url_prelim(url::AbstractString) = occursin(r"[/\\]PRELIM[/\\]", url)

function _destino_cache(url::AbstractString)
    _eh_url_prelim(url) || return joinpath(_dir_cache(), basename(url))
    dir = mkpath(joinpath(_dir_cache(), "PRELIM"))
    return joinpath(dir, basename(url))
end

# ── espelhos ─────────────────────────────────────────────────────────
#
# Raízes alternativas com a mesma árvore de pastas do FTP do DATASUS
# (`<espelho>/SIM/CID10/DORES/DOPE2023.dbc`): um bucket, um servidor do
# grupo, uma pasta de rede (`file://`). Separados por `;` em
# MICROSUS_ESPELHOS. Por padrão só entram quando o DATASUS falha por rede;
# com MICROSUS_ESPELHO_PRIMEIRO=true, são tentados antes dele.

function _espelhos()
    v = get(ENV, "MICROSUS_ESPELHOS", "")
    return [String(rstrip(strip(e), '/')) for e in split(v, ';') if !isempty(strip(e))]
end

_espelho_primeiro() =
    lowercase(strip(get(ENV, "MICROSUS_ESPELHO_PRIMEIRO", ""))) in ("1", "true", "sim")

# a mesma URL num espelho; `nothing` para o que não está sob a raiz do FTP
function _url_no_espelho(url::AbstractString, espelho::AbstractString)
    startswith(url, _FTP_BASE * "/") || return nothing
    return espelho * url[ncodeunits(_FTP_BASE)+1:end]
end

# ── download ─────────────────────────────────────────────────────────
#
# Um download por destino de cada vez: com os downloads simultâneos, dois
# pedidos do mesmo arquivo escreviam no mesmo temporário — e no Windows,
# que não apaga arquivo aberto, o rm de um falhava com EBUSY. O segundo
# espera o primeiro.
const _TRAVAS_DESTINO = Dict{String,ReentrantLock}()
const _TRAVA_TRAVAS = ReentrantLock()
_trava_destino(destino) = lock(() -> get!(ReentrantLock, _TRAVAS_DESTINO, destino), _TRAVA_TRAVAS)

# Baixa `url` para o cache. O DATASUS é a autoridade sobre a ausência de
# um arquivo (as partições do SIA e o PRELIM dependem de saber disso): se
# ele diz que não existe, não existe, haja o que houver num espelho. Um
# espelho entra no lugar dele só quando ele não responde — ou antes dele,
# com MICROSUS_ESPELHO_PRIMEIRO. O registro de origem guarda a URL do
# DATASUS (é contra ela que verificar_cache compara) e, se veio de um
# espelho, de onde veio.
_baixa!(url::AbstractString, destino::AbstractString) =
    _baixa_de!(_origens(url), url, destino)

# de onde tentar `url`, em ordem
function _origens(url::AbstractString)
    espelhos = String[u for e in _espelhos()
                      for u in (_url_no_espelho(url, e),) if u !== nothing]
    return _espelho_primeiro() ? [espelhos; String(url)] : [String(url); espelhos]
end

function _baixa_de!(ordem, url::AbstractString, destino::AbstractString)
    lock(_trava_destino(destino)) do
        erro_datasus = nothing
        for u in ordem
            try
                _baixa_retomando!(u, destino)
                u == url || @info "obtido de um espelho" url espelho = u
                _registra_origem(destino, url; obtido_de = u == url ? nothing : u)
                return destino
            catch e
                e isa Downloads.RequestError || rethrow()
                if u == url
                    _eh_ausente(e) && rethrow()
                    erro_datasus = e
                end
                # espelho sem o arquivo ou fora do ar: a próxima origem
            end
        end
        throw(erro_datasus)
    end
end

# ── retomada ─────────────────────────────────────────────────────────
#
# O FTP do DATASUS derruba transferências no meio: em 28/09/2026 um
# arquivo de 8,4 MB parou em 80–90% três vezes seguidas. O download vai
# para `destino.parcial`, com `destino.parcial.info` (URL e tamanho
# esperado) ao lado; uma transferência que cai depois de avançar continua
# de onde parou, e o parcial sobrevive para a próxima chamada. Só vira o
# arquivo definitivo inteiro.
#
# Retomar só em FTP e file://: um servidor HTTP pode ignorar o pedido de
# continuar e devolver o arquivo todo, que seria anexado ao parcial.

const _TENTATIVAS_RETOMADA = 5

_retomavel(url) = startswith(url, "ftp://") || startswith(url, "file://")

function _le_parcial(info::AbstractString)
    isfile(info) || return nothing
    l = split(read(info, String), '\t')
    length(l) == 2 || return nothing
    t = tryparse(Int, strip(l[2]))
    return t === nothing ? nothing : (url = String(l[1]), total = t)
end

# o parcial só serve para a mesma URL e o mesmo arquivo no servidor
function _confere_parcial!(url, parcial, info)
    isfile(parcial) || (rm(info; force = true); return)
    reg = _le_parcial(info)
    descarta = !_retomavel(url) || reg === nothing || reg.url != url ||
               filesize(parcial) > reg.total
    if !descarta
        t = try
            _tamanho_remoto(url)
        catch e
            e isa ErroDeRede || rethrow()
            missing                   # sem resposta: a tentativa dirá
        end
        descarta = t === nothing || (t isa Int && t != reg.total)
    end
    descarta && (rm(parcial; force = true); rm(info; force = true))
    return
end

function _baixa_retomando!(url::AbstractString, destino::AbstractString)
    parcial = destino * ".parcial"
    info = parcial * ".info"
    _confere_parcial!(url, parcial, info)
    for k in 1:_TENTATIVAS_RETOMADA
        antes = isfile(parcial) ? filesize(parcial) : 0
        try
            _baixa_trecho!(url, parcial, info, antes)
            break
        catch e
            if !(e isa Downloads.RequestError) || _eh_ausente(e)
                rm(parcial; force = true); rm(info; force = true)
                rethrow()
            end
            depois = isfile(parcial) ? filesize(parcial) : 0
            (_retomavel(url) && depois > antes && k < _TENTATIVAS_RETOMADA) || rethrow()
            @info "transferência interrompida; retomando" url baixados = depois
        end
    end
    reg = _le_parcial(info)
    if reg !== nothing && filesize(parcial) != reg.total
        rm(parcial; force = true); rm(info; force = true)
        error("download de $url terminou com $(filesize(parcial)) bytes; " *
              "o servidor anunciou $(reg.total)")
    end
    mv(parcial, destino; force = true)
    rm(info; force = true)
    return destino
end

# um trecho: do byte `inicio` até o fim, anexado ao parcial
function _baixa_trecho!(url, parcial, info, inicio::Int)
    _retomavel(url) || (inicio = 0)
    d = Downloads.Downloader()
    inicio > 0 && (d.easy_hook = (easy, _) -> Downloads.Curl.setopt(
        easy, Downloads.Curl.CURLOPT_RESUME_FROM_LARGE, Downloads.Curl.curl_off_t(inicio)))
    anotado = Ref(false)
    progresso = (total, _) -> begin
        # numa retomada a libcurl anuncia só o que falta
        if !anotado[] && total > 0
            write(info, url, '\t', string(inicio + total))
            anotado[] = true
        end
    end
    open(parcial, inicio > 0 ? "a" : "w") do io
        Downloads.download(url, io; downloader = d, progress = progresso)
    end
    return
end

# Arquivo do cache que de fato serve. Um download interrompido por versões
# antigas do pacote podia deixar um .dbc truncado com o nome definitivo, e
# o cache o devolvia para sempre (`DENGBR00.dbc`, cabeçalho truncado, no
# cache de quem escreveu isto). Ler o cabeçalho é barato: se falha, o
# arquivo é descartado e baixado de novo.
function _cache_valido(caminho::AbstractString)
    (isfile(caminho) && filesize(caminho) > 0) || return false
    try
        cabecalho(caminho)
        return true
    catch e
        @warn "arquivo do cache ilegível; será baixado de novo" arquivo = caminho erro = sprint(showerror, e)
        rm(caminho; force = true)
        rm(_arquivo_origem(caminho); force = true)
        return false
    end
end

"""
    eh_preliminar(caminho) -> Bool

`true` se o arquivo veio de uma pasta `PRELIM/` do DATASUS — dado ainda não
consolidado, sujeito a revisão. [`baixar`](@ref), [`baixar_sinan`](@ref) e
[`fetch_datasus`](@ref) guardam esses arquivos em `PRELIM/` dentro do cache,
separados dos consolidados de mesmo nome.

```julia
c = baixar(:sim, "PE"; ano = 2025)
eh_preliminar(c)    # true enquanto o DATASUS não consolidar 2025
```
"""
eh_preliminar(caminho::AbstractString) =
    basename(dirname(abspath(caminho))) == "PRELIM"

# O preliminar também muda: o DATASUS o republica até consolidar. Quem usa
# o do cache precisa saber de quando ele é.
_baixado_em(caminho) = Date(unix2datetime(mtime(caminho)))

"""
    baixar(sistema, uf; ano = nothing, mes = nothing,
           forcar = false, quieto = false) -> String

Baixa (com cache local via Scratch.jl) um arquivo do DATASUS e devolve
o caminho no disco. Chamadas repetidas não rebaixam; `forcar = true`
ignora o cache.

    baixar(sistema, uf; anos, meses = nothing) -> Vector{String}

Forma plural: baixa vários períodos em paralelo (`asyncmap`).
"""
function baixar(sistema::Symbol, uf::AbstractString;
                ano::Union{Nothing,Int} = nothing,
                mes::Union{Nothing,Int} = nothing,
                anos = nothing, meses = nothing,
                forcar::Bool = false, quieto::Bool = false)
    # forma plural
    if anos !== nothing
        pares = meses === nothing ? [(a, nothing) for a in anos] :
                [(a, m) for a in anos for m in meses]
        return asyncmap(pares; ntasks = 4) do (a, m)
            baixar(sistema, uf; ano = a, mes = m, forcar = forcar,
                   quieto = quieto)
        end
    end

    u = url_arquivo(sistema, uf; ano = ano, mes = mes)
    t = _resolve_travado(u)                    # restaurar_dados
    t === nothing || return t
    destino = _destino_cache(u)
    if !forcar && _cache_valido(destino)
        quieto || @info "cache: $destino"
        return destino
    end
    try
        quieto || @info "baixando $u"
        return _baixa!(u, destino)
    catch e
        # consolidado inexistente → tenta a pasta PRELIM (anos recentes do
        # SIM/SINASC ficam lá até a consolidação). O consolidado é sempre
        # tentado antes, mesmo com o preliminar em cache: é assim que a
        # versão definitiva substitui a preliminar quando sai.
        sistema in (:sim, :sinasc) || throw(_erro_de_rede(u, e))
        sem_rede = !_eh_ausente(e)
        up = url_arquivo(sistema, uf; ano = ano, mes = mes, prelim = true)
        dp = _destino_cache(up)
        if !forcar && _cache_valido(dp)
            @warn (sem_rede ? "sem acesso à rede" : "consolidado ainda não publicado") *
                  "; usando dados PRELIMINARES do cache (o DATASUS os atualiza — " *
                  "`forcar = true` rebaixa)" arquivo = dp baixado_em = _baixado_em(dp)
            return dp
        end
        sem_rede && throw(_erro_de_rede(u, e))
        @warn "não achei o consolidado; tentando dados PRELIMINARES" url = up
        try
            return _baixa!(up, dp)
        catch e2
            throw(_eh_ausente(e2) ? e : _erro_de_rede(up, e2))   # ausente: erro da URL principal
        end
    end
end

# ── SINAN (arquivos NACIONAIS por agravo, não por UF) ────────────────

const _FTP_SINAN = "$_FTP_BASE/SINAN/DADOS"

# agravo → prefixo do arquivo nacional (AGRAVOBR{aa}), do catálogo único
# em agravos.jl, mais os nomes alternativos
const _SINAN_AGRAVO = merge(
    Dict(a.agravo => a.prefixo * "BR" for a in AGRAVOS_SINAN),
    Dict(k => only(a.prefixo for a in AGRAVOS_SINAN if a.agravo === v) * "BR"
         for (k, v) in _ALIASES_AGRAVO))

"""
    url_sinan(agravo; ano, prelim = false) -> String

URL FTP do arquivo NACIONAL do SINAN para um agravo. Os arquivos do
SINAN cobrem o Brasil inteiro (`DENGBR20.dbc`), então não há UF — filtre
por residência no [`ler`](@ref) (`SG_UF`/`ID_MN_RESI`). `prelim = true`
aponta para a pasta de dados preliminares.

Agravos: `:dengue`, `:chikungunya`, `:zika`, `:meningite`,
`:tuberculose`, `:hanseniase`, `:sifilis_congenita`, `:violencia`, … —
a lista completa, com o ano inicial de cada um, é [`agravos_sinan`](@ref).

Ex.: `url_sinan(:dengue; ano = 2020)` →
`.../SINAN/DADOS/FINAIS/DENGBR20.dbc`.
"""
function url_sinan(agravo::Symbol; ano::Int, prelim::Bool = false)
    pref = get(_SINAN_AGRAVO, agravo, nothing)
    pref === nothing && throw(ArgumentError(
        "agravo desconhecido: $agravo (veja agravos_sinan())"))
    aa = lpad(ano % 100, 2, '0')
    pasta = prelim ? "PRELIM" : "FINAIS"
    return "$_FTP_SINAN/$pasta/$pref$aa.dbc"
end

"""
    baixar_sinan(agravo; ano, prelim = false, forcar = false,
                 quieto = false) -> String
    baixar_sinan(agravo; anos, kwargs...) -> Vector{String}

Baixa (com cache) o arquivo nacional do SINAN de um agravo. Se
`prelim` não for informado e o arquivo FINAIS não existir, tenta
automaticamente a pasta PRELIM (com aviso). Forma plural baixa vários
anos em paralelo.
"""
function baixar_sinan(agravo::Symbol; ano::Union{Nothing,Int} = nothing,
                      anos = nothing, prelim::Union{Nothing,Bool} = nothing,
                      forcar::Bool = false, quieto::Bool = false)
    if anos !== nothing
        return asyncmap(a -> baixar_sinan(agravo; ano = a, prelim = prelim,
                                          forcar = forcar, quieto = quieto),
                        anos; ntasks = 4)
    end
    ano === nothing && throw(ArgumentError("baixar_sinan requer ano"))

    # tenta FINAIS e cai para PRELIM se prelim===nothing
    tentativas = prelim === nothing ? (false, true) : (prelim,)
    erro = nothing
    for (i, pl) in enumerate(tentativas)
        u = url_sinan(agravo; ano = ano, prelim = pl)
        t = _resolve_travado(u)                # restaurar_dados
        t === nothing || return t
        destino = _destino_cache(u)
        if !forcar && _cache_valido(destino)
            pl && @warn "usando dados PRELIMINARES do cache (o DATASUS os atualiza — " *
                        "`forcar = true` rebaixa)" agravo ano arquivo = destino baixado_em = _baixado_em(destino)
            quieto || @info "cache: $destino"
            return destino
        end
        try
            i > 1 && @warn "FINAIS ausente; tentando PRELIM" agravo ano
            quieto || @info "baixando $u"
            return _baixa!(u, destino)
        catch e
            erro = _erro_de_rede(u, e)
            # sem rede, o PRELIM só serve se já estiver no cache (o laço
            # confere na próxima volta); baixá-lo também falharia
            erro isa ErroDeRede && !pl && prelim === nothing &&
                !isfile(_destino_cache(url_sinan(agravo; ano = ano, prelim = true))) &&
                throw(erro)
        end
    end
    throw(erro)
end

"""
    limpar_cache()

Remove todos os `.dbc` baixados do cache local, inclusive os preliminares
(subpasta `PRELIM/`).
"""
function limpar_cache()
    dir = _dir_cache()
    for f in readdir(dir; join = true)
        rm(f; force = true, recursive = true)
    end
    return dir
end

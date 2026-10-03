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

# baixa para um .part e só então move: download interrompido não deixa
# arquivo truncado com o nome definitivo no cache.
#
# O .part é exclusivo de cada chamada: com os downloads simultâneos, dois
# pedidos do mesmo arquivo escreviam no mesmo .part, e no Windows — que
# não apaga arquivo aberto por outra tarefa — o rm de um falhava com EBUSY
# enquanto o outro o segurava. E uma falha ao limpar nunca esconde o erro
# do download, do qual depende saber se é ausência ou falta de rede.
function _baixa!(url::AbstractString, destino::AbstractString)
    tmp = string(destino, ".", getpid(), "-", rand(UInt32), ".part")
    try
        open(io -> Downloads.download(url, io), tmp, "w")
    catch
        try
            rm(tmp; force = true)
        catch
        end
        rethrow()
    end
    mv(tmp, destino; force = true)
    _registra_origem(destino, url)
    return destino
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

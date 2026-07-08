# ─────────────────────────────────────────────────────────────────────
# FTP do DATASUS: construção de URLs por sistema/UF/período e download
# com cache local (Scratch.jl). Montar nome de arquivo do DATASUS é
# arqueologia — fica encapsulado aqui.
# ─────────────────────────────────────────────────────────────────────

const _FTP_BASE = "ftp://ftp.datasus.gov.br/dissemin/publicos"

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

_dir_cache() = @get_scratch!("dbc")

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
    destino = joinpath(_dir_cache(), basename(u))
    if isfile(destino) && !forcar
        quieto || @info "cache: $destino"
        return destino
    end
    tmp = destino * ".part"
    try
        quieto || @info "baixando $u"
        Downloads.download(u, tmp)
    catch e
        rm(tmp; force = true)
        # arquivo consolidado inexistente (550) → tenta a pasta PRELIM
        # (anos recentes do SIM/SINASC ficam lá até a consolidação)
        if sistema in (:sim, :sinasc)
            up = url_arquivo(sistema, uf; ano = ano, mes = mes,
                             prelim = true)
            @warn "não achei o consolidado; tentando dados PRELIMINARES" url = up
            try
                Downloads.download(up, tmp)
            catch
                rm(tmp; force = true)
                rethrow(e)   # erro original, com a URL principal
            end
        else
            rethrow(e)
        end
    end
    mv(tmp, destino; force = true)
    return destino
end

"""
    limpar_cache()

Remove todos os `.dbc` baixados do cache local.
"""
function limpar_cache()
    dir = _dir_cache()
    for f in readdir(dir; join = true)
        rm(f; force = true)
    end
    return dir
end

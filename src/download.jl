# download.jl — Download dos arquivos do FTP do DATASUS com cache local.
#
# Reaproveita o mesmo cache (_dir_cache(), definido em ftp.jl) usado por
# baixar/url_arquivo — um único diretório de cache para todo o pacote,
# limpo por limpar_cache() (também em ftp.jl).

# Quando a falha quer dizer "o arquivo não existe" — e não "não consegui
# perguntar". Antes, todo RequestError contava como ausência: sem rede, um
# fetch_datasus devolvia um resultado incompleto com só um @warn de
# "arquivos não encontrados". Códigos da libcurl: 78 REMOTE_FILE_NOT_FOUND
# (FTP 550, HTTP sem corpo), 19 FTP_COULDNT_RETR_FILE (libcurl antiga),
# 37 FILE_COULDNT_READ_FILE (file://).
const _CURL_AUSENTE = (78, 19, 37)
const _STATUS_AUSENTE = (404, 410, 550)

_eh_ausente(e) = e isa Downloads.RequestError &&
    (e.code in _CURL_AUSENTE || e.response.status in _STATUS_AUSENTE)

"""
    MicroSUS.ErroDeRede

Falha ao falar com o servidor — timeout, DNS, conexão recusada, canal de
dados do FTP bloqueado —, distinta de "o arquivo não existe". É lançada
em vez de seguir com um resultado incompleto. `causa` é o
`Downloads.RequestError` original.
"""
struct ErroDeRede <: Exception
    url::String
    causa::Downloads.RequestError
end

Base.showerror(io::IO, e::ErroDeRede) = print(io,
    "falha de rede ao baixar ", e.url, ": ", e.causa.message,
    " (código ", e.causa.code, "). Não é ausência do arquivo — seguir daria ",
    "um resultado incompleto. O DATASUS publica só por FTP ",
    "(ftp.datasus.gov.br), que precisa de conexões de dados liberadas.")

_erro_de_rede(url, e) =
    e isa Downloads.RequestError && !_eh_ausente(e) ? ErroDeRede(String(url), e) : e

"""
    baixar_url(url; cache = true, verbose = true) -> Union{String,Nothing}

Baixa `url` para o cache local e devolve o caminho do arquivo, ou `nothing`
se o arquivo não existir no servidor. Erros de rede (timeout, DNS, conexão
recusada) viram [`MicroSUS.ErroDeRede`](@ref); só a ausência do arquivo é
`nothing`, porque a existência de partições (`PA...b.dbc`) e de arquivos
preliminares só pode ser descoberta tentando.
"""
function baixar_url(url::AbstractString; cache::Bool = true, verbose::Bool = true)
    destino = _destino_cache(url)

    if cache && _cache_valido(destino)
        verbose && @info "cache" arquivo = basename(destino)
        return destino
    end

    try
        verbose && @info "baixando" url
        return _baixa!(url, destino)
    catch e
        _eh_ausente(e) && return nothing
        throw(_erro_de_rede(url, e))
    end
end

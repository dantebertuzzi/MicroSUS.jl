# download.jl — Download dos arquivos do FTP do DATASUS com cache local.

const CACHE_DIR = Ref{String}("")

function __init_cache__()
    CACHE_DIR[] = @get_scratch!("datasus_cache")
end

"""
    cache_dir() -> String

Diretório de cache local dos arquivos baixados (gerenciado por Scratch.jl;
removido automaticamente se o pacote for desinstalado).
"""
cache_dir() = CACHE_DIR[]

"""
    limpar_cache()

Remove todos os arquivos `.dbc` do cache local.
"""
function limpar_cache()
    for f in readdir(cache_dir(); join = true)
        rm(f; force = true)
    end
    return nothing
end

"""
    baixar_url(url; cache = true, verbose = true) -> Union{String,Nothing}

Baixa `url` para o cache local e devolve o caminho do arquivo, ou `nothing`
se o arquivo não existir no servidor. Erros de rede genuínos (timeout, DNS)
são propagados; apenas a ausência do arquivo é tratada como `nothing`,
porque a existência de partições (`PA...b.dbc`) e de arquivos preliminares
só pode ser descoberta tentando.
"""
function baixar_url(url::AbstractString; cache::Bool = true, verbose::Bool = true)
    destino = joinpath(cache_dir(), basename(url))

    if cache && isfile(destino) && filesize(destino) > 0
        verbose && @info "cache" arquivo = basename(destino)
        return destino
    end

    tmp = destino * ".part"
    try
        verbose && @info "baixando" url
        Downloads.download(url, tmp)
        mv(tmp, destino; force = true)
        return destino
    catch e
        rm(tmp; force = true)
        if e isa Downloads.RequestError
            # FTP: arquivo inexistente responde com erro de transferência
            # (RETR falhou / 550); HTTP responderia 404.
            return nothing
        end
        rethrow()
    end
end

#!/usr/bin/env julia
#= scripts/testes/verifica_links.jl
Verifica se todos os links (HTTP/HTTPS/FTP) nos arquivos .md da
documentação estão acessíveis. =#
using Downloads: download
using MicroSUS

const DOCS_DIR = joinpath(dirname(@__DIR__), "..", "docs", "src")

function extrai_urls(texto::String)
    urls = String[]
    for m in eachmatch(r"https?://[^\s\)\]\"\']+|ftp://[^\s\)\]\"\']+", texto)
        url = m.match
        url = replace(url, r"[\)\]\"\'\,\.\;]*$" => "")
        url = replace(url, r"`$" => "")
        push!(urls, url)
    end
    return unique(urls)
end

function verifica_url(url::String)
    try
        if startswith(url, "ftp://")
            # Arquivo no FTP do DATASUS: basta saber que existe. Baixá-lo
            # inteiro dependia da velocidade do servidor — em 28/09/2026 o
            # DNBA2022.dbc (8,4 MB) parou em 80–90% nas três tentativas, por
            # tempo, e o job falhou sem link quebrado nenhum. O tamanho vem
            # pelo canal de controle, como em verificar_cache.
            t = MicroSUS._tamanho_remoto(url)
            t === nothing && return (url, false, "arquivo ausente no FTP")
            return (url, true, nothing)
        end
        download(url; timeout=60)   # páginas: pequenas, e nem todo servidor aceita HEAD
        return (url, true, nothing)
    catch e
        return (url, false, sprint(showerror, e))
    end
end

function main()
    @info "Escaneando documentação em: $DOCS_DIR"
    md_files = String[]
    for (root, _, files) in walkdir(DOCS_DIR)
        for f in files
            endswith(f, ".md") && push!(md_files, joinpath(root, f))
        end
    end
    @info "$(length(md_files)) arquivos .md encontrados"

    todas_urls = String[]
    for f in md_files
        texto = read(f, String)
        urls = extrai_urls(texto)
        append!(todas_urls, urls)
    end
    unique!(todas_urls)
    @info "$(length(todas_urls)) URLs únicas encontradas"

    # só verifica URLs externas (não links internos tipo #anchor)
    externas = filter(u -> !startswith(u, "#"), todas_urls)
    @info "Verificando $(length(externas)) URLs externas..."

    problemas = []
    for (i, url) in enumerate(externas)
        status, ok, err = verifica_url(url)
        simbolo = ok ? "✓" : "✗"
        println("[$i/$(length(externas))] $simbolo $url")
        if !ok
            push!(problemas, (url, err))
        end
    end

    if isempty(problemas)
        println("\n✅ Todos os $(length(externas)) links estão acessíveis.")
    else
        println("\n❌ $(length(problemas)) link(s) quebrado(s):")
        for (url, err) in problemas
            println("  $url")
            println("    → $err")
        end
        exit(1)
    end
end

main()
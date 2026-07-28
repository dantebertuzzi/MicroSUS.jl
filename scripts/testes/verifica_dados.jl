#!/usr/bin/env julia
#= scripts/testes/verifica_dados.jl
Compara arquivos baixados pelo MicroSUS.jl com download direto via FTP
público do DATASUS. Verifica se os bytes são idênticos (checksum SHA256).

Uso:
  julia --project=. scripts/testes/verifica_dados.jl
=#
using MicroSUS
using SHA
using Downloads

const TESTES = [
    (sistema = :sim,      uf = "PE", ano = 2023, mes = nothing),
    (sistema = :sinasc,   uf = "PE", ano = 2022, mes = nothing),
    (sistema = :sih,      uf = "PE", ano = 2023, mes = 1),
]

function baixa_direto(url::String, destino::String)
    @info "Baixando direto: $url"
    Downloads.download(url, destino; timeout = 30)
    return destino
end

function sha256_arquivo(caminho::String)
    open(caminho, "r") do io
        bytes2hex(sha256(io))
    end
end

function testa_par(teste::NamedTuple)
    println("\n" * "─"^60)
    sistema = teste.sistema
    uf = get(teste, :uf, nothing)
    ano = teste.ano
    mes = get(teste, :mes, nothing)

    println("Testando: $sistema $uf $ano $(mes !== nothing ? "/$mes" : "")")

    # MicroSUS
    caminho_ms = baixar(sistema, uf; ano = ano, mes = mes)
    hash_ms = sha256_arquivo(caminho_ms)

    # URL direta
    url = url_arquivo(sistema, uf; ano = ano, mes = mes)
    destino = joinpath(tempdir(), basename(url))
    hash_direto = nothing
    try
        baixa_direto(url, destino)
        hash_direto = sha256_arquivo(destino)
        rm(destino; force = true)
    catch e
        @warn "FTP direto falhou (pode ser normal para rede local)" url
        rm(destino; force = true)
        return nothing  # pula este teste
    end

    if hash_direto === nothing
        println("  ⚠ Download direto indisponível, pulando...")
        return nothing
    end

    ok = hash_ms == hash_direto
    if ok
        println("  ✅ SHA256 idêntico: $hash_ms")
    else
        println("  ❌ SHA256 diverge:")
        println("     MicroSUS: $hash_ms")
        println("     Direto:   $hash_direto")
    end
    return ok
end

function main()
    @info "Verificando integridade dos downloads..."
    resultados = []
    for t in TESTES
        r = testa_par(t)
        r === nothing || push!(resultados, r)
    end

    sucessos = count(r -> r, resultados)
    falhas = count(r -> !r, resultados)
    pulados = length(TESTES) - length(resultados)
    println("\n" * "="^60)
    println("Resultado: $sucessos ✓  |  $falhas ✗  |  $pulados pulados  |  $(length(TESTES)) total")
    falhas > 0 && exit(1)
end

main()
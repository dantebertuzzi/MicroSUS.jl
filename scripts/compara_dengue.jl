#!/usr/bin/env julia
using MicroSUS
using DataFrames
using Statistics
using Dates
using Printf

# ============================================================
# Série temporal: Dengue em Petrolina (PE) vs Juazeiro (BA)
# Dados via MicroSUS.jl — SINAN 2019-2020
# ============================================================

const COD_CIDADE1 = "221100"
const COD_CIDADE2 = "211220"
const NOME_CIDADE1 = "Teresina (PI)"
const NOME_CIDADE2 = "Timon (MA)"

# --- Download ---
function baixar_com_retry(agravo, ano; tentativas = 3)
    for i = 1:tentativas
        try
            return baixar_sinan(agravo; ano = ano, forcar = false)
        catch e
            i < tentativas || rethrow(e)
            @warn "Tentativa $i/$tentativas falhou. Retentando em 5s..."
            sleep(5)
        end
    end
end

anos_disponiveis = Int[]
caminhos = Dict{Int,String}()
for ano in [2019, 2020]
    try
        caminhos[ano] = baixar_com_retry(:dengue, ano)
        push!(anos_disponiveis, ano)
    catch e
        @warn "Ano $ano indisponível: $(sprint(showerror, e))"
    end
end
isempty(anos_disponiveis) && error("Nenhum ano disponível.")

# --- Leitura com filtro ---
function ler_municipio(caminho, cod, ano)
    ler(caminho;
        colunas = [:DT_NOTIFIC, :DT_SIN_PRI, :NU_IDADE_N,
                   :CS_SEXO, :CLASSI_FIN, :EVOLUCAO,
                   :SG_UF, :ID_MN_RESI],
        filtro = r -> r[:ID_MN_RESI] == cod,
        tamanho_lote = 50_000)
end

function coletar_municipio(caminhos, cod, rotulo)
    println("Lendo $rotulo ($cod)...")
    partes = DataFrame[]
    for (ano, caminho) in caminhos
        df = DataFrame(ler_municipio(caminho, cod, ano))
        df.Ano .= ano
        push!(partes, df)
    end
    dados = vcat(partes...; cols = :union)
    dados.Municipio .= rotulo
    return dados
end

cidade1 = coletar_municipio(caminhos, COD_CIDADE1, "Teresina")
cidade2 = coletar_municipio(caminhos, COD_CIDADE2, "Timon")
dados = vcat(cidade1, cidade2; cols = :union)

# ============================================================
# SÉRIE TEMPORAL SEMANAL (por data de sintomas)
# ============================================================
dados.Semana_Epi = zeros(Int, nrow(dados))
dados.Ano_Epi     = zeros(Int, nrow(dados))

for i in 1:nrow(dados)
    dt = ismissing(dados.DT_SIN_PRI[i]) ? dados.DT_NOTIFIC[i] : dados.DT_SIN_PRI[i]
    dados.Semana_Epi[i] = week(dt)
    dados.Ano_Epi[i]     = year(dt)
end

semanal = combine(groupby(dados, [:Municipio, :Ano_Epi, :Semana_Epi]),
                  nrow => :Casos)
sort!(semanal, [:Ano_Epi, :Semana_Epi, :Municipio])

# ============================================================
# IMPRESSÃO: TABELA COMPLETA SEMANAL
# ============================================================
println("\n" * "="^80)
println("  SÉRIE TEMPORAL SEMANAL — Dengue: Teresina vs Timon")
println("  Período: $(minimum(anos_disponiveis))–$(maximum(anos_disponiveis))")
println("="^80)

for ano in sort(unique(semanal.Ano_Epi))
    println("\n  ─── $ano ───")
    print("  Semana  ")
    sub_pet = semanal[semanal.Ano_Epi .== ano .&& semanal.Municipio .== "Teresina", :]
    sub_jua = semanal[semanal.Ano_Epi .== ano .&& semanal.Municipio .== "Timon", :]
    semanas = sort(union(sub_pet.Semana_Epi, sub_jua.Semana_Epi))
    println(join(lpad.(semanas, 5), ""))
    for (mun, sub) in [("Teresina", sub_pet), ("Timon", sub_jua)]
        vals = [get(sub.Casos, i, 0) for i in 1:length(semanas)]
        linha = join([@sprintf("%5d", v) for v in vals])
        println("  $(rpad(mun, 9))$linha")
    end
    total_pet = sum(sub_pet.Casos)
    total_jua = sum(sub_jua.Casos)
    print("  Total    ")
    println(join([@sprintf("%5d", t) for t in [total_pet, total_jua]], "           "))
end

# ============================================================
# SÉRIE MENSAL AGREGADA
# ============================================================
println("\n" * "="^80)
println("  SÉRIE TEMPORAL MENSAL")
println("="^80)

meses = ["Jan", "Fev", "Mar", "Abr", "Mai", "Jun",
         "Jul", "Ago", "Set", "Out", "Nov", "Dez"]

dados.Mes = month.(dados.DT_NOTIFIC)
dados.Ano_Not = year.(dados.DT_NOTIFIC)

dados.Mes_Label = [meses[m] for m in dados.Mes]

mensal = combine(groupby(dados, [:Municipio, :Ano_Not, :Mes, :Mes_Label]),
                 nrow => :Casos)
sort!(mensal, [:Ano_Not, :Mes])

max_casos = maximum(mensal.Casos)
for ano in sort(unique(mensal.Ano_Not))
    println("\n  --- $ano ---")
    for mun in ["Teresina", "Timon"]
        sub = mensal[mensal.Ano_Not .== ano .&& mensal.Municipio .== mun, :]
        print("  $(rpad(mun, 13))")
        for row in eachrow(sub)
            bar_len = max(1, row.Casos * 40 ÷ max_casos)
            bar = repeat("█", bar_len)
            print(" $(row.Mes_Label): $bar $(row.Casos)")
        end
        println()
    end
end

# ============================================================
# RESUMO GERAL
# ============================================================
println("\n" * "="^80)
println("  RESUMO DA SÉRIE")
println("="^80)

for mun in ["Teresina", "Timon"]
    sub = dados[dados.Municipio .== mun, :]
    ids = sub.NU_IDADE_N
    ids_val = collect(skipmissing(ids))

    println("\n  $mun -> $(nrow(sub)) casos notificados em $(join(anos_disponiveis, "-"))")
    @printf("    Média semanal:   %.1f casos\n", nrow(sub) / (52 * length(anos_disponiveis)))
    @printf("    Idade média:     %.1f anos\n", mean(ids_val))
    @printf("    Idade mediana:   %.1f anos\n", median(ids_val))

    sub_fem = count(x -> x == "F", sub.CS_SEXO)
    @printf("    %% Feminino:      %.1f%%\n", 100 * sub_fem / nrow(sub))
end

# --- Pico mais intenso ---
println("\n  Semana mais intensa de cada município:")
for mun in ["Teresina", "Timon"]
    sub = semanal[semanal.Municipio .== mun, :]
    idx = argmax(sub.Casos)
    row = sub[idx, :]
    @printf("    %s → semana %d/%d: %d casos\n",
            mun, row.Semana_Epi, row.Ano_Epi, row.Casos)
end

println("\n✅ Série temporal concluída.")
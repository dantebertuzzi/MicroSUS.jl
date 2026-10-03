#!/usr/bin/env julia
# ============================================================================
# Doença de Creutzfeldt-Jakob (DCJ) no Brasil — MicroSUS.jl
#
# Identifica casos nos microdados públicos do DATASUS e os distribui por
# REGIÃO, UNIDADE FEDERATIVA e MUNICÍPIO (de residência), com taxas por
# milhão de habitantes.
#
#   Óbitos      — SIM/DO  : causa básica (CAUSABAS) e, com --mencao, as
#                           linhas da declaração de óbito (causas múltiplas)
#   Internações — SIH/RD  : diagnóstico principal (DIAG_PRINC) e, com
#                           --mencao, o secundário (DIAG_SECUN)   [--sih]
#
# CID-10 usados:
#   A81.0  Doença de Creutzfeldt-Jakob (engloba a variante, vCJD)
#   F02.1  Demência na doença de Creutzfeldt-Jakob
#   --prion acrescenta A81.1 / A81.2 / A81.8 / A81.9 (demais infecções por
#   vírus atípicos do SNC — inclui outras doenças priônicas: GSS, kuru,
#   insônia familiar fatal) para efeito de comparação.
#
# Observações epidemiológicas:
#   * a DCJ é de notificação compulsória, mas o SINAN não publica arquivo
#     nacional do agravo no FTP do DATASUS — SIM e SIH são as fontes de
#     microdados disponíveis;
#   * o SIM conta ÓBITOS e o SIH conta AIHs (internações), não pacientes
#     únicos: um mesmo paciente pode aparecer em várias AIHs;
#   * anos recentes podem vir de bases PRELIM — a coluna PRELIMINAR marca
#     esses registros, e números preliminares merecem asterisco.
#
# Uso:
#   julia --project -t auto scripts/creutzfeldt_jakob.jl
#   julia --project scripts/creutzfeldt_jakob.jl --anos=2015:2023 --ufs=PE,BA
#   julia --project scripts/creutzfeldt_jakob.jl --mencao --prion
#   julia --project scripts/creutzfeldt_jakob.jl --sih --anos=2022:2023 --meses=1:12
#
# Opções:
#   --anos=2010:2023   faixa (a:b) ou lista (a,b,c)          [padrão 2010:2023]
#   --ufs=all|PE,BA    UFs a varrer                          [padrão all]
#   --mencao           também conta menções (causas múltiplas / diag. secundário)
#   --prion            inclui as demais A81.x
#   --sih              acrescenta internações (SIH/RD, mensal — download pesado)
#   --meses=1:12       meses do SIH                          [padrão 1:12]
#   --saida=DIR        diretório de saída       [padrão resultados_creutzfeldt_jakob]
#   --sem-taxas        não consulta a população do IBGE (API SIDRA)
#
# Sem acesso ao FTP do DATASUS, o script para com MicroSUS.ErroDeRede em vez
# de seguir com um resultado incompleto. Com mais de uma thread (-t auto), os
# arquivos são lidos em paralelo.
# ============================================================================

using MicroSUS
using DataFrames
using Dates
using Printf

# ── linha de comando ────────────────────────────────────────────────────────

function opcao(chave::String, padrao::String)
    for a in ARGS
        startswith(a, "--$chave=") && return String(split(a, '='; limit = 2)[2])
    end
    return padrao
end
flag(chave::String) = any(==("--$chave"), ARGS)

function periodo(s::AbstractString)
    s = strip(s)
    if occursin(':', s)
        p = split(s, ':')
        return collect(parse(Int, p[1]):parse(Int, p[2]))
    end
    return [parse(Int, strip(x)) for x in split(s, ',')]
end

const ANOS    = periodo(opcao("anos", "2010:2023"))
const MESES   = periodo(opcao("meses", "1:12"))
const MENCAO  = flag("mencao")
const PRION   = flag("prion")
const COM_SIH = flag("sih")
const TAXAS   = !flag("sem-taxas")
const SAIDA   = opcao("saida", "resultados_creutzfeldt_jakob")

const UFS = let v = opcao("ufs", "all")
    uppercase(v) == "ALL" ? MicroSUS.UFS :
        [uppercase(strip(String(x))) for x in split(v, ',')]
end

# ── CID-10 ──────────────────────────────────────────────────────────────────

const CID_DCJ   = ["A810", "F021"]
const CID_PRION = ["A811", "A812", "A818", "A819"]
const ALVOS     = PRION ? vcat(CID_DCJ, CID_PRION) : CID_DCJ

const ROTULO_CID = Dict(
    "A810" => "A81.0 Doença de Creutzfeldt-Jakob",
    "F021" => "F02.1 Demência na doença de Creutzfeldt-Jakob",
    "A811" => "A81.1 Panencefalite esclerosante subaguda",
    "A812" => "A81.2 Leucoencefalopatia multifocal progressiva",
    "A818" => "A81.8 Outras infecções por vírus atípicos do SNC",
    "A819" => "A81.9 Infecção por vírus atípico do SNC, não especificada",
)

# ── coleta ──────────────────────────────────────────────────────────────────
#
# Uma chamada a fetch_datasus por fonte: baixa (com cache), lê em streaming
# só as colunas pedidas e aplica o filtro dentro do leitor. Colunas que não
# existem em algum ano (as linhas da DO, por exemplo) vêm missing nele.

const COLS_SIM  = [:DTOBITO, :CAUSABAS, :CODMUNRES, :CODMUNOCOR,
                   :IDADE, :SEXO, :RACACOR, :LOCOCOR]
const LINHAS_DO = [:LINHAA, :LINHAB, :LINHAC, :LINHAD, :LINHAII, :CAUSABAS_O]

const COLS_SIH  = [:DT_INTER, :DT_SAIDA, :DIAG_PRINC, :DIAG_SECUN, :MUNIC_RES,
                   :MUNIC_MOV, :IDADE, :COD_IDADE, :SEXO, :MORTE, :DIAS_PERM]

# o CID-alvo que o campo traz como código único (causa básica, diagnóstico)
alvo_principal(cid) = (j = findfirst(a -> cid_casa(cid, a), ALVOS);
                       j === nothing ? nothing : ALVOS[j])
# o CID-alvo mencionado num campo com vários códigos (linhas da DO)
alvo_mencionado(txt) = (j = findfirst(a -> menciona_cid(txt, a), ALVOS);
                        j === nothing ? nothing : ALVOS[j])

"""
CRITERIO ("principal" ou "menção") e CID_ALVO de cada registro: a DCJ
costuma ser causa consequencial, então com --mencao o alvo pode estar numa
linha da DO / no diagnóstico secundário enquanto a causa básica é outra.
"""
function classifica!(df::DataFrame, col_principal::Symbol, campos_mencao, mencao_unica::Bool)
    criterio = Vector{String}(undef, nrow(df))
    alvo = Vector{String}(undef, nrow(df))
    for i in 1:nrow(df)
        a = alvo_principal(df[i, col_principal])
        if a !== nothing
            criterio[i], alvo[i] = "principal", a
            continue
        end
        criterio[i], alvo[i] = "menção", "?"
        for c in campos_mencao
            v = df[i, c]
            v === missing && continue
            m = mencao_unica ? alvo_principal(v) : alvo_mencionado(v)
            m === nothing && continue
            alvo[i] = m
            break
        end
    end
    df[!, :CRITERIO] = criterio
    df[!, :CID_ALVO] = alvo
    return df
end

function coleta_sim()
    extras = MENCAO ? LINHAS_DO : Symbol[]
    filtro = r -> cid_casa(r[:CAUSABAS], ALVOS) ||
                  any(c -> haskey(r, c) && menciona_cid(r[c], ALVOS), extras)
    df = fetch_datasus(:SIM_DO; uf = UFS, anos = ANOS, colunas = [COLS_SIM; extras],
                       filtro, processar = false, verbose = false)
    df[!, :FONTE] .= "SIM"
    df[!, :ANO] = [d isa Date ? year(d) : a for (d, a) in zip(df.DTOBITO, df.ANO_ARQUIVO)]
    df[!, :DATA] = df.DTOBITO
    df[!, :CID] = normaliza_cid.(df.CAUSABAS)
    classifica!(df, :CID, extras, false)
    df[!, :COD_MUN] = String.(strip.(String.(coalesce.(df.CODMUNRES, ""))))
    return df
end

function coleta_sih()
    secun = MENCAO ? [:DIAG_SECUN] : Symbol[]
    filtro = r -> cid_casa(r[:DIAG_PRINC], ALVOS) ||
                  any(c -> haskey(r, c) && cid_casa(r[c], ALVOS), secun)
    df = fetch_datasus(:SIH_RD; uf = UFS, anos = ANOS, meses = MESES, colunas = COLS_SIH,
                       filtro, processar = false, verbose = false)
    df[!, :FONTE] .= "SIH"
    df[!, :ANO] = df.ANO_ARQUIVO
    df[!, :DATA] = df.DT_INTER
    df[!, :CID] = normaliza_cid.(df.DIAG_PRINC)
    classifica!(df, :CID, secun, true)
    df[!, :COD_MUN] = String.(strip.(String.(coalesce.(df.MUNIC_RES, ""))))
    return df
end

# ── geografia (tabela do IBGE embarcada no pacote, sem rede) ────────────────

function geografia!(casos::DataFrame)
    casos[!, :UF] = [coalesce(uf_de(c), u) for (c, u) in zip(casos.COD_MUN, casos.UF_ARQUIVO)]
    casos[!, :REGIAO] = [coalesce(regiao(u), "Não identificada") for u in casos.UF]
    casos[!, :MUNICIPIO] = map(casos.COD_MUN) do c
        m = municipio(c)
        string(m === nothing ? c : m.nome, " (", coalesce(uf_de(c), "??"), ")")
    end
    return casos
end

# ── CSV sem dependências ────────────────────────────────────────────────────

function celula(v)
    v === missing && return ""
    s = string(v)
    return any(c -> c in (',', '"', '\n'), s) ? '"' * replace(s, '"' => "\"\"") * '"' : s
end

function escreve_csv(caminho::AbstractString, df::AbstractDataFrame)
    open(caminho, "w") do io
        println(io, join(string.(names(df)), ','))
        for r in eachrow(df)
            println(io, join((celula(r[c]) for c in names(df)), ','))
        end
    end
    @printf("  %-42s %6d linhas\n", basename(caminho), nrow(df))
end

# ── agregações ──────────────────────────────────────────────────────────────

conta(df, chaves) = sort!(combine(groupby(df, chaves), nrow => :CASOS),
                          [order(:CASOS, rev = true); chaves])

function percentual!(df)
    total = sum(df.CASOS)
    df[!, :PCT] = total == 0 ? zeros(nrow(df)) :
                  round.(100 .* df.CASOS ./ total; digits = 2)
    return df
end

barra(n, maxn; largura = 28) =
    maxn == 0 ? "" : "█"^max(1, round(Int, largura * n / maxn))

function imprime(titulo, df, chave; limite = 100)
    println("\n", titulo)
    println(repeat("─", length(titulo)))
    isempty(df) && (println("  (sem casos)"); return)
    maxn = maximum(df.CASOS)
    for (i, r) in enumerate(eachrow(df))
        i > limite && (println(@sprintf("  … +%d linhas (ver CSV)",
                                        nrow(df) - limite)); break)
        @printf("  %-38s %6d  %5.1f%%  %s\n",
                r[chave], r.CASOS, r.PCT, barra(r.CASOS, maxn))
    end
    @printf("  %-38s %6d\n", "TOTAL", sum(df.CASOS))
end

# ── taxas por milhão de habitantes ──────────────────────────────────────────
#
# Óbitos do SIM sobre pessoas-ano (soma das populações dos anos do recorte).
# A população vem de fontes diferentes conforme o ano (Censo, Contagem,
# estimativa); 2023, sem publicação do IBGE, é interpolado. Ver `populacao`.

function taxas_uf(sim::DataFrame)
    pop = DataFrame(populacao(ANOS; nivel = :uf, interpolar = true))
    pop[!, :UF] = [uf_de(c) for c in pop.codigo_uf]
    filter!(:UF => in(UFS), pop)
    pa = combine(groupby(pop, :UF), :populacao => sum => :PESSOAS_ANO)
    t = leftjoin(pa, combine(groupby(sim, :UF), nrow => :OBITOS); on = :UF)
    t.OBITOS = coalesce.(t.OBITOS, 0)
    t[!, :REGIAO] = regiao.(t.UF)
    t[!, :POR_MILHAO_ANO] = round.(1e6 .* t.OBITOS ./ t.PESSOAS_ANO; digits = 2)
    return sort!(t, :POR_MILHAO_ANO; rev = true)
end

function taxas_regiao(tuf::DataFrame)
    t = combine(groupby(tuf, :REGIAO), :OBITOS => sum => :OBITOS,
                :PESSOAS_ANO => sum => :PESSOAS_ANO)
    t[!, :POR_MILHAO_ANO] = round.(1e6 .* t.OBITOS ./ t.PESSOAS_ANO; digits = 2)
    return sort!(t, :POR_MILHAO_ANO; rev = true)
end

# ── execução ────────────────────────────────────────────────────────────────

function main()
    println(repeat("=", 78))
    println("Doença de Creutzfeldt-Jakob no Brasil — microdados DATASUS (MicroSUS.jl)")
    println(repeat("=", 78))
    println("CID-10 alvo : ", join((get(ROTULO_CID, c, c) for c in ALVOS), "\n              "))
    println("Anos        : ", first(ANOS), "–", last(ANOS), "  (", length(ANOS), " anos)")
    println("UFs         : ", length(UFS) == 27 ? "todas (27)" : join(UFS, ", "))
    println("Critério    : ", MENCAO ?
            "causa básica + menção nas causas múltiplas / diag. secundário" :
            "causa básica (SIM) / diagnóstico principal (SIH)")
    println("Fontes      : SIM/DO", COM_SIH ? " + SIH/RD" : "")
    println("Threads     : ", Threads.nthreads(), Threads.nthreads() == 1 ? "  (use -t auto para ler em paralelo)" : "")
    println()

    partes = [coleta_sim()]
    @printf("SIM: %d registro(s)\n", nrow(partes[1]))
    if COM_SIH
        println("SIH/RD — arquivos mensais (download volumoso)…")
        push!(partes, coleta_sih())
        @printf("SIH: %d registro(s)\n", nrow(partes[2]))
    end

    casos = vcat(partes...; cols = :union)
    if nrow(casos) == 0
        println("\nNenhum caso encontrado no recorte solicitado.")
        return
    end

    geografia!(casos)
    casos[!, :CID_ROTULO] = [get(ROTULO_CID, c, c) for c in casos.CID_ALVO]
    casos[!, :CRITERIO] = [c == "principal" ?
        "causa básica / diagnóstico principal" :
        "menção (causa múltipla / diag. secundário)" for c in casos.CRITERIO]

    mkpath(SAIDA)

    por_regiao = percentual!(conta(casos, [:REGIAO]))
    por_uf     = percentual!(conta(casos, [:UF]))
    por_mun    = percentual!(conta(casos, [:MUNICIPIO]))
    por_ano    = percentual!(sort!(conta(casos, [:ANO]), :ANO))
    por_cid    = percentual!(conta(casos, [:CID_ROTULO]))
    por_criterio = percentual!(conta(casos, [:CRITERIO]))
    regiao_ano = sort!(conta(casos, [:REGIAO, :ANO]), [:REGIAO, :ANO])
    uf_ano     = sort!(conta(casos, [:UF, :ANO]), [:UF, :ANO])
    por_fonte  = percentual!(conta(casos, [:FONTE]))

    println("\n", repeat("=", 78))
    @printf("TOTAL DE REGISTROS IDENTIFICADOS: %d\n", nrow(casos))
    n_prelim = count(coalesce.(casos.PRELIMINAR, false))
    n_prelim > 0 && @printf("  dos quais %d de bases PRELIMINARES (coluna PRELIMINAR)\n", n_prelim)
    println(repeat("=", 78))

    imprime("Por fonte", por_fonte, :FONTE)
    imprime("Por CID-10 identificado", por_cid, :CID_ROTULO)
    MENCAO && imprime("Por critério de captura", por_criterio, :CRITERIO)
    imprime("Por região (residência)", por_regiao, :REGIAO)
    imprime("Por unidade federativa (residência)", por_uf, :UF)
    imprime("Por município de residência — 30 maiores", por_mun, :MUNICIPIO; limite = 30)

    println("\nSérie anual")
    println(repeat("─", 11))
    maxn = maximum(por_ano.CASOS)
    for r in eachrow(por_ano)
        @printf("  %-6d %6d  %s\n", r.ANO, r.CASOS, barra(r.CASOS, maxn; largura = 40))
    end

    # perfil demográfico (SIM)
    sim = filter(:FONTE => ==("SIM"), casos)
    if !isempty(sim) && hasproperty(sim, :IDADE)
        idades = collect(skipmissing(sim.IDADE))
        if !isempty(idades)
            @printf("\nIdade ao óbito (SIM): média %.1f anos | mediana %.1f | %d–%d anos\n",
                    sum(idades) / length(idades),
                    sort(idades)[cld(length(idades), 2)],
                    floor(Int, minimum(idades)), ceil(Int, maximum(idades)))
        end
    end
    if !isempty(sim) && hasproperty(sim, :SEXO)
        sexo = percentual!(conta(sim, [:SEXO]))
        println("\nSexo (SIM; 1/M = masculino, 2/F = feminino):")
        for r in eachrow(sexo)
            @printf("  %-6s %6d  %5.1f%%\n", r.SEXO, r.CASOS, r.PCT)
        end
    end

    tuf = treg = nothing
    if TAXAS && !isempty(sim)
        tuf = try
            taxas_uf(sim)
        catch e
            println("\nTaxas não calculadas — a população vem da API SIDRA do IBGE: ",
                    sprint(showerror, e), "\n(use --sem-taxas para não tentar)")
            nothing
        end
        if tuf !== nothing
            treg = taxas_regiao(tuf)
            println("\nÓbitos (SIM) por milhão de habitantes-ano, ", first(ANOS), "–", last(ANOS))
            println(repeat("─", 50))
            for r in eachrow(treg)
                @printf("  %-14s %5d óbitos  %6.2f /milhão/ano\n", r.REGIAO, r.OBITOS, r.POR_MILHAO_ANO)
            end
            println("  (população: Censo, Contagem ou estimativa conforme o ano; 2023 interpolado)")
        end
    end

    println("\nArquivos gerados em $SAIDA/")
    escreve_csv(joinpath(SAIDA, "casos_registros.csv"), casos)
    escreve_csv(joinpath(SAIDA, "por_regiao.csv"), por_regiao)
    escreve_csv(joinpath(SAIDA, "por_uf.csv"), por_uf)
    escreve_csv(joinpath(SAIDA, "por_municipio.csv"), por_mun)
    escreve_csv(joinpath(SAIDA, "por_ano.csv"), por_ano)
    escreve_csv(joinpath(SAIDA, "por_cid.csv"), por_cid)
    escreve_csv(joinpath(SAIDA, "por_criterio.csv"), por_criterio)
    escreve_csv(joinpath(SAIDA, "regiao_ano.csv"), regiao_ano)
    escreve_csv(joinpath(SAIDA, "uf_ano.csv"), uf_ano)
    tuf === nothing || escreve_csv(joinpath(SAIDA, "taxas_uf.csv"), tuf)
    treg === nothing || escreve_csv(joinpath(SAIDA, "taxas_regiao.csv"), treg)

    println("""

    Notas de interpretação
    ──────────────────────
    • SIM conta óbitos; SIH conta AIHs (internações), não pacientes únicos.
    • Distribuição por município/UF/região usa a RESIDÊNCIA (CODMUNRES /
      MUNIC_RES); CODMUNOCOR e MUNIC_MOV, no CSV de registros, trazem o local
      de ocorrência/atendimento — a DCJ costuma ser diagnosticada em centros
      de referência, o que desloca a ocorrência para as capitais.
    • As taxas usam a população do IBGE de cada ano, que vem de fontes
      diferentes (Censo, Contagem, estimativa) e não forma série homogênea.
    • Doença rara (incidência ~1–2 casos por milhão/ano) e sub-registrada:
      números pequenos por município são esperados e instáveis.""")
end

main()

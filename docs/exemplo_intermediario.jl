#!/usr/bin/env julia
# ============================================================================
# exemplo_intermediario.jl — pipeline completo da página "Exemplos
# intermediários" da documentação do MicroSUS.jl.
#
# Internações por infarto agudo do miocárdio (CID-10 I21) no Nordeste, 2022:
# carga multi-UF, recorte por diagnóstico, join com o IBGE, cruzamento com o
# SIM, taxas padronizadas por idade e diagnóstico do atraso de digitação.
#
#   julia --project=docs docs/exemplo_intermediario.jl
#
# Custo: ~250 MB de download (108 arquivos do SIH + 9 do SIM), ~2 min na
# primeira execução. O cache do Scratch.jl torna as seguintes quase imediatas.
# ============================================================================

using MicroSUS, DataFrames, Dates, Statistics, Tables, HTTP, JSON3, Printf

const NE = ["AL","BA","CE","MA","PB","PE","PI","RN","SE"]
const ANO = 2022
const CAMPOS_DIAG = [:DIAG_PRINC, :DIAG_SECUN, (Symbol("DIAGSEC$i") for i in 1:9)...]
const COLS = [CAMPOS_DIAG..., :PROC_REA, :MUNIC_RES, :IDADE, :COD_IDADE, :SEXO,
              :MORTE, :DT_INTER, :ANO_CMPT, :MES_CMPT, :DIAS_PERM, :VAL_TOT]
const FAIXAS = ["0 a 4","5 a 9","10 a 14","15 a 19","20 a 24","25 a 29","30 a 34",
  "35 a 39","40 a 44","45 a 49","50 a 54","55 a 59","60 a 64","65 a 69","70 a 74",
  "75 a 79","80+"]

println("extração: ", today(), "  ·  MicroSUS.jl v", pkgversion(MicroSUS))

# ── 1. layout muda entre anos ────────────────────────────────────────────────
println("\n── 1. layout do SIH ao longo do tempo ──")
for ano in (2010, 2011, 2013, 2014, 2022)
    c = baixar(:sih, "PE"; anos = [ano], meses = [6], quieto = true)[1]
    campos = Set(Symbol(x.nome) for x in cabecalho(c).campos)
    println("  ", ano, ": ", lpad(length(campos), 3), " campos   DIAGSEC1? ",
            :DIAGSEC1 in campos)
end

# ── 2. carga com filtro no leitor ────────────────────────────────────────────
diag_presentes(caminho) = filter(∈(keys(cabecalho(caminho).indice)), CAMPOS_DIAG)

function carregar_iam(ufs, ano, meses)
    partes = DataFrame[]; lidas = 0
    for uf in ufs, c in baixar(:sih, uf; anos = [ano], meses = meses, quieto = true)
        lidas += cabecalho(c).n_registros
        campos = diag_presentes(c)
        df = DataFrame(ler(c; colunas = COLS, ignorar_ausentes = true,
                filtro = r -> any(startswith(r[k], "I21") for k in campos)))
        df.UF = fill(uf, nrow(df))
        push!(partes, df)
    end
    vcat(partes...; cols = :union), lidas
end

println("\n── 2. carga (pode levar ~1 min na primeira vez) ──")
t0 = time(); iam, lidas = carregar_iam(NE, ANO, 1:12)
@printf("  %d internações varridas → %d com I21 em alguma posição (%.1f s)\n",
        lidas, nrow(iam), time() - t0)

iam_p = iam[startswith.(coalesce.(String.(iam.DIAG_PRINC), ""), "I21"), :]
@printf("  só diagnóstico principal: %d   (secundário acrescenta %.1f%%)\n",
        nrow(iam_p), 100 * (nrow(iam) - nrow(iam_p)) / nrow(iam_p))
println("  DIAG_SECUN — valores distintos: ", unique(String.(iam.DIAG_SECUN)))

# MORTE vem como texto "0"/"1": o schema do SIH não o tipa
# MORTE, COD_IDADE, ANO_CMPT e MES_CMPT vêm tipados desde a v0.3.0
iam_p.morte = iam_p.MORTE
@printf("  letalidade hospitalar: %.1f%%\n", 100mean(iam_p.morte))

# ── 3. join com o IBGE ───────────────────────────────────────────────────────
println("\n── 3. join com a tabela de municípios do IBGE ──")
j = JSON3.read(String(HTTP.get(
    "https://servicodados.ibge.gov.br/api/v1/localidades/municipios").body))
function uf_de(m)
    mr = get(m, :microrregiao, nothing)
    mr !== nothing && return (String(mr.mesorregiao.UF.sigla),
                              String(mr.mesorregiao.UF.regiao.nome))
    ri = get(m, Symbol("regiao-imediata"), nothing)
    ri !== nothing && return (String(ri[Symbol("regiao-intermediaria")].UF.sigla),
                              String(ri[Symbol("regiao-intermediaria")].UF.regiao.nome))
    (missing, missing)
end
ufs_ibge = uf_de.(j)
mun = DataFrame(cod7 = [m.id for m in j], municipio = [String(m.nome) for m in j],
                uf_sigla = first.(ufs_ibge), regiao = last.(ufs_ibge))

codigos = String.(iam_p.MUNIC_RES)
ruins = Set(filter(c -> length(c) != 6 || !all(isdigit, c) || c[3:6] == "9999",
                   unique(codigos)))
@printf("  códigos inválidos ou 'ignorado': %d de %d distintos\n",
        length(ruins), length(unique(codigos)))
ok = iam_p[.!in.(codigos, Ref(ruins)), :]
ok.cod7 = codigo7_ibge.(String.(ok.MUNIC_RES))
com_nome = leftjoin(ok, mun, on = :cod7, makeunique = true)
@printf("  órfãos após o join: %d (%.3f%%)\n",
        count(ismissing, com_nome.municipio),
        100count(ismissing, com_nome.municipio) / nrow(com_nome))
ingenuo = count(∈(Set(mun.cod7)), parse.(Int, String.(ok.MUNIC_RES)) .* 10)
@printf("  se usasse cod6*10: casariam %d de %d (%.1f%%)\n",
        ingenuo, nrow(ok), 100ingenuo / nrow(ok))

# ── 4. cruzamento com o SIM ──────────────────────────────────────────────────
println("\n── 4. óbitos por IAM no SIM ──")
function obitos_iam(ufs, ano)
    total = 0
    for uf in ufs
        c = baixar(:sim, uf; ano = ano, quieto = true)
        for lote in Tables.partitions(ler(c; colunas = [:CAUSABAS],
                        filtro = r -> startswith(r[:CAUSABAS], "I21")))
            total += Tables.rowcount(lote)
        end
    end
    total
end
obitos = obitos_iam(NE, ANO)
@printf("  SIM: %d óbitos   ·   SIH: %d óbitos hospitalares   ·   razão %.2f\n",
        obitos, sum(iam_p.morte), obitos / sum(iam_p.morte))

# ── 5. taxas padronizadas ────────────────────────────────────────────────────
println("\n── 5. taxas por 100 mil, brutas e padronizadas ──")
const FAIXAS_SIDRA = ["93070","93084","93085","93086","93087","93088","93089",
  "93090","93091","93092","93093","93094","93095","93096","93097","93098",
  "49108","49109","60040","60041","6653"]
const UF_COD = Dict("11"=>"RO","12"=>"AC","13"=>"AM","14"=>"RR","15"=>"PA",
  "16"=>"AP","17"=>"TO","21"=>"MA","22"=>"PI","23"=>"CE","24"=>"RN","25"=>"PB",
  "26"=>"PE","27"=>"AL","28"=>"SE","29"=>"BA","31"=>"MG","32"=>"ES","33"=>"RJ",
  "35"=>"SP","41"=>"PR","42"=>"SC","43"=>"RS","50"=>"MS","51"=>"MT","52"=>"GO",
  "53"=>"DF")
url = "https://apisidra.ibge.gov.br/values/t/9514/n3/all/v/93/p/2022/c2/6794" *
      "/c287/" * join(FAIXAS_SIDRA, ",") * "/c286/113635"
linhas = JSON3.read(String(HTTP.get(url).body))[2:end]
bruto = DataFrame(uf = [UF_COD[String(r["D1C"])] for r in linhas],
                  idade = [String(r["D5N"]) for r in linhas],
                  n = [parse(Int, String(r["V"])) for r in linhas])
@assert sum(bruto.n) == 203_080_756 "denominador não fecha com o Censo 2022"
const TOPO = ["80 a 84 anos","85 a 89 anos","90 a 94 anos","95 a 99 anos",
              "100 anos ou mais"]
bruto.faixa = [i in TOPO ? "80+" : replace(i, " anos" => "") for i in bruto.idade]
pop = combine(groupby(bruto, [:uf, :faixa]), :n => sum => :pop)
println("  população conferida contra o Censo 2022: ", sum(pop.pop))

faixa_de(a) = ismissing(a) ? missing : (a ≥ 80 ? "80+" : FAIXAS[div(a,5)+1])
iam_p.faixa = faixa_de.(idade_sih.(iam_p.IDADE, iam_p.COD_IDADE))
casos = combine(groupby(dropmissing(iam_p, :faixa), [:UF, :faixa]), nrow => :casos)

# a direção do join manda: partir da população mantém as faixas sem casos
base = leftjoin(filter(:uf => ∈(NE), pop), casos, on = [:uf => :UF, :faixa => :faixa])
rename!(base, :uf => :UF); base.casos = coalesce.(base.casos, 0)
@assert nrow(base) == length(NE) * length(FAIXAS) "grade UF×faixa incompleta"

const OMS = Dict(zip(FAIXAS, [8860,8690,8600,8470,8220,7930,7610,7150,6590,
                              6040,5370,4550,3720,2960,2210,1520,1545]))
const W = Dict(k => v / sum(values(OMS)) for (k, v) in OMS)
base.taxa_esp = 1e5 .* base.casos ./ base.pop
base.peso = [W[f] for f in base.faixa]
res = sort(combine(groupby(base, :UF)) do g
    (; casos = sum(g.casos), pop = sum(g.pop),
       bruta = 1e5 * sum(g.casos) / sum(g.pop),
       padronizada = sum(g.taxa_esp .* g.peso))
end, :padronizada, rev = true)
show(res, allrows = true, allcols = true); println()
@printf("  Nordeste — taxa bruta %.1f / 100 mil (pop %d)\n",
        1e5 * sum(res.casos) / sum(res.pop), sum(res.pop))

# ── 6. atraso de digitação ───────────────────────────────────────────────────
println("\n── 6. atraso entre internação e competência ──")
comp = Date.(iam_p.ANO_CMPT, iam_p.MES_CMPT, 1)
atraso = [round(Int, Dates.value(c - firstdayofmonth(d)) / 30.44)
          for (d, c) in zip(iam_p.DT_INTER, comp)]
for k in 0:4
    @printf("  %d mês(es): %6d  (%.1f%%)\n", k, count(==(k), atraso),
            100count(==(k), atraso) / length(atraso))
end
@printf("  ≥5 meses : %6d\n", count(≥(5), atraso))

println("\nconcluído.")

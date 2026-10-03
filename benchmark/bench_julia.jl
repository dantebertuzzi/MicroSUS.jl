# MicroSUS.jl — uma medição: julia --project=. benchmark/bench_julia.jl ARQUIVO TAREFA [REPETICOES]
using MicroSUS, DataFrames, Statistics

rss(campo) = parse(Int, match(Regex("$campo:\\s+(\\d+)"), read("/proc/self/status", String))[1]) / 1024

const CVLI_COLS = [:DTOBITO, :CAUSABAS, :CODMUNRES]

function tarefa(arq, t)
    t == "tudo"       && return DataFrame(ler(arq))
    t == "cvli"       && return DataFrame(ler(arq; colunas = CVLI_COLS, filtro = r -> eh_agressao(r[:CAUSABAS])))
    t == "padronizar" && return process_sim(DataFrame(ler(arq)))
    error("tarefa desconhecida: $t")
end

arq, t = ARGS[1], ARGS[2]
reps = length(ARGS) ≥ 3 ? parse(Int, ARGS[3]) : 3
GC.gc(); base = rss("VmRSS")
t0 = time(); df = tarefa(arq, t); frio = time() - t0
pico = rss("VmHWM")
dims = size(df); df = nothing
quentes = Float64[]
for _ in 1:reps
    GC.gc()
    local t0 = time(); tarefa(arq, t); push!(quentes, time() - t0)
end
println("""{"ferramenta":"MicroSUS.jl ($(Threads.nthreads()) thread$(Threads.nthreads() > 1 ? "s" : ""))","arquivo":"$(basename(arq))","tarefa":"$t","linhas":$(dims[1]),"colunas":$(dims[2]),"t_frio":$(round(frio; digits=3)),"t_quente":$(round(median(quentes); digits=3)),"rss_base_mb":$(round(base; digits=1)),"rss_pico_mb":$(round(pico; digits=1))}""")

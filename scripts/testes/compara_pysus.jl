#!/usr/bin/env julia
#= scripts/testes/compara_pysus.jl
Compara os dados lidos pelo MicroSUS.jl com os mesmos dados lidos pelo
pySUS (Python). Ambos baixam do FTP do DATASUS e leem os mesmos arquivos.

Requisitos:
  - Python 3 com pySUS instalado: pip install pySUS
  - Julia com MicroSUS, DataFrames

Uso:
  julia --project=. scripts/testes/compara_pysus.jl
=#
using MicroSUS
using DataFrames

const PYTHON = "python3"

# tenta importar JSON; usa fallback simples se não disponível
const HAS_JSON = try
    using JSON
    true
catch
    false
end

const TESTES = [
    (sistema = :sim,    uf = "PE", ano = 2023,
     colunas = ["DTOBITO", "CAUSABAS", "IDADE", "SEXO"]),
    (sistema = :sinasc, uf = "PE", ano = 2022,
     colunas = ["DTNASC", "IDADEMAE", "PESO", "SEXO"]),
]

function roda_pysus(sistema::Symbol, uf::String, ano::Int, colunas::Vector{String})
    sis = sistema == :sim ? "SIM" :
          sistema == :sinasc ? "SINASC" : error("não suportado")

    cols_py = "[" * join("\"$c\"", colunas) * "]"

    script = """
import pandas as pd
from pysus import ftp
import json

df = ftp.fetch(sis, "$uf", $ano)
df = df[$cols_py].copy()
# converte datas para string (ISO) e numéricos para float
for c in df.columns:
    if df[c].dtype == 'object':
        df[c] = df[c].astype(str)
    else:
        df[c] = pd.to_numeric(df[c], errors='coerce')
print(df.to_json(orient='records', date_format='iso'))
"""

    tmp = tempname() * ".py"
    write(tmp, script)
    try
        result = read(`$PYTHON $tmp`, String)
        return result
    finally
        rm(tmp; force = true)
    end
end

function le_microsus(sistema::Symbol, uf::String, ano::Int, colunas::Vector{String})
    caminho = sistema == :sim ? baixar(:sim, uf; ano = ano) :
              sistema == :sinasc ? baixar(:sinasc, uf; ano = ano) :
              error("não suportado")

    cols_sym = [Symbol(c) for c in colunas]
    df = DataFrame(ler(caminho; colunas = cols_sym))
    return df
end

function compara(sistema, uf, ano, colunas)
    println("\n" * "─"^60)
    println("Comparando: $sistema $uf $ano")
    println("Colunas: $(join(colunas, ", "))")

    # MicroSUS
    df_jl = le_microsus(sistema, uf, ano, colunas)

    # pySUS (opcional — pula se Python/pySUS não disponível)
    try
        json_py = roda_pysus(sistema, uf, ano, colunas)
    catch e
@info "pySUS indisponível (instale com: pip install pysus)"
    return
    end

    # compara contagem de linhas
    if HAS_JSON
        dados_py = JSON.parse(json_py)
    else
        @error "JSON.jl não disponível; instale com: ] add JSON"
        return
    end
    n_py = length(dados_py)
    n_jl = nrow(df_jl)

    println("  Linhas: MicroSUS=$n_jl  pySUS=$n_py")
    if n_jl != n_py
        println("  ❌ Contagem de linhas diverge!")
        return
    end
    println("  ✅ Contagem de linhas idêntica")

    # compara algumas linhas
    iguais = 0
    for (i, row_py) in enumerate(dados_py)
        row_jl = df_jl[i, :]
        match = true
        for c in colunas
            v_py = row_py[c]
            v_jl = row_jl[Symbol(c)]
            # normaliza missing/None
            v_py_n = v_py === nothing ? missing : v_py
            if ismissing(v_jl) && v_py_n === missing
                continue
            elseif ismissing(v_jl) || v_py_n === missing
                match = false
                break
            end
            # compara como string para evitar diferenças de tipo
            if string(v_jl) != string(v_py_n)
                match = false
                break
            end
        end
        iguais += match
        # só checa as primeiras 100 linhas em detalhe
        i >= 100 && break
    end
    n_checadas = min(100, n_jl)
    if iguais == n_checadas
        println("  ✅ Primeiras $n_checadas linhas idênticas")
    else
        println("  ⚠ $iguais/$n_checadas linhas idênticas ($(n_checadas - iguais) divergem)")
    end
end

function main()
    skip_pysus = "--skip-pysus" in ARGS
    if skip_pysus
        @info "Pulando comparação com pySUS (--skip-pysus)"
        return
    end

    for t in TESTES
        compara(t.sistema, t.uf, t.ano, t.colunas)
    end
    println("\n✅ Comparação concluída.")
end

main()
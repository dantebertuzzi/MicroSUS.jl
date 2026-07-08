"""
    MicroSUS

Interface moderna em Julia para download, descompressão, leitura e
padronização dos microdados públicos do DATASUS, inspirada no pacote
`microdatasus` do R (Saldanha, Bastos & Barcellos, 2019), com implementação
totalmente independente.

# Uso típico
```julia
using MicroSUS

# Óbitos de Pernambuco, 2019–2023, padronizados
do_pe = fetch_datasus(:SIM_DO; uf = "PE", anos = 2019:2023)

# Fontes disponíveis
fontes()

# Leitura direta de um .dbc já baixado
df = read_dbc("DOPE2023.dbc")
```

# Camadas
1. **`blast`** — descompressor PKWare DCL em Julia puro (formato dos `.dbc`);
2. **`read_dbc` / `dbc2dbf`** — conversão `.dbc` → tabela/`.dbf`;
3. **`fetch_datasus`** — download com cache + leitura + concatenação;
4. **`process_*`** — padronização por fonte (rótulos, datas, numéricos).
"""
module MicroSUS

using DBFTables
using DataFrames
using Dates
using Downloads
using Printf
using Scratch
using Tables

export fetch_datasus, fontes,
       read_dbc, read_dbc_table, dbc2dbf,
       process_sim, process_sinasc,
       cache_dir, limpar_cache,
       DBCError

include("blast.jl")
include("dbc.jl")
include("sources.jl")
include("download.jl")
include("fetch.jl")
include("process/process.jl")
include("process/sim.jl")
include("process/sinasc.jl")

function __init__()
    __init_cache__()
end

end # module

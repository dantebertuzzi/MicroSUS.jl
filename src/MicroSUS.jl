"""
    MicroSUS

Microdados do DATASUS em Julia, com leitura **streaming** de arquivos
`.dbc` (PKWare DCL) e `.dbf`: memória constante do arquivo comprimido
até o sink, seleção de colunas e filtro de linhas no leitor,
transcodificação CP850/Latin-1 → UTF-8, schemas tipados por sistema
(SIM, SINASC, SIH, SIA, CNES) e interface Tables.jl com partições.

Uso básico:

```julia
using MicroSUS, DataFrames

caminho = baixar(:sim, "PE"; ano = 2023)          # cache local (Scratch.jl)
df = DataFrame(ler(caminho))                       # tudo tipado

# nacional sem estourar RAM: colunas + filtro no leitor
t = ler(caminho; colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO],
        filtro = r -> eh_agressao(r[:CAUSABAS]))   # CVLI: X85–Y09

# streaming direto para Arrow (requer `using Arrow`)
converter(caminho, "do_pe_2023.arrow"; colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES])
```

Formato `.dbc` = cabeçalho DBF em claro + 4 bytes de CRC + registros
comprimidos com PKWare DCL ("implode"). O descompressor é um porte puro
Julia do `blast.c` de Mark Adler, com janela de 4 KiB emitida em chunks
— é isso que permite a leitura em memória constante.
"""
module MicroSUS

using Dates
using Downloads
using InlineStrings
using PooledArrays
using Scratch
using Tables

export ler, materializar, converter, baixar, url_arquivo,
       dcl_descomprime, descomprime_dbc_para_dbf,
       decodifica_idade_sim, capitulo_cid10, eh_agressao,
       dv_ibge, codigo7_ibge, codigo6_ibge,
       CabecalhoDBF, CampoDBF, TabelaDBC

include("dcl.jl")
include("encoding.jl")
include("dbf.jl")
include("dbc.jl")
include("dimensoes.jl")
include("schema.jl")
include("tables.jl")
include("ftp.jl")

"""
    converter(entrada, saida; kwargs...)

Converte um `.dbc`/`.dbf` para Arrow em streaming (um record batch por
lote), sem materializar o arquivo inteiro. Requer `using Arrow` na
sessão (extensão condicional). Aceita os mesmos kwargs de [`ler`](@ref).
"""
function converter end

function __init__()
    Base.Experimental.register_error_hint(MethodError) do io, exc, _, _
        if exc.f === converter
            print(io, "\nconverter requer o pacote Arrow carregado: " *
                      "`using Arrow` e tente novamente.")
        end
    end
end

end # module

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

using DataFrames
using Dates
using Downloads
using InlineStrings
using PooledArrays
using Scratch
using Tables
import SHA

export ler, materializar, converter, baixar, url_arquivo,
       baixar_sinan, url_sinan, agravos_sinan, eh_preliminar,
       verificar_cache, proveniencia,
       dcl_descomprime, descomprime_dbc_para_dbf,
       decodifica_idade_sim, decodifica_idade_sinan, idade_sih,
       capitulo_cid10, eh_agressao,
       normaliza_cid, cid_casa, cids_em, menciona_cid,
       dv_ibge, codigo7_ibge, codigo6_ibge, populacao,
       populacao_por_idade, faixa_etaria, taxa_padronizada,
       uf_de, regiao, municipio, municipios,
       CabecalhoDBF, CampoDBF, TabelaDBC, TabelaConcatenada, cabecalho,
       fetch_datasus, fontes, fonte,
       process_sim, process_sinasc, process_sih, process_sinan, process_cnes

include("dcl.jl")
include("encoding.jl")
include("dbf.jl")
include("dbc.jl")
include("dimensoes.jl")
include("agravos.jl")
include("schema.jl")
include("tables.jl")
include("multi.jl")
include("ftp.jl")
include("download.jl")
include("origem.jl")
include("populacao.jl")
include("populacao_idade.jl")
include("sources.jl")
include("process/process.jl")
include("process/sim.jl")
include("process/sinasc.jl")
include("process/sih.jl")
include("process/cnes.jl")
include("process/sinan.jl")
include("fetch.jl")

"""
    converter(entrada, saida; kwargs...)

Converte um `.dbc`/`.dbf` para Arrow em streaming (um record batch por
lote), sem materializar o arquivo inteiro. Requer `using Arrow` na
sessão (extensão condicional). Aceita os mesmos kwargs de [`ler`](@ref).

`entrada` também pode ser um vetor de caminhos: os arquivos vão para um
único `.arrow`, com schema unificado (ver `ler(caminhos::AbstractVector)`).

As colunas categóricas são gravadas como texto simples, sem dicionário:
o leitor do Arrow.jl falha de forma intermitente em arquivos cujo
dicionário cresce de um lote para outro. Por isso `converter` é o caminho
recomendado em vez de `Arrow.write(saida, ler(caminho))`.
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

# Gera a documentação:
#   julia --project=docs -e 'using Pkg; Pkg.develop(path="."); Pkg.instantiate()'
#   julia --project=docs docs/make.jl
# Saída em docs/build/index.html

using Documenter
using MicroSUS

makedocs(
    sitename = "MicroSUS.jl",
    modules = [MicroSUS],
    authors = "Dante Bertuzzi",
    remotes = nothing,                 # sem repositório remoto configurado
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", "false") == "true",
        edit_link = nothing,
        sidebar_sitename = true,
    ),
    pages = [
        "Início" => "index.md",
        "O formato .dbc e o streaming" => "formato.md",
        "Guia" => [
            "Leitura: ler, filtro, partições" => "guia/leitura.md",
            "Schemas e tipagem" => "guia/schemas.md",
            "Download e FTP" => "guia/download.md",
            "Conversão para Arrow" => "guia/arrow.md",
            "Dimensões: IBGE e CID-10" => "guia/dimensoes.md",
        ],
        "Referência da API" => "api.md",
        "Internos" => "internos.md",
    ],
    checkdocs = :exports,
    warnonly = [:missing_docs, :cross_references],
)

using MicroSUS
using Documenter
import Documenter.Remotes

DocMeta.setdocmeta!(MicroSUS, :DocTestSetup, :(using MicroSUS); recursive = true)

makedocs(;
    modules = [MicroSUS],
    authors = "Dante Bertuzzi",
    sitename = "MicroSUS.jl",
    repo = Remotes.GitHub("dantebertuzzi", "MicroSUS.jl"),
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://dantebertuzzi.github.io/MicroSUS.jl",
        assets = String[],
        sidebar_sitename = true,
    ),
    pages = [
        "Home" => "index.md",
        "O formato .dbc e o streaming" => "formato.md",
        "Guia" => [
            "Leitura: ler, filtro, partições" => "guia/leitura.md",
            "Schemas e tipagem" => "guia/schemas.md",
            "Download e FTP" => "guia/download.md",
            "Conversão para Arrow" => "guia/arrow.md",
            "Dimensões: IBGE e CID-10" => "guia/dimensoes.md",
        ],
        "API Reference" => "api.md",
        "Internals" => "internos.md",
    ],
    checkdocs = :exports,
    warnonly = [:missing_docs, :cross_references],
)

deploydocs(;
    repo = "github.com/dantebertuzzi/MicroSUS.jl",
    push_preview = true,
)
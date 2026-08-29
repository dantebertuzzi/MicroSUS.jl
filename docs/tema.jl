# tema.jl — vocabulário visual compartilhado pelas figuras da documentação.
#
# Extraído de scripts/cartorios/analise_receita.jl (tokens de cor, `cabecalho!`,
# `rodape!`, `quebrar`, formatação de eixo). O que muda aqui em relação à fonte:
# `fmt_num`/`fmt_tick` formatam contagens e taxas em vez de reais, porque os
# eixos desta página são internações e óbitos por 100 mil, não moeda.

using CairoMakie, Colors, Printf

# ── design tokens ────────────────────────────────────────────────────────────
const SURF   = colorant"#fcfcfb"
const INK    = colorant"#0b0b0b"    # texto primário
const INK2   = colorant"#52514e"    # texto secundário
const INK3   = colorant"#8a8983"    # texto discreto, rodapé
const GRID   = colorant"#e8e7e3"
const SERIES = parse.(Colorant, ["#2a78d6", "#eb6834", "#1baf7a",
                                 "#eda100", "#e87ba4", "#008300"])
const AZUL, LARANJA, VERDE = SERIES[1], SERIES[2], SERIES[3]

# rampa sequencial para heatmap — luminosidade monotônica, legível em cinza
const RAMPA = cgrad(["#f2f6fb", "#cde2fb", "#9ec5f4", "#6da7ec",
                     "#3987e5", "#256abf", "#184f95", "#0d366b"])

set_theme!(Theme(
    backgroundcolor = SURF,
    fonts = (; regular = "DejaVu Sans", bold = "DejaVu Sans Bold"),
    Axis = (backgroundcolor = SURF, xgridcolor = GRID, ygridcolor = GRID,
            xgridwidth = 1, ygridwidth = 1, leftspinecolor = GRID,
            bottomspinecolor = GRID, xtickcolor = GRID, ytickcolor = GRID,
            xticklabelcolor = INK2, yticklabelcolor = INK2,
            xlabelcolor = INK2, ylabelcolor = INK2,
            titlecolor = INK, titlealign = :left, titlesize = 15,
            xticklabelsize = 11, yticklabelsize = 11,
            xlabelsize = 12, ylabelsize = 12),
))

# ── formatação ───────────────────────────────────────────────────────────────
"Inteiro com separador de milhar pt-BR: 1234567 → \"1.234.567\"."
function fmt_int(x::Real)
    s = string(round(Int, abs(x)))
    partes = String[]
    while length(s) > 3
        pushfirst!(partes, s[end-2:end]); s = s[1:end-3]
    end
    pushfirst!(partes, s)
    (x < 0 ? "-" : "") * join(partes, ".")
end

"Contagem compacta em linguagem humana: 1200 → \"1,2 mil\"; 3.4e6 → \"3,4 mi\"."
function fmt_num(x)
    (x === missing || (x isa AbstractFloat && isnan(x))) && return "—"
    a = abs(x)
    a ≥ 1e6 && return replace(@sprintf("%.1f mi", x / 1e6), "." => ",")
    a ≥ 1e3 && return replace(@sprintf("%.1f mil", x / 1e3), "." => ",")
    fmt_int(x)
end

"Decimal pt-BR com `d` casas: 12.34 → \"12,3\"."
fmt_dec(x, d = 1) = replace(@sprintf("%.*f", d, x), "." => ",")

# ── cabeçalho e rodapé ───────────────────────────────────────────────────────
"""
    cabecalho!(fig, titulo, subtitulo; cols = 1)

Título como afirmação (linha 1, negrito) e subtítulo em duas linhas (linha 2):
a primeira descreve o dado, a segunda ensina a ler o gráfico.
"""
function cabecalho!(fig, t, sub; cols = 1)
    Label(fig[1, cols], t; fontsize = 18, font = :bold, color = INK,
          halign = :left, tellwidth = false, padding = (2, 0, 0, 2))
    Label(fig[2, cols], sub; fontsize = 12, color = INK2, halign = :left,
          justification = :left, lineheight = 1.2, tellwidth = false,
          padding = (2, 0, 0, 14))
end

"Quebra cada linha do texto em pedaços de até `largura` caracteres, por palavra."
function quebrar(texto, largura = 170)
    saida = String[]
    for linha in split(texto, '\n')
        atual = ""
        for palavra in split(linha)
            if isempty(atual)
                atual = palavra
            elseif length(atual) + 1 + length(palavra) ≤ largura
                atual *= " " * palavra
            else
                push!(saida, atual); atual = palavra
            end
        end
        push!(saida, atual)
    end
    join(saida, "\n")
end

"""
    rodape!(fig, linha, texto; cols = 1)

Fonte e ressalvas metodológicas. Obrigatório em toda figura: sem a proveniência
e o que o dado não cobre, o gráfico não se sustenta fora do texto.
"""
rodape!(fig, linha, texto; cols = 1) =
    Label(fig[linha, cols], quebrar(texto); fontsize = 9.5, color = INK3,
          halign = :left, justification = :left, lineheight = 1.3,
          tellwidth = false, padding = (2, 0, 8, 6))

const FONTE_SIH = "Fonte: SIH/SUS — Autorizações de Internação Hospitalar, Ministério da Saúde, via MicroSUS.jl."
const FONTE_SIM = "Fonte: SIM — Sistema de Informações sobre Mortalidade, Ministério da Saúde, via MicroSUS.jl."
const FONTE_POP = "População: IBGE, Censo Demográfico 2022 (SIDRA, tabela 9514)."

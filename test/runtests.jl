using MicroSUS
using Test
using Dates
using Random
using Tables
using PooledArrays

# ═════════════════════════════════════════════════════════════════════
# Infra de teste 1: compressor DCL mínimo (literais crus + matches +
# código de fim), usando as próprias tabelas canônicas do pacote para
# emitir códigos — permite round-trip real do descompressor.
# ═════════════════════════════════════════════════════════════════════

mutable struct EscritorBits
    bytes::Vector{UInt8}
    atual::Int
    nbits::Int
end
EscritorBits() = EscritorBits(UInt8[], 0, 0)

function bit!(w::EscritorBits, b::Integer)
    w.atual |= (Int(b) & 1) << w.nbits
    w.nbits += 1
    if w.nbits == 8
        push!(w.bytes, UInt8(w.atual))
        w.atual = 0
        w.nbits = 0
    end
end

# LSB-first, como o leitor consome
bits!(w::EscritorBits, val::Integer, n::Int) =
    foreach(i -> bit!(w, (val >> i) & 1), 0:(n - 1))

function fecha!(w::EscritorBits)
    w.nbits > 0 && (push!(w.bytes, UInt8(w.atual)); w.atual = 0; w.nbits = 0)
    return w.bytes
end

# emite o código canônico de `sym` (MSB primeiro, bits invertidos —
# exatamente o inverso do decodificador do blast)
function codigo!(w::EscritorBits, h::MicroSUS._Huffman, sym::Int)
    first = 0
    index = 0
    for len in 1:MicroSUS._MAXBITS
        cnt = h.count[len + 1]
        for k in 1:cnt
            if h.symbol[index + k] == sym
                code = first + (k - 1)
                for i in (len - 1):-1:0
                    bit!(w, ((code >> i) & 1) ⊻ 1)
                end
                return
            end
        end
        index += cnt
        first = (first + cnt) << 1
    end
    error("símbolo $sym sem código")
end

# símbolo de comprimento para um dado len (usa base/extra do pacote)
function simbolo_len(len::Int)
    for s in 15:-1:0
        b = MicroSUS._LEN_BASE[s + 1]
        e = MicroSUS._LEN_EXTRA[s + 1]
        if b ≤ len ≤ b + (1 << e) - 1
            return s, len - b, e
        end
    end
    error("len fora de faixa")
end

function comprime_dcl(dados::Vector{UInt8};
                      dict::Int = 4,
                      matches::Vector{Tuple{Int,Int,Int}} = Tuple{Int,Int,Int}[])
    # matches: lista (posição_inicial_1based, len, dist) — o restante
    # vai como literal cru. Posições devem ser consistentes c/ os dados.
    w = EscritorBits()
    bits!(w, 0, 8)      # literais crus
    bits!(w, dict, 8)
    i = 1
    ms = sort(matches; by = first)
    mi = 1
    while i ≤ length(dados)
        if mi ≤ length(ms) && ms[mi][1] == i
            (_, len, dist) = ms[mi]
            bit!(w, 1)
            s, extra_val, extra_n = simbolo_len(len)
            codigo!(w, MicroSUS._LENCODE, s)
            bits!(w, extra_val, extra_n)
            nb = len == 2 ? 2 : dict
            d = dist - 1
            codigo!(w, MicroSUS._DISTCODE, d >> nb)
            bits!(w, d & ((1 << nb) - 1), nb)
            i += len
            mi += 1
        else
            bit!(w, 0)
            bits!(w, dados[i], 8)
            i += 1
        end
    end
    # código de fim: len 519 = símbolo 15 + 255 nos 8 bits extras
    bit!(w, 1)
    codigo!(w, MicroSUS._LENCODE, 15)
    bits!(w, 255, 8)
    return fecha!(w)
end

# ═════════════════════════════════════════════════════════════════════
# Infra de teste 2: montagem de DBF/DBC sintéticos
# ═════════════════════════════════════════════════════════════════════

function monta_cabecalho_dbf(campos::Vector{<:Tuple}, n_reg::Int;
                             ldid::UInt8 = 0x02)
    # campos: (nome::String, tipo::Char, largura::Int, decimais::Int)
    rsize = 1 + sum(c[3] for c in campos)
    hsize = 32 + 32 * length(campos) + 1
    h = zeros(UInt8, hsize)
    h[1] = 0x03
    h[2:4] .= (24, 1, 1)                       # data qualquer
    h[5:8] .= reinterpret(UInt8, [UInt32(n_reg)])
    h[9:10] .= reinterpret(UInt8, [UInt16(hsize)])
    h[11:12] .= reinterpret(UInt8, [UInt16(rsize)])
    h[30] = ldid
    pos = 33
    for (nome, tipo, larg, dec) in campos
        nb = codeunits(nome)
        h[pos:(pos + length(nb) - 1)] .= nb
        h[pos + 11] = UInt8(tipo)
        h[pos + 16] = UInt8(larg)
        h[pos + 17] = UInt8(dec)
        pos += 32
    end
    h[pos] = 0x0d
    return h, rsize
end

# valor → bytes de campo com padding correto (C: à direita; N: à esquerda)
function campo_bytes(valor, tipo::Char, larg::Int)
    b = valor isa Vector{UInt8} ? valor : Vector{UInt8}(codeunits(string(valor)))
    length(b) ≤ larg || error("valor maior que o campo")
    pad = fill(0x20, larg - length(b))
    return tipo == 'C' ? vcat(b, pad) : vcat(pad, b)
end

function monta_registros(campos, linhas)
    corpo = UInt8[]
    for linha in linhas
        push!(corpo, 0x20)   # flag: ativo
        for ((_, tipo, larg, _), valor) in zip(campos, linha)
            append!(corpo, campo_bytes(valor, tipo, larg))
        end
    end
    return corpo
end

function escreve_dbf(caminho, campos, linhas; ldid = 0x02)
    h, _ = monta_cabecalho_dbf(campos, length(linhas); ldid = ldid)
    open(caminho, "w") do io
        write(io, h)
        write(io, monta_registros(campos, linhas))
        write(io, 0x1a)
    end
    return caminho
end

function escreve_dbc(caminho, campos, linhas; ldid = 0x02, kwargs...)
    h, _ = monta_cabecalho_dbf(campos, length(linhas); ldid = ldid)
    corpo = monta_registros(campos, linhas)
    open(caminho, "w") do io
        write(io, h)
        write(io, UInt8[0, 0, 0, 0])            # CRC (ignorado na leitura)
        write(io, comprime_dcl(corpo; kwargs...))
    end
    return caminho
end

# ═════════════════════════════════════════════════════════════════════
# Testes
# ═════════════════════════════════════════════════════════════════════

@testset "MicroSUS.jl" begin

    rng = MersenneTwister(2026)

    @testset "DCL — round-trip de literais" begin
        for n in (1, 100, 4096, 4097, 20_000)   # cruza fronteiras da janela
            dados = rand(rng, UInt8, n)
            fluxo = comprime_dcl(dados)
            saida = MicroSUS.dcl_descomprime(IOBuffer(fluxo))
            @test saida == dados
        end
    end

    @testset "DCL — matches (cópia com sobreposição e volta na janela)" begin
        # "ABC" literal + match(len=9, dist=3) ⇒ ABC repetido 4×
        dados = Vector{UInt8}("ABCABCABCABC")
        fluxo = comprime_dcl(dados; matches = [(4, 9, 3)])
        @test MicroSUS.dcl_descomprime(IOBuffer(fluxo)) == dados

        # padrão que atravessa várias janelas de 4096
        bloco = Vector{UInt8}("PETROLINA-PE ")
        dados2 = repeat(bloco, 2000)             # 26 000 bytes
        L = length(bloco)
        # len máximo por match é 519 (código de fim); quebra em vários
        ms = Tuple{Int,Int,Int}[]
        pos = L + 1
        resta = length(dados2) - L
        while resta > 0
            l = min(resta, 500)
            push!(ms, (pos, l, L))
            pos += l
            resta -= l
        end
        fluxo2 = comprime_dcl(dados2; matches = ms)
        # também testa o sink por chunks
        pedacos = Vector{UInt8}[]
        total = MicroSUS.dcl_descomprime(IOBuffer(fluxo2),
                                         c -> push!(pedacos, Vector(c)))
        @test total == length(dados2)
        @test all(length(p) ≤ 4096 for p in pedacos)
        @test vcat(pedacos...) == dados2
    end

    campos = [("NOME", 'C', 12, 0), ("QTD", 'N', 5, 0),
              ("VALOR", 'N', 8, 2), ("DTREG", 'D', 8, 0)]
    # "SÃO JOSÉ" em CP850: Ã = 0xC7, É = 0x90
    sao_jose = UInt8['S', 0xC7, 'O', ' ', 'J', 'O', 'S', 0x90]
    linhas = [
        ["RECIFE", "123", "45.10", "20230115"],
        [sao_jose, "7", "0.50", "20231201"],
        ["PETROLINA", "", "", ""],               # vazios → missing
    ]

    @testset "DBF — leitura direta" begin
        dir = mktempdir()
        f = escreve_dbf(joinpath(dir, "sintetico.dbf"), campos, linhas)
        cab = MicroSUS.cabecalho(f)
        @test cab.n_registros == 3
        @test [c.nome for c in cab.campos] == [:NOME, :QTD, :VALOR, :DTREG]

        t = ler(f)
        cols = Tables.columntable(t)
        @test cols.NOME == ["RECIFE", "SÃO JOSÉ", "PETROLINA"]
        @test isequal(cols.QTD, [Int32(123), Int32(7), missing])
        @test isequal(cols.VALOR, [45.10, 0.50, missing])
        @test isequal(cols.DTREG,
                      [Date(2023, 1, 15), Date(2023, 12, 1), missing])
    end

    @testset "DBC ≡ DBF (mesmos dados pelos dois caminhos)" begin
        dir = mktempdir()
        fdbf = escreve_dbf(joinpath(dir, "a.dbf"), campos, linhas)
        fdbc = escreve_dbc(joinpath(dir, "a.dbc"), campos, linhas)
        @test isequal(Tables.columntable(ler(fdbf)), Tables.columntable(ler(fdbc)))

        # dbc → dbf materializado
        fdbf2 = MicroSUS.descomprime_dbc_para_dbf(
            fdbc, joinpath(dir, "b.dbf"))
        @test isequal(Tables.columntable(ler(fdbf2)), Tables.columntable(ler(fdbf)))
    end

    @testset "schema SIM: datas, idade, pooling, colunas, filtro" begin
        campos_sim = [("DTOBITO", 'C', 8, 0), ("IDADE", 'C', 3, 0),
                      ("CAUSABAS", 'C', 4, 0), ("CODMUNRES", 'C', 6, 0),
                      ("SEXO", 'C', 1, 0)]
        linhas_sim = [
            ["15012023", "425", "X954", "261110", "1"],
            ["02062023", "501", "I219", "261160", "2"],
            ["30112023", "310", "Y090", "261110", "1"],
            ["        ", "999", "W870", "260790", "2"],
        ]
        dir = mktempdir()
        f = escreve_dbc(joinpath(dir, "DOPE2023.dbc"), campos_sim, linhas_sim)

        t = ler(f)   # schema :auto pelo prefixo DO
        cols = Tables.columntable(t)
        @test isequal(cols.DTOBITO[1], Date(2023, 1, 15))
        @test ismissing(cols.DTOBITO[4])
        @test cols.IDADE[1] == 25.0
        @test cols.IDADE[2] == 101.0
        @test cols.IDADE[3] ≈ 10 / 12
        @test ismissing(cols.IDADE[4])
        @test cols.CAUSABAS isa PooledArray

        # seleção de colunas + filtro por agressão (CVLI)
        t2 = ler(f; colunas = [:CAUSABAS, :CODMUNRES],
                 filtro = r -> eh_agressao(r[:CAUSABAS]))
        c2 = Tables.columntable(t2)
        @test length(c2.CAUSABAS) == 2
        @test all(eh_agressao, c2.CAUSABAS)
        @test propertynames(c2) == (:CAUSABAS, :CODMUNRES)

        @test_throws ArgumentError ler(f; colunas = [:NAO_EXISTE])
        @test occursin("CAUSABAS", sprint(show, MIME"text/plain"(), t))
    end

    @testset "partições e materializar" begin
        campos_p = [("ID", 'N', 6, 0), ("COD", 'C', 3, 0)]
        n = 5_000
        linhas_p = [[string(i), string(i % 7)] for i in 1:n]
        dir = mktempdir()
        f = escreve_dbc(joinpath(dir, "p.dbc"), campos_p, linhas_p)

        t = ler(f; tamanho_lote = 1_000)
        lotes = collect(Tables.partitions(t))
        @test length(lotes) == 5
        @test all(length(l.ID) == 1_000 for l in lotes)
        @test vcat((l.ID for l in lotes)...) == Int32.(1:n)

        mat = materializar(t)
        @test length(mat.ID) == n
        @test mat.ID == Int32.(1:n)
    end

    @testset "idade SIM — tabela de unidades" begin
        @test decodifica_idade_sim("425") == 25.0
        @test decodifica_idade_sim("400") == 0.0
        @test decodifica_idade_sim("501") == 101.0
        @test decodifica_idade_sim("312") == 1.0          # 12 meses
        @test decodifica_idade_sim("230") ≈ 30 / 365.25   # dias
        @test decodifica_idade_sim("112") ≈ 12 / 8766     # horas
        @test decodifica_idade_sim("030") ≈ 30 / 525960   # minutos
        @test ismissing(decodifica_idade_sim("999"))
        @test ismissing(decodifica_idade_sim("   "))
        @test ismissing(decodifica_idade_sim(missing))
    end

    @testset "dimensões: IBGE e CID-10" begin
        @test dv_ibge(355030) == 8                 # São Paulo
        @test codigo7_ibge(261110) == 2611101      # Petrolina
        @test codigo6_ibge(2611101) == 261110
        @test_throws ArgumentError codigo6_ibge(2611100)
        @test codigo6_ibge(2611100; validar = false) == 261110

        @test capitulo_cid10("X954").numeral == "XX"
        @test capitulo_cid10("I219").numeral == "IX"
        @test capitulo_cid10("C50").numeral == "II"
        @test capitulo_cid10("") === nothing
        @test capitulo_cid10("1234") === nothing

        @test eh_agressao("X850")
        @test eh_agressao("X99")
        @test eh_agressao("Y00")
        @test eh_agressao("Y090")
        @test eh_agressao("Y871")                  # sequela de agressão
        @test !eh_agressao("Y10")
        @test !eh_agressao("W870")
        @test !eh_agressao(missing)
    end

    @testset "encoding CP850" begin
        b = UInt8['S', 0xC7, 'O', ' ', 'J', 'O', 'S', 0x90, ' ', ' ']
        @test MicroSUS.decodifica_texto(b, 1, 10, :cp850) == "SÃO JOSÉ"
        @test MicroSUS.decodifica_texto(b, 1, 10, :latin1) != "SÃO JOSÉ"
        ascii = Vector{UInt8}("RECIFE  ")
        @test MicroSUS.decodifica_texto(ascii, 1, 8, :cp850) == "RECIFE"
    end

    @testset "URLs do FTP" begin
        @test url_arquivo(:sim, "PE"; ano = 2023) ==
              "ftp://ftp.datasus.gov.br/dissemin/publicos/SIM/CID10/DORES/DOPE2023.dbc"
        @test url_arquivo(:sinasc, "pe"; ano = 2022) ==
              "ftp://ftp.datasus.gov.br/dissemin/publicos/SINASC/1996_/Dados/DNRES/DNPE2022.dbc"
        @test occursin("PRELIM", url_arquivo(:sinasc, "PE"; ano = 2024,
                                             prelim = true))
        @test occursin("SIM/PRELIM", url_arquivo(:sim, "PE"; ano = 2025,
                                                 prelim = true))
        @test_throws ArgumentError url_arquivo(:sinasc, "PE"; ano = 1995)
        @test url_arquivo(:sih, "PE"; ano = 2023, mes = 1) |> basename ==
              "RDPE2301.dbc"
        @test_throws ArgumentError url_arquivo(:sim, "XX"; ano = 2023)
        @test_throws ArgumentError url_arquivo(:sih, "PE"; ano = 2023)
    end
end

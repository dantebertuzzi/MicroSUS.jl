using MicroSUS
using Test
using DataFrames
using Dates
using Random
using Tables
using PooledArrays
using Arrow

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

    @testset "ler(caminhos) — vários arquivos como uma tabela" begin
        dir = mktempdir()
        # mesmo layout, larguras diferentes: COD C(3) num, C(10) noutro
        a = escreve_dbc(joinpath(dir, "a.dbc"), [("ID", 'N', 6, 0), ("COD", 'C', 3, 0)],
                        [[string(i), "x$(i % 3)"] for i in 1:2_500])
        b = escreve_dbc(joinpath(dir, "b.dbc"), [("ID", 'N', 6, 0), ("COD", 'C', 10, 0)],
                        [[string(i), "y$(i % 2)"] for i in 2_501:4_000])

        t = ler([a, b]; tamanho_lote = 1_000)
        @test t isa TabelaConcatenada
        lotes = collect(Tables.partitions(t))
        @test length(lotes) == 5                       # 3 de a + 2 de b
        @test length(unique(map(l -> map(typeof, values(l)), lotes))) == 1
        @test eltype(lotes[1].COD) == eltype(lotes[end].COD)   # largura unificada
        d = DataFrame(t)
        @test d.ID == Int32.(1:4_000)
        @test d.COD[1] == "x1" && d.COD[end] == "y0"
        @test d.ARQUIVO == [fill("a.dbc", 2_500); fill("b.dbc", 1_500)]
        @test propertynames(DataFrame(ler([a, b]; origem = nothing))) == [:ID, :COD]
        @test propertynames(DataFrame(ler([a, b]; origem = :FONTE))) == [:ID, :COD, :FONTE]
        @test_throws ArgumentError ler([a, b]; origem = :ID)
        @test_throws ArgumentError ler(String[])

        # filtro e colunas valem para cada arquivo
        f = DataFrame(ler([a, b]; colunas = [:COD], filtro = r -> r[:COD] in ("x0", "y0")))
        @test nrow(f) == 833 + 750
        @test propertynames(f) == [:COD, :ARQUIVO]

        # layouts diferentes: erro por padrão, união com missing se pedido
        c = escreve_dbc(joinpath(dir, "c.dbc"), [("ID", 'N', 6, 0), ("NOVO", 'C', 2, 0)],
                        [["9001", "n1"], ["9002", "n2"]])
        e = try ler([a, c]); nothing catch err; err end
        @test e isa ArgumentError && occursin("faltam em", e.msg) && occursin("uniao = true", e.msg)
        u = DataFrame(ler([a, c]; uniao = true))
        @test propertynames(u) == [:ID, :COD, :NOVO, :ARQUIVO]
        @test all(ismissing, u.COD[2_501:end]) && all(ismissing, u.NOVO[1:2_500])
        @test u.NOVO[end] == "n2"
        # com `colunas`, a ordem é a pedida mesmo que o 1º arquivo não tenha a coluna
        o = DataFrame(ler([c, a]; colunas = [:COD, :NOVO, :ID], ignorar_ausentes = true,
                          uniao = true))
        @test propertynames(o) == [:COD, :NOVO, :ID, :ARQUIVO]

        # campo que muda de tipo: inteiro + decimal → Float64; N + C → texto, com aviso
        g = escreve_dbc(joinpath(dir, "g.dbc"), [("ID", 'N', 8, 2), ("COD", 'C', 3, 0)],
                        [["1.50", "z"]])
        @test eltype(DataFrame(ler([a, g])).ID) == Union{Missing,Float64}
        h = escreve_dbc(joinpath(dir, "h.dbc"), [("ID", 'C', 6, 0), ("COD", 'C', 3, 0)],
                        [["abc", "z"]])
        th = @test_logs (:warn, r"ID muda de tipo") ler([a, h])
        dh = DataFrame(th)
        @test eltype(dh.ID) == String && dh.ID[1] == "1" && dh.ID[end] == "abc"

        # colunas categóricas: pool de String em todo arquivo e lote
        pa = DataFrame(ler([a, b]; schema = Dict(:COD => :pool), tamanho_lote = 1_000))
        @test pa.COD isa PooledArray && eltype(pa.COD) == String
    end

    @testset "Arrow: vários lotes com coluna categórica, e vários arquivos" begin
        dir = mktempdir()
        a = escreve_dbc(joinpath(dir, "a.dbc"), [("ID", 'N', 6, 0), ("COD", 'C', 3, 0)],
                        [[string(i), "x$(i % 3)"] for i in 1:2_500])
        b = escreve_dbc(joinpath(dir, "b.dbc"), [("ID", 'N', 6, 0), ("COD", 'C', 10, 0)],
                        [[string(i), "y$(i % 2)"] for i in 2_501:4_000])
        pool = Dict(:COD => :pool)
        # regressão: o dicionário de InlineString quebrava o Arrow no 2º lote
        s1 = converter(a, joinpath(dir, "a.arrow"); schema = pool, tamanho_lote = 1_000)
        @test DataFrame(Arrow.Table(s1)) == DataFrame(ler(a; schema = pool))
        s2 = converter([a, b], joinpath(dir, "ab.arrow"); schema = pool, tamanho_lote = 1_000)
        r = DataFrame(Arrow.Table(s2))
        @test nrow(r) == 4_000
        @test r == DataFrame(ler([a, b]; schema = pool))
        # valores novos de categoria em lotes posteriores: com dicionário, o
        # leitor do Arrow.jl falhava de vez em quando; sem ele, nunca
        c = escreve_dbc(joinpath(dir, "c.dbc"), [("COD", 'C', 3, 0)],
                        [["z$(i ÷ 500)"] for i in 1:2_500])
        s3 = converter(c, joinpath(dir, "c.arrow"); schema = pool, tamanho_lote = 500)
        @test all(_ -> length(Arrow.Table(s3).COD) == 2_500, 1:20)
        @test !(Arrow.Table(s3).COD isa Arrow.DictEncoded)
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
        @test eh_agressao("X99.0")                 # normaliza o ponto
        @test !eh_agressao("X8")                   # curto demais para a faixa
    end

    @testset "busca de CID: prefixos, faixas, causas múltiplas" begin
        @test normaliza_cid(" a81.0 ") == "A810"
        @test normaliza_cid(missing) == ""

        dcj = ["A810", "F021"]
        @test cid_casa("A810", dcj)
        @test cid_casa("a81.0", dcj)
        @test !cid_casa("A811", dcj)
        @test cid_casa("A811", "A81")              # alvo único, prefixo de categoria
        @test cid_casa("J189", "J12" => "J18")
        @test !cid_casa("J190", "J12" => "J18")
        @test cid_casa("I219", ["C00" => "D48", "I21"])
        @test !cid_casa("", dcj)
        @test !cid_casa(missing, dcj)
        @test_throws ArgumentError cid_casa("A810", "A8" => "A810")

        @test cids_em("*I219*E149") == ["I219", "E149"]
        @test cids_em("*j18x  r092") == ["J18X", "R092"]
        @test cids_em(missing) == String[]
        @test menciona_cid("*G934*A810", dcj)
        @test !menciona_cid("*G934*I10X", dcj)
        @test !menciona_cid("*A8*10", "A810")      # não junta códigos vizinhos
        @test !menciona_cid(missing, dcj)
    end

    @testset "UF, região e municípios (tabela embarcada)" begin
        @test uf_de("261160") == "PE"
        @test uf_de(2611606) == "PE"
        @test uf_de(" 530010") == "DF"
        @test uf_de(53) == "DF"
        @test uf_de("") === missing
        @test uf_de("990000") === missing
        @test uf_de(missing) === missing

        @test regiao("PE") == "Nordeste"
        @test regiao("sp") == "Sudeste"
        @test regiao(4314902) == "Sul"
        @test regiao("530010") == "Centro-Oeste"
        @test regiao("XX") === missing

        ms = municipios()
        @test length(ms) == 5571
        @test length(unique(m.codigo7 for m in ms)) == length(ms)
        @test sort(unique(m.uf for m in ms)) == sort([u[1] for u in values(MicroSUS._UFS)])
        @test all(m -> uf_de(m.codigo7) == m.uf && regiao(m.uf) == m.regiao, ms)
        @test all(m -> codigo7_ibge(m.codigo6) == m.codigo7, ms)

        r = municipio("261160")
        @test r.nome == "Recife" && r.uf == "PE" && r.codigo7 == 2611606
        @test municipio(2611606) == r
        @test municipio(261160) == r
        @test municipio(2611600) === nothing       # DV errado
        @test municipio("260000") === nothing      # "ignorado" do DATASUS
        @test municipio("") === nothing
        @test municipio(missing) === nothing

        # DV oficial que foge do algoritmo de dv_ibge
        @test dv_ibge(261153) == 1
        @test codigo7_ibge(261153) == 2611533      # Quixaba-PE
        @test codigo6_ibge(2611533) == 261153
        @test_throws ArgumentError codigo6_ibge(2611531)
        @test municipio(2611533).nome == "Quixaba"
    end

    @testset "encoding CP850" begin
        b = UInt8['S', 0xC7, 'O', ' ', 'J', 'O', 'S', 0x90, ' ', ' ']
        @test MicroSUS.decodifica_texto(b, 1, 10, :cp850) == "SÃO JOSÉ"
        @test MicroSUS.decodifica_texto(b, 1, 10, :latin1) != "SÃO JOSÉ"
        ascii = Vector{UInt8}("RECIFE  ")
        @test MicroSUS.decodifica_texto(ascii, 1, 8, :cp850) == "RECIFE"
    end

    @testset "SINAN: idade, schema, detecção, URLs" begin
        @test decodifica_idade_sinan("4025") == 25.0
        @test decodifica_idade_sinan("3006") == 0.5        # 6 meses
        @test decodifica_idade_sinan("2015") ≈ 15 / 365.25 # 15 dias
        @test decodifica_idade_sinan("5010") == 110.0
        @test ismissing(decodifica_idade_sinan("999"))
        @test ismissing(decodifica_idade_sinan(missing))

        @test MicroSUS.detecta_sistema("DENGBR20.dbc") == :sinan
        @test MicroSUS.detecta_sistema("CHIKBR20.dbc") == :sinan
        @test MicroSUS.detecta_sistema("ZIKABR20.dbc") == :sinan

        @test url_sinan(:dengue; ano = 2020) ==
              "ftp://ftp.datasus.gov.br/dissemin/publicos/SINAN/DADOS/FINAIS/DENGBR20.dbc"
        @test occursin("CHIKBR19", url_sinan(:chikungunya; ano = 2019))
        @test occursin("PRELIM", url_sinan(:zika; ano = 2024, prelim = true))
        @test_throws ArgumentError url_sinan(:inexistente; ano = 2020)

        # leitura tipada de um DENGBR sintético (schema :auto → :sinan)
        campos_dg = [("DT_NOTIFIC", 'C', 8, 0), ("NU_IDADE_N", 'C', 4, 0),
                     ("CS_SEXO", 'C', 1, 0), ("SG_UF", 'C', 2, 0),
                     ("CLASSI_FIN", 'C', 2, 0)]
        linhas_dg = [
            ["20200315", "4025", "F", "26", "10"],
            ["20200620", "3006", "M", "26", "5"],
            ["20200810", "4040", "F", "25", "11"],
        ]
        dir = mktempdir()
        f = escreve_dbc(joinpath(dir, "DENGBR20.dbc"), campos_dg, linhas_dg)
        t = ler(f; filtro = r -> strip(r[:SG_UF]) == "26")
        c = Tables.columntable(t)
        @test length(c.NU_IDADE_N) == 2                 # só residentes 26
        @test isequal(c.DT_NOTIFIC[1], Date(2020, 3, 15))
        @test c.NU_IDADE_N[1] == 25.0                   # idade_sinan
        @test c.NU_IDADE_N[2] == 0.5
    end

    @testset "catálogo único dos agravos do SINAN" begin
        ag = agravos_sinan()
        @test length(ag) == length(MicroSUS.AGRAVOS_SINAN) ≥ 48
        @test allunique(a.agravo for a in ag)
        @test allunique(a.prefixo for a in ag)
        @test all(a -> 2000 ≤ a.ano_inicial ≤ 2025, ag)
        for a in ag
            # as três visões derivam da mesma tabela e concordam
            f = fonte(a.fonte)
            @test f.abrangencia == :br && first(f.anos) == a.ano_inicial
            u = url_sinan(a.agravo; ano = 2023)
            @test basename(u) == "$(a.prefixo)BR23.dbc"
            @test first(f.urls(nothing, 2023, nothing)) == u
            @test MicroSUS.detecta_sistema(basename(u)) === :sinan
        end
        # prefixo de 3 letras: o nome do arquivo inteiro é que decide
        @test MicroSUS.detecta_sistema("SRCBR21.dbc") === :sinan
        @test MicroSUS.detecta_sistema("srcbr21.DBF") === :sinan
        @test MicroSUS.detecta_sistema("MALABR22.dbc") === :sinan
        @test MicroSUS.detecta_sistema("DOPE2023.dbc") === :sim
        @test MicroSUS.detecta_sistema("XYZWBR21.dbc") === nothing
        # todo símbolo que baixar_sinan aceitava antes continua aceito
        for s in (:dengue, :chikungunya, :chik, :zika, :malaria,
                  :leishmaniose_visceral, :leishmaniose_tegumentar,
                  :esquistossomose, :febre_tifoide, :meningite, :tuberculose,
                  :hanseniase, :hepatites, :violencia, :intoxicacao_exogena,
                  :acidente_animais)
            @test url_sinan(s; ano = 2020) isa String
        end
        @test url_sinan(:chik; ano = 2020) == url_sinan(:chikungunya; ano = 2020)
        # e toda fonte :SINAN_* que existia continua existindo
        for id in (:SINAN_DENGUE, :SINAN_CHIKUNGUNYA, :SINAN_ZIKA,
                   :SINAN_MALARIA, :SINAN_TUBERCULOSE, :SINAN_VIOLENCIA)
            @test fonte(id) isa MicroSUS.FonteDATASUS
        end
        @test occursin("SIFCBR24", url_sinan(:sifilis_congenita; ano = 2024))
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

    # ═════════════════════════════════════════════════════════════════
    # fetch_datasus / fontes / fonte — interface de alto nível (sources.jl,
    # download.jl, fetch.jl, process/*.jl). Usa URLs file:// apontando para
    # fixtures .dbc sintéticas (mesmo helper escreve_dbc usado acima), então
    # roda 100% offline: Downloads.download trata file:// como um protocolo
    # normal (RequestError para arquivo inexistente, igual FTP/HTTP 404).
    # ═════════════════════════════════════════════════════════════════

    @testset "fontes() e fonte() — catálogo" begin
        fs = fontes()
        @test !isempty(fs)
        ids = Set(f.id for f in fs)
        @test :SIM_DO in ids
        @test :SINASC in ids
        @test :SINAN_DENGUE in ids

        f = fonte(:SIM_DO)
        @test f.periodicidade == :anual
        @test f.abrangencia == :uf

        fnac = fonte(:SINAN_DENGUE)
        @test fnac.abrangencia == :br

        @test_throws ArgumentError fonte(:NAO_EXISTE)
    end

    @testset "fetch_datasus — fonte sintética particionada por UF" begin
        dir = mktempdir()
        campos_fic = [("DTOBITO", 'C', 8, 0), ("IDADE", 'C', 3, 0),
                      ("SEXO", 'C', 1, 0)]
        escreve_dbc(joinpath(dir, "FICPE2023.dbc"), campos_fic,
                    [["15012023", "425", "1"], ["02062023", "430", "2"]])
        escreve_dbc(joinpath(dir, "FICBA2023.dbc"), campos_fic,
                    [["10032023", "501", "1"]])

        MicroSUS.registrar!(MicroSUS.FonteDATASUS(
            id = :TESTE_FIC_UF,
            nome = "Fonte fictícia (teste, por UF)",
            periodicidade = :anual,
            abrangencia = :uf,
            urls = (uf, ano, _) -> ["file://" * joinpath(dir, "FIC$(uf)$(ano).dbc")],
            anos = 2023:2023,
        ))

        try
            df = fetch_datasus(:TESTE_FIC_UF; uf = ["PE", "BA"], anos = 2023,
                               processar = false, cache = false, verbose = false)
            @test nrow(df) == 3
            @test Set(df.UF_ARQUIVO) == Set(["PE", "BA"])
            @test all(==(2023), df.ANO_ARQUIVO)
            @test "DTOBITO" in names(df)

            # UF sem arquivo correspondente: pulada (com @warn), resultado só
            # com as encontradas — não lança erro.
            df2 = @test_logs (:warn,) fetch_datasus(:TESTE_FIC_UF; uf = ["PE", "SP"],
                                                    anos = 2023, processar = false,
                                                    cache = false, verbose = false)
            @test Set(df2.UF_ARQUIVO) == Set(["PE"])
        finally
            # não deixa a fonte fictícia vazar para outros testes (ex.: o
            # teste de rede, que itera fontes() por completo).
            delete!(MicroSUS.FONTES, :TESTE_FIC_UF)
        end
    end

    @testset "dados preliminares: cache separado, metadado e consolidação" begin
        dir = mktempdir()
        mkpath(joinpath(dir, "FINAIS")); mkpath(joinpath(dir, "PRELIM"))
        campos = [("DTOBITO", 'C', 8, 0), ("SEXO", 'C', 1, 0)]
        # mesmo nome nas duas pastas, como no FTP; nome que não colide com
        # nada do cache real do usuário
        nome = "TESTEPRELIMPE2023.dbc"
        escreve_dbc(joinpath(dir, "PRELIM", nome), campos, [["15012023", "1"]])

        MicroSUS.registrar!(MicroSUS.FonteDATASUS(
            id = :TESTE_PRELIM, nome = "Fonte fictícia (preliminar)",
            periodicidade = :anual, abrangencia = :uf,
            urls = (uf, ano, _) -> ["file://" * joinpath(dir, p, "TESTEPRELIM$(uf)$(ano).dbc")
                                    for p in ("FINAIS", "PRELIM")],
            anos = 2023:2023,
        ))
        cache_final = joinpath(MicroSUS._dir_cache(), nome)
        cache_prelim = joinpath(MicroSUS._dir_cache(), "PRELIM", nome)
        try
            df = @test_logs (:warn, r"PRELIMINARES") fetch_datasus(:TESTE_PRELIM;
                uf = "PE", anos = 2023, processar = false, verbose = false)
            @test df.PRELIMINAR == [true]
            @test isfile(cache_prelim) && !isfile(cache_final)
            @test eh_preliminar(cache_prelim) && !eh_preliminar(cache_final)
            @test occursin("PRELIMINARES", sprint(show, MIME"text/plain"(), ler(cache_prelim)))

            # o DATASUS consolida: com o preliminar ainda no cache, o
            # consolidado é tentado primeiro e passa a ser o usado
            escreve_dbc(joinpath(dir, "FINAIS", nome), campos,
                        [["15012023", "1"], ["16012023", "2"]])
            df2 = @test_logs fetch_datasus(:TESTE_PRELIM; uf = "PE", anos = 2023,
                                           processar = false, verbose = false)
            @test df2.PRELIMINAR == [false, false]
            @test nrow(df2) == 2
            @test !occursin("PRELIMINARES", sprint(show, MIME"text/plain"(), ler(cache_final)))
        finally
            delete!(MicroSUS.FONTES, :TESTE_PRELIM)
            rm(cache_final; force = true); rm(cache_prelim; force = true)
        end
    end

    @testset "fetch_datasus — fonte sintética nacional (abrangência :br)" begin
        dir = mktempdir()
        campos_fic = [("DT_NOTIFIC", 'C', 8, 0), ("SG_UF", 'C', 2, 0)]
        escreve_dbc(joinpath(dir, "FICBR23.dbc"), campos_fic,
                    [["20230115", "26"], ["20230620", "35"]])

        MicroSUS.registrar!(MicroSUS.FonteDATASUS(
            id = :TESTE_FIC_BR,
            nome = "Fonte fictícia (teste, nacional)",
            periodicidade = :anual,
            abrangencia = :br,
            urls = (_, ano, _) -> ["file://" * joinpath(dir, "FICBR$(string(ano % 100; pad = 2)).dbc")],
            anos = 2023:2023,
        ))

        try
            # uf é ignorada em fontes nacionais
            df = fetch_datasus(:TESTE_FIC_BR; uf = "PE", anos = 2023,
                               processar = false, cache = false, verbose = false)
            @test nrow(df) == 2
            @test only(unique(df.UF_ARQUIVO)) == "BR"
        finally
            delete!(MicroSUS.FONTES, :TESTE_FIC_BR)
        end
    end

    @testset "fetch_datasus — processar=true aplica process_sim (override de :SIM_DO)" begin
        dir = mktempdir()
        campos_sim = [("DTOBITO", 'C', 8, 0), ("IDADE", 'C', 3, 0),
                      ("SEXO", 'C', 1, 0), ("RACACOR", 'C', 1, 0)]
        # Nome de arquivo deliberadamente diferente do padrão real (DOxxAAAA)
        # para nunca colidir com um arquivo já presente no cache real do
        # usuário (mesmo _dir_cache() usado por baixar/fetch_datasus de verdade).
        escreve_dbc(joinpath(dir, "TESTEFICSIMPE2023.dbc"), campos_sim,
                    [["15012023", "425", "1", "4"], ["02062023", "430", "2", "1"]])

        original = MicroSUS.FONTES[:SIM_DO]
        MicroSUS.registrar!(MicroSUS.FonteDATASUS(
            id = :SIM_DO, nome = original.nome, periodicidade = :anual,
            abrangencia = :uf,
            urls = (uf, ano, _) -> ["file://" * joinpath(dir, "TESTEFICSIM$(uf)$(ano).dbc")],
            anos = 2023:2023,
        ))
        try
            df = fetch_datasus(:SIM_DO; uf = "PE", anos = 2023, cache = false, verbose = false)
            @test eltype(df.DTOBITO) <: Union{Missing,Date}
            @test df.DTOBITO[1] == Date(2023, 1, 15)
            @test df.SEXO == ["Masculino", "Feminino"]
            @test df.RACACOR == ["Parda", "Branca"]
            @test "IDADE_ANOS" in names(df)
            @test df.IDADE_ANOS == [25, 30]
        finally
            MicroSUS.registrar!(original)   # restaura a fonte real
        end
    end

    @testset "fetch_datasus — validações" begin
        @test_throws ArgumentError fetch_datasus(:SIM_DO; uf = "XX", anos = 2023, verbose = false)
        @test_throws ArgumentError fetch_datasus(:SIM_DO; uf = "PE", anos = Int[], verbose = false)
        @test_throws ArgumentError fetch_datasus(:SIH_RD; uf = "PE", anos = 2023, verbose = false)  # mensal sem `meses`

        dir = mktempdir()
        MicroSUS.registrar!(MicroSUS.FonteDATASUS(
            id = :TESTE_FIC_VAZIA,
            nome = "Fonte fictícia (teste, sempre ausente)",
            periodicidade = :anual,
            abrangencia = :uf,
            urls = (uf, ano, _) -> ["file://" * joinpath(dir, "NAOEXISTE$(uf)$(ano).dbc")],
            anos = 2023:2023,
        ))
        try
            @test_throws ErrorException fetch_datasus(:TESTE_FIC_VAZIA; uf = "PE",
                                                       anos = 2023, verbose = false)
        finally
            delete!(MicroSUS.FONTES, :TESTE_FIC_VAZIA)
        end
    end

    @testset "process_sim / process_sinasc / rotular! / para_data! / para_int!" begin
        df = DataFrame(SEXO = ["1", "2", "9"], DTOBITO = ["15012023", "00000000", ""],
                       IDADE = ["425", "999", "   "], QTDFILVIVO = ["2", "", "abc"])
        out = MicroSUS.process_sim(df)
        @test isequal(out.SEXO, ["Masculino", "Feminino", missing])
        @test out.DTOBITO[1] == Date(2023, 1, 15)
        @test ismissing(out.DTOBITO[2]) && ismissing(out.DTOBITO[3])
        @test out.IDADE_ANOS[1] == 25
        @test ismissing(out.IDADE_ANOS[2])
        @test isequal(out.QTDFILVIVO, [2, missing, missing])

        dfn = DataFrame(SEXO = ["M", "F"], PARTO = ["1", "2"], PESO = ["3200", ""])
        outn = MicroSUS.process_sinasc(dfn)
        @test outn.SEXO == ["Masculino", "Feminino"]
        @test outn.PARTO == ["Vaginal", "Cesáreo"]
        @test isequal(outn.PESO, [3200, missing])

        # coluna ausente é ignorada, não lança erro
        dfsem = DataFrame(OUTRACOISA = [1, 2])
        @test MicroSUS.process_sim(dfsem) == dfsem
    end

    @testset "process_sinan: núcleo, zeros à esquerda, agravo, idade" begin
        df = DataFrame(
            ID_AGRAVO  = ["A90", "A90", "A90"],
            TP_NOT     = ["2", "2", "3"],
            CS_SEXO    = ["M", "F", "I"],
            CS_RACA    = ["4", "9", ""],
            CS_GESTANT = ["1", "6", "9"],
            CS_ESCOL_N = ["01", "1", "00"],       # mesmo arquivo, duas formas
            HOSPITALIZ = ["1", "2", "9"],
            CLASSI_FIN = ["10", "5", "0"],
            CRITERIO   = ["1", "2", ""],
            EVOLUCAO   = ["1", "2", "9"],
            NU_IDADE_N = [25.4, 0.5, missing],    # já em anos (schema)
            DT_ENCERRA = ["20230115", "", "00000000"],
        )
        out = process_sinan(df)
        @test isequal(out.CS_SEXO, ["Masculino", "Feminino", missing])
        @test out.TP_NOT == ["Individual", "Individual", "Surto"]
        @test isequal(out.CS_RACA, ["Parda", missing, missing])
        @test isequal(out.CS_GESTANT, ["1º trimestre", "Não se aplica", missing])
        @test out.CS_ESCOL_N == ["1ª a 4ª série incompleta do EF",
                                 "1ª a 4ª série incompleta do EF", "Analfabeto"]
        @test isequal(out.HOSPITALIZ, ["Sim", "Não", missing])
        @test isequal(out.CLASSI_FIN, ["Dengue", "Descartado", missing])
        @test isequal(out.CRITERIO, ["Laboratorial", "Clínico-epidemiológico", missing])
        @test isequal(out.EVOLUCAO, ["Cura", "Óbito pelo agravo", missing])
        @test isequal(out.IDADE_ANOS, [25, 0, missing])
        @test isequal(out.DT_ENCERRA, [Date(2023, 1, 15), missing, missing])
        @test df.CS_SEXO == ["M", "F", "I"]       # original intacto

        # o mesmo "1" muda de sentido com o agravo
        z = DataFrame(ID_AGRAVO = ["A928", "A92."], CLASSI_FIN = ["1", "2"])
        @test process_sinan(z).CLASSI_FIN == ["Confirmado", "Descartado"]
        d = DataFrame(CLASSI_FIN = ["1", "2"])
        @test process_sinan(d; agravo = :dengue).CLASSI_FIN ==
              ["Dengue clássico", "Dengue com complicações"]
        @test process_sinan(d; agravo = :chikungunya).CLASSI_FIN ==
              ["Confirmado", "Descartado"]

        # agravo desconhecido ou misto: CLASSI_FIN/EVOLUCAO ficam crus
        v = DataFrame(ID_AGRAVO = ["Y09", "Y09"], CLASSI_FIN = ["1", "3"], CS_SEXO = ["F", "M"])
        outv = process_sinan(v)
        @test outv.CLASSI_FIN == ["1", "3"]
        @test outv.CS_SEXO == ["Feminino", "Masculino"]
        misto = DataFrame(ID_AGRAVO = ["A90", "A928"], CLASSI_FIN = ["1", "1"])
        @test process_sinan(misto).CLASSI_FIN == ["1", "1"]
        @test process_sinan(misto; agravo = nothing).CLASSI_FIN == ["1", "1"]
        @test_throws ArgumentError process_sinan(misto; agravo = :malaria)

        # NU_IDADE_N cru: texto e inteiro (campo N lido sem schema) são o código
        @test isequal(process_sinan(DataFrame(NU_IDADE_N = ["4025", "3006", "999"])).IDADE_ANOS,
                      [25, 0, missing])
        @test process_sinan(DataFrame(NU_IDADE_N = [4025, 5010, 2015])).IDADE_ANOS ==
              [25, 110, 0]

        # despacho pelo id da fonte
        zf = DataFrame(CLASSI_FIN = ["1"], CS_SEXO = ["F"])
        @test MicroSUS.processar_fonte(:SINAN_ZIKA, zf).CLASSI_FIN == ["Confirmado"]
        tf = MicroSUS.processar_fonte(:SINAN_TUBERCULOSE, zf)
        @test tf.CLASSI_FIN == ["1"] && tf.CS_SEXO == ["Feminino"]

        @test process_sinan(DataFrame(OUTRACOISA = [1])) == DataFrame(OUTRACOISA = [1])
    end

    @testset "rotular! — ignora_zeros" begin
        df = DataFrame(X = ["01", "1", "00", "10", "A1"])
        dic = Dict("0" => "zero", "1" => "um", "10" => "dez", "A1" => "a-um")
        @test isequal(MicroSUS.rotular!(copy(df), :X, dic).X, [missing, "um", missing, "dez", "a-um"])
        @test MicroSUS.rotular!(copy(df), :X, dic; ignora_zeros = true).X ==
              ["um", "um", "zero", "dez", "a-um"]
    end

    @testset "detecta_sistema reconhece toda fonte SINAN registrada" begin
        for (id, f) in MicroSUS.FONTES
            startswith(string(id), "SINAN_") || continue
            arq = basename(first(f.urls("BR", 2022, nothing)))
            @test MicroSUS.detecta_sistema(arq) === :sinan
        end
    end

    @testset "ignorar_ausentes e cabecalho pública" begin
        caminho = joinpath(@__DIR__, "data", "sids.dbc")

        # cabecalho é API pública: acessível sem o prefixo do módulo
        cab = cabecalho(caminho)
        @test cab.n_registros > 0
        @test !isempty(cab.campos)
        presente = cab.campos[1].nome
        @test presente in keys(cab.indice)
        @test !(:NAO_EXISTE_MESMO in keys(cab.indice))

        # comportamento padrão: coluna ausente é erro, listando as disponíveis
        err = try ler(caminho; colunas = [presente, :NAO_EXISTE_MESMO]); nothing
              catch e; e end
        @test err isa ArgumentError
        @test occursin("NAO_EXISTE_MESMO", sprint(showerror, err))

        # ignorar_ausentes descarta o que não existe e mantém o resto
        t = ler(caminho; colunas = [presente, :NAO_EXISTE_MESMO],
                ignorar_ausentes = true)
        @test [c.nome for c in t.campos] == [presente]
        @test nrow(DataFrame(t)) == nrow(DataFrame(ler(caminho; colunas = [presente])))

        # mas se NENHUMA existir continua sendo erro: aí o problema é outro
        @test_throws ArgumentError ler(caminho; colunas = [:NADA_A, :NADA_B],
                                       ignorar_ausentes = true)

        # a ordem pedida é preservada entre as que sobraram
        if length(cab.campos) ≥ 2
            a, b = cab.campos[1].nome, cab.campos[2].nome
            t2 = ler(caminho; colunas = [b, :NAO_EXISTE_MESMO, a],
                     ignorar_ausentes = true)
            @test [c.nome for c in t2.campos] == [b, a]
        end
    end

    @testset "process_sih / idade_sih" begin
        # SEXO no SIH é 1/3 (não 1/2 como no SIM) e RACA_COR é 01..05 + 99
        df = DataFrame(SEXO = ["1", "3", "9"],
                       RACA_COR = ["01", "03", "99"],
                       IDENT = ["1", "5", "9"],
                       CAR_INT = ["01", "02", "07"],
                       IDADE = [45, 6, 5], COD_IDADE = [4, 3, 5],
                       MORTE = [0, 1, 0],
                       DT_INTER = ["20220115", "00000000", ""])
        out = MicroSUS.process_sih(df)
        @test isequal(out.SEXO, ["Masculino", "Feminino", missing])
        @test isequal(out.RACA_COR, ["Branca", "Parda", missing])   # 99 → missing
        @test isequal(out.IDENT, ["Normal", "Longa permanência", missing])
        @test isequal(out.CAR_INT, ["Eletivo", "Urgência", missing])
        @test out.IDADE_ANOS == [45, 0, 105]      # anos, 6 meses → 0, 5+100
        @test out.DT_INTER[1] == Date(2022, 1, 15)
        @test ismissing(out.DT_INTER[2]) && ismissing(out.DT_INTER[3])
        @test sum(out.MORTE) == 1

        # idade_sih aceita tanto o tipado quanto o texto cru
        @test MicroSUS.idade_sih(45, 4) == 45
        @test MicroSUS.idade_sih("45", "4") == 45
        @test MicroSUS.idade_sih(30, 2) == 0            # dias
        @test MicroSUS.idade_sih(12, 3) == 0            # meses
        @test MicroSUS.idade_sih(5, 5) == 105
        @test ismissing(MicroSUS.idade_sih(45, 9))
        @test ismissing(MicroSUS.idade_sih(missing, 4))
        @test ismissing(MicroSUS.idade_sih(45, missing))
        @test ismissing(MicroSUS.idade_sih("abc", "4"))

        # COBRANCA e ESPEC ficam crus de propósito (domínio extenso e variável)
        dfc = DataFrame(COBRANCA = ["12", "61"], ESPEC = ["01", "03"])
        @test MicroSUS.process_sih(dfc).COBRANCA == ["12", "61"]
        @test MicroSUS.process_sih(dfc).ESPEC == ["01", "03"]

        # coluna ausente é ignorada
        @test MicroSUS.process_sih(DataFrame(X = [1])) == DataFrame(X = [1])
    end

    # -----------------------------------------------------------------------
    # Testes de rede (opcionais):
    # MicroSUS_TEST_NETWORK=true julia --project -e 'using Pkg; Pkg.test()'
    # -----------------------------------------------------------------------
    if get(ENV, "MicroSUS_TEST_NETWORK", "false") == "true"
        @testset "Rede (DATASUS) — links de todas as fontes registradas" begin
            # Para cada fonte de fontes(), baixa de verdade o ano MAIS ANTIGO
            # coberto (tende a ser o menor arquivo) — PE quando particionado
            # por UF. Pega tanto link quebrado quanto mudança de estrutura do
            # FTP; roda para TODAS as fontes, não só uma amostra, porque agora
            # existe fontes() para enumerá-las.
            falhas = Tuple{Symbol,String}[]
            for f in fontes()
                ano = f.ano_inicial
                # dez/ano_inicial em vez de jan: alguns sistemas começam no
                # meio do ano de cobertura (CNES em 08/2005, SIA_PA em
                # 07/1994) — dezembro já existe em qualquer um dos casos.
                mes = f.periodicidade == :mensal ? 12 : nothing
                try
                    df = fetch_datasus(f.id; uf = "PE", anos = ano, meses = mes,
                                       processar = false, cache = false,
                                       verbose = false)
                    nrow(df) > 0 || push!(falhas, (f.id, "0 linhas retornadas"))
                catch e
                    push!(falhas, (f.id, sprint(showerror, e)))
                end
            end
            isempty(falhas) ||
                @warn "Fontes com problema no FTP do DATASUS" falhas
            @test isempty(falhas)
        end
    else
        @info "Testes de rede desativados. Ative com MicroSUS_TEST_NETWORK=true."
    end
end

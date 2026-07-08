using MicroSUS
using MicroSUS: dbc_para_dbf_bytes, blast, idade_sim,
                rotular!, para_data!, para_int!, fonte, UFS,
                _inserir_sufixo, _normalizar_ufs, _validar_ufs
using DataFrames
using Dates
using Test

# sids.dbc: arquivo de teste clássico (dataset SIDS da Carolina do Norte),
# usado também pelo read.dbc do R. 100 registros, header de 481 bytes,
# registros de 168 bytes.
const SIDS = joinpath(@__DIR__, "data", "sids.dbc")

@testset "MicroSUS.jl" begin

    @testset "blast / dbc → dbf" begin
        dbf = dbc_para_dbf_bytes(read(SIDS))

        nrec  = Int(dbf[5]) | Int(dbf[6]) << 8 | Int(dbf[7]) << 16 | Int(dbf[8]) << 24
        hsize = Int(dbf[9]) | Int(dbf[10]) << 8
        rsize = Int(dbf[11]) | Int(dbf[12]) << 8

        @test nrec == 100
        @test hsize == 481
        @test rsize == 168
        @test length(dbf) == hsize + nrec * rsize + 1
        @test dbf[end] == 0x1a                       # byte EOF do DBF

        # Conteúdo dos registros deve ser texto ASCII (campos Character/Numeric)
        primeiro = String(dbf[hsize+1:hsize+rsize])
        @test occursin("Ashe", primeiro)
        @test occursin("1825", primeiro)

        # Erros de formato
        @test_throws DBCError dbc_para_dbf_bytes(UInt8[0x03, 0x00])
        @test_throws DBCError blast(UInt8[0xff, 0xff, 0x00])   # flag inválida
    end

    @testset "dbc2dbf grava arquivo" begin
        mktempdir() do dir
            destino = joinpath(dir, "sids.dbf")
            @test dbc2dbf(SIDS, destino) == destino
            @test filesize(destino) == 17282
        end
    end

    @testset "read_dbc → DataFrame" begin
        df = read_dbc(SIDS)
        @test df isa DataFrame
        @test nrow(df) == 100
        @test ncol(df) == 14
        @test issubset(["AREA", "NAME", "BIR74"], names(df))

        # Valores conhecidos do dataset SIDS (condado de Ashe, NC)
        @test df.AREA[1] ≈ 0.114
        @test strip(String(df.NAME[1])) == "Ashe"
        @test strip(String(df.NAME[2])) == "Alleghany"
    end

    @testset "catálogo de fontes" begin
        @test length(UFS) == 27
        @test :SIM_DO in getproperty.(fontes(), :id)

        f = fonte(:SIM_DO)
        @test f.periodicidade == :anual
        @test occursin("DOPE2023.dbc", first(f.urls("PE", 2023, 0)))

        f = fonte(:SIH_RD)
        @test occursin("RDPE2401.dbc", first(f.urls("PE", 2024, 1)))
        @test occursin("199201_200712", first(f.urls("PE", 2000, 6)))

        f = fonte(:SINAN_DENGUE)
        @test f.abrangencia == :br
        @test occursin("DENGBR24.dbc", first(f.urls("BR", 2024, 0)))

        @test _inserir_sufixo("ftp://x/PAPE2401.dbc", "b") == "ftp://x/PAPE2401b.dbc"
        @test _validar_ufs("pe") == ["PE"]
        @test_throws ArgumentError _validar_ufs("XX")
        @test _normalizar_ufs(fonte(:SIM_DO), :all) == UFS
        @test_throws ArgumentError fonte(:NAO_EXISTE)
    end

    @testset "padronização — utilitários" begin
        df = DataFrame(SEXO = ["1", "2", "9", missing],
                       DTOBITO = ["01072026", "1072026", "00000000", "abc"],
                       PESO = ["3200", "", missing, "x"])
        rotular!(df, :SEXO, MicroSUS.SIM_SEXO)
        para_data!(df, :DTOBITO)
        para_int!(df, :PESO)

        @test isequal(df.SEXO, ["Masculino", "Feminino", missing, missing])
        @test df.DTOBITO[1] == Date(2026, 7, 1)
        @test df.DTOBITO[2] == Date(2026, 7, 1)   # dia sem zero à esquerda
        @test ismissing(df.DTOBITO[3]) && ismissing(df.DTOBITO[4])
        @test isequal(df.PESO, [3200, missing, missing, missing])

        # Coluna inexistente é ignorada sem erro
        @test rotular!(df, :NAO_EXISTE, MicroSUS.SIM_SEXO) === df
    end

    @testset "padronização — SIM" begin
        @test idade_sim("435") == 35
        @test idade_sim("501") == 101
        @test idade_sim("312") == 0      # 12 meses → 0 anos completos
        @test idade_sim("201") == 0      # dias
        @test idade_sim("101") == 0      # horas
        @test ismissing(idade_sim("9"))
        @test ismissing(idade_sim(missing))

        df = DataFrame(SEXO = ["1"], RACACOR = ["4"], IDADE = ["475"],
                       DTOBITO = ["15032023"], CIRCOBITO = ["3"])
        out = process_sim(df)
        @test out.SEXO == ["Masculino"]
        @test out.RACACOR == ["Parda"]
        @test out.IDADE_ANOS == [75]
        @test out.IDADE == ["475"]               # original preservado
        @test out.DTOBITO == [Date(2023, 3, 15)]
        @test out.CIRCOBITO == ["Homicídio"]
        @test df.SEXO == ["1"]                   # entrada não mutada
    end

    @testset "padronização — SINASC" begin
        df = DataFrame(SEXO = ["2", "M"], PARTO = ["1", "2"],
                       DTNASC = ["01012024", "31122023"],
                       PESO = ["3450", "2980"], APGAR1 = ["9", "8"])
        out = process_sinasc(df)
        @test out.SEXO == ["Feminino", "Masculino"]
        @test out.PARTO == ["Vaginal", "Cesáreo"]
        @test out.DTNASC == [Date(2024, 1, 1), Date(2023, 12, 31)]
        @test out.PESO == [3450, 2980]
        @test out.APGAR1 == [9, 8]
    end

    @testset "fetch_datasus — validação de argumentos" begin
        @test_throws ArgumentError fetch_datasus(:NAO_EXISTE; anos = 2023)
        @test_throws ArgumentError fetch_datasus(:SIH_RD; uf = "PE", anos = 2023)  # falta meses
        @test_throws ArgumentError fetch_datasus(:SIM_DO; uf = "XX", anos = 2023)
    end

end

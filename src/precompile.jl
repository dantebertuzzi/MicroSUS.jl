# ─────────────────────────────────────────────────────────────────────
# Workload de precompilação (PrecompileTools): lê arquivos sintéticos,
# gerados aqui mesmo, pelos caminhos que uma análise percorre — `.dbc` e
# `.dbf`, schema automático e explícito, todo tipo lógico em toda largura
# de texto, filtro, colunas, partições, vários arquivos e `DataFrame`. O
# código nativo resultante fica no cache do pacote, e a primeira leitura
# da sessão deixa de pagar a compilação (≈ 2,8 s no DOPE2023).
#
# Nada aqui acessa a rede nem o cache do usuário: os arquivos vão para um
# diretório temporário apagado no fim.
# ─────────────────────────────────────────────────────────────────────

# Fluxo DCL só de literais crus + código de fim: o bastante para exercitar
# o descompressor sem um compressor de verdade.
function _pc_dcl_literais(dados::Vector{UInt8})
    out = UInt8[]
    acc = 0
    nb = 0
    function bit!(b)
        acc |= (b & 1) << nb
        nb += 1
        nb == 8 && (push!(out, UInt8(acc)); acc = 0; nb = 0)
        return nothing
    end
    bits!(v, n) = foreach(i -> bit!(v >> i), 0:(n - 1))
    bits!(0, 8)                    # literais crus
    bits!(4, 8)                    # dicionário de 1 KiB
    for b in dados
        bit!(0)
        bits!(Int(b), 8)
    end
    # código de fim: símbolo de comprimento 15 + 255 nos 8 bits extras
    bit!(1)
    h = _LENCODE
    first = 0
    index = 0
    for len in 1:_MAXBITS
        cnt = h.count[len + 1]
        k = findfirst(==(15), view(h.symbol, (index + 1):(index + cnt)))
        if k !== nothing
            code = first + k - 1
            foreach(i -> bit!(((code >> i) & 1) ⊻ 1), (len - 1):-1:0)
            break
        end
        index += cnt
        first = (first + cnt) << 1
    end
    bits!(255, 8)
    nb > 0 && push!(out, UInt8(acc))
    return out
end

# campos (nome, tipo DBF, largura, decimais) e valor de cada um por linha
function _pc_dbf(campos, linhas)
    rsize = 1 + sum(c[3] for c in campos)
    hsize = 32 + 32 * length(campos) + 1
    h = zeros(UInt8, hsize)
    h[1] = 0x03
    h[2:4] .= (23, 1, 1)
    h[5:8] .= reinterpret(UInt8, [UInt32(length(linhas))])
    h[9:10] .= reinterpret(UInt8, [UInt16(hsize)])
    h[11:12] .= reinterpret(UInt8, [UInt16(rsize)])
    h[30] = 0x02                       # LDID: CP850
    p = 33
    for (nome, tipo, larg, dec) in campos
        nb = codeunits(nome)
        h[p:(p + length(nb) - 1)] .= nb
        h[p + 11] = UInt8(tipo)
        h[p + 16] = UInt8(larg)
        h[p + 17] = UInt8(dec)
        p += 32
    end
    h[p] = 0x0d
    corpo = UInt8[]
    for (k, linha) in enumerate(linhas)
        push!(corpo, k == length(linhas) ? 0x2a : 0x20)   # último: deletado
        for ((_, tipo, larg, _), v) in zip(campos, linha)
            b = v isa Vector{UInt8} ? v : Vector{UInt8}(codeunits(string(v)))
            pad = fill(0x20, larg - length(b))
            append!(corpo, tipo == 'C' ? vcat(b, pad) : vcat(pad, b))
        end
    end
    return h, corpo
end

function _pc_escreve(caminho, h, corpo)
    open(caminho, "w") do io
        write(io, h)
        if endswith(caminho, ".dbc")
            write(io, UInt8[0, 0, 0, 0])
            write(io, _pc_dcl_literais(corpo))
        else
            write(io, corpo)
            write(io, 0x1a)
        end
    end
    return caminho
end

# Os campos que `process_sim` e `process_sinasc` tocam, com as larguras dos
# arquivos reais (DOPE2023, DNSP2023): a compilação especializa no tipo de
# cada coluna (PooledArray, String3, String7, Int32…), que vem da largura.
const _PC_SIM = [("DTOBITO", 8), ("DTNASC", 8), ("IDADE", 3), ("SEXO", 1),
    ("RACACOR", 1), ("ESTCIV", 1), ("ESC", 1), ("LOCOCOR", 1), ("QTDFILVIVO", 2),
    ("QTDFILMORT", 2), ("GRAVIDEZ", 1), ("OBITOPARTO", 1), ("PESO", 4),
    ("TPMORTEOCO", 1), ("OBITOGRAV", 1), ("OBITOPUERP", 1), ("ASSISTMED", 1),
    ("NECROPSIA", 1), ("DTATESTADO", 8), ("CIRCOBITO", 1), ("ACIDTRAB", 1),
    ("FONTE", 1), ("DTINVESTIG", 8), ("DTCADASTRO", 8), ("CAUSABAS", 4),
    ("CODMUNRES", 6), ("CODMUNOCOR", 6)]
const _PC_SINASC = [("LOCNASC", 1), ("IDADEMAE", 2), ("ESTCIVMAE", 1),
    ("ESCMAE", 1), ("QTDFILVIVO", 2), ("QTDFILMORT", 2), ("GRAVIDEZ", 1),
    ("PARTO", 1), ("CONSULTAS", 1), ("DTNASC", 8), ("SEXO", 1), ("APGAR1", 2),
    ("APGAR5", 2), ("RACACOR", 1), ("PESO", 4), ("DTCADASTRO", 8),
    ("DTNASCMAE", 8), ("RACACORMAE", 1), ("QTDGESTANT", 2), ("QTDPARTNOR", 2),
    ("QTDPARTCES", 2), ("IDADEPAI", 2), ("DTULTMENST", 8), ("SEMAGESTAC", 2),
    ("CONSPRENAT", 2), ("STTRABPART", 1), ("STCESPARTO", 1), ("DTDECLARAC", 8),
    ("CODMUNRES", 6)]

# um valor válido por largura (código "1", datas, idade do SIM, município);
# a 3ª linha fica em branco, como os campos ignorados dos arquivos reais (as
# colunas saem Union{Missing,…}, como nos dados de verdade)
function _pc_valor(nome, larg, i)
    i == 3 && return ""
    nome == "IDADE" && return i == 1 ? "472" : "210"
    nome == "CAUSABAS" && return i == 1 ? "X954" : "I219"
    larg == 8 && return "0$(i)022023"
    larg == 6 && return "26116$(i)"
    larg == 4 && return "3$(i)00"
    return lpad(string(i), larg, '0')
end

_pc_processo(campos) = _pc_dbf([(n, 'C', l, 0) for (n, l) in campos],
                               [[_pc_valor(n, l, i) for (n, l) in campos] for i in 1:4])

PrecompileTools.@setup_workload begin
    # um campo de texto por classe de InlineString (String3 … String) e
    # os tipos lógicos dos schemas
    campos = [("DTOBITO", 'C', 8, 0), ("DTNASC", 'C', 8, 0),
              ("IDADE", 'C', 3, 0), ("SEXO", 'C', 1, 0),
              ("RACACOR", 'C', 1, 0), ("CODMUNRES", 'C', 6, 0),
              ("CAUSABAS", 'C', 4, 0), ("LINHAA", 'C', 20, 0),
              ("NU_IDADE_N", 'C', 4, 0), ("T2", 'C', 2, 0),
              ("T40", 'C', 40, 0), ("T80", 'C', 80, 0), ("T120", 'C', 120, 0),
              ("QTD", 'N', 5, 0), ("VALOR", 'N', 8, 2), ("DTREG", 'D', 8, 0)]
    sao_jose = UInt8['S', 0xc7, 'O', ' ', 'J', 'O', 'S', 0x90]   # CP850
    linhas = [["01022023", "15071950", "472", "1", "2", "261160", "X954",
               "*X954", "4072", "AB", sao_jose, "x", "y", 3, "12.50", "20230201"],
              ["02022023", "01012023", "210", "2", "4", "260790", "I219",
               "*I219", "3006", "CD", "RUA", "", "", 1, "7.25", "20230202"],
              ["03022023", "", "999", "9", "", "261160", "R99", "", "",
               "", "", "", "", "", "", ""]]
    h, corpo = _pc_dbf(campos, linhas)
    texto = Dict(Symbol(c[1]) => :pool for c in campos if c[2] == 'C')
    texto[:NU_IDADE_N] = :idade_sinan
    h_sim, c_sim = _pc_processo(_PC_SIM)
    h_nasc, c_nasc = _pc_processo(_PC_SINASC)
    PrecompileTools.@compile_workload begin
        dir = mktempdir()
        try
            sim = _pc_escreve(joinpath(dir, "DOXX2023.dbc"), h, corpo)
            sim2 = _pc_escreve(joinpath(dir, "DOXX2024.dbc"), h, corpo)
            dbf = _pc_escreve(joinpath(dir, "XX2023.dbf"), h, corpo)
            cabecalho(sim)
            DataFrame(ler(sim))
            DataFrame(ler(dbf))
            DataFrame(ler(dbf; schema = texto))
            DataFrame(ler(sim; pool = false))
            DataFrame(ler(sim; colunas = [:DTOBITO, :CAUSABAS, :CODMUNRES, :IDADE, :SEXO],
                           filtro = r -> haskey(r, :CAUSABAS) && eh_agressao(r[:CAUSABAS])))
            for lote in Tables.partitions(ler(sim; tamanho_lote = 1))
                length(lote)
            end
            # o ramo paralelo da conversão (com várias threads, um lote grande)
            for f in (sim, dbf), sch in (:auto, texto)
                tab = ler(f; schema = sch)
                for lote in canal_registros(f, tab.cab)
                    _converte_lote(tab, lote, true)
                end
            end
            DataFrame(ler([sim, sim2]))
            DataFrame(ler([sim, dbf]; colunas = [:CAUSABAS, :QTD]))
            # padronização: a 1ª chamada de process_sim compilava ~3,5 s
            do_ = _pc_escreve(joinpath(dir, "DOYY2023.dbc"), h_sim, c_sim)
            dn = _pc_escreve(joinpath(dir, "DNYY2023.dbc"), h_nasc, c_nasc)
            process_sim(DataFrame(ler(do_)))
            process_sim(DataFrame(ler(do_)); copiar = false)
            process_sinasc(DataFrame(ler(dn)))
        finally
            rm(dir; recursive = true, force = true)
        end
    end
end

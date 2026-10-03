# cnes.jl — Padronização dos microdados do CNES (estabelecimentos, arquivo
# ST, e profissionais, arquivo PF).
#
# Os dicionários ficam em data/rotulos_cnes.tsv, derivados do microdatasus
# (MIT) e restritos aos campos cujos códigos observados em arquivos reais
# de 2005, 2019 e 2023 estão todos cobertos. Sem as tabelas oficiais do
# DATASUS (.cnv) para conferir os rótulos, um código que apareça em outro
# ano ou UF e não esteja no dicionário vira missing com aviso, nunca em
# silêncio.

const _Rotulos = Dict{Symbol,Tuple{Dict{String,String},Set{String}}}
const _ROTULOS_CNES = Ref{_Rotulos}()
const _TRAVA_CNES = ReentrantLock()

function _rotulos_cnes()
    isassigned(_ROTULOS_CNES) && return _ROTULOS_CNES[]
    lock(_TRAVA_CNES) do
        isassigned(_ROTULOS_CNES) && return _ROTULOS_CNES[]
        d = _Rotulos()
        for linha in eachline(joinpath(pkgdir(@__MODULE__), "data", "rotulos_cnes.tsv"))
            (isempty(linha) || startswith(linha, '#')) && continue
            campo, codigo, rotulo = split(linha, '\t')
            rot, ign = get!(() -> (Dict{String,String}(), Set{String}()), d, Symbol(campo))
            rotulo == "\\N" ? push!(ign, String(codigo)) : (rot[String(codigo)] = String(rotulo))
        end
        _ROTULOS_CNES[] = d
    end
end

"""
    process_cnes(df::DataFrame; copiar = true) -> DataFrame

Padroniza microdados do CNES — estabelecimentos (`:CNES_ST`) e
profissionais (`:CNES_PF`): rotula os campos categóricos presentes (tipo
de unidade `TP_UNID`, esfera administrativa `ESFERA_A`, natureza
`NATUREZA`/`NAT_JUR`, nível de hierarquia `NIV_HIER`, tipo de gestão
`TPGESTAO`, vínculo com o SUS `VINC_SUS`, turno `TURNO_AT`, clientela
`CLIENTEL`, os indicadores sim/não de serviços, e mais — 119 campos ao
todo). Códigos com e sem zero à esquerda valem o mesmo.

Os dicionários vêm do `microdatasus` (licença MIT, ver
`data/LICENSE-microdatasus`) e só incluem campos cujos códigos observados
em arquivos reais estão todos cobertos. Um código fora do dicionário —
que pode aparecer em anos ou UFs não verificados — vira `missing` com um
`@warn` que diz qual é e em quantos registros.

`copiar = false` padroniza `df` no lugar. Chamado automaticamente por
[`fetch_datasus`](@ref) para `:CNES_ST` e `:CNES_PF`.

!!! note "Não verificado"
    Os rótulos não foram conferidos contra as tabelas oficiais do DATASUS
    (`TAB_CNES`), indisponíveis no momento da escrita. Em `NIV_HIER`, os
    códigos 3 e 6 têm o mesmo rótulo ("Média M2 e M3") no dicionário de
    origem.
"""
function process_cnes(df::DataFrame; copiar::Bool = true)
    copiar && (df = copy(df))
    for (campo, (rot, ign)) in _rotulos_cnes()
        rotular!(df, campo, rot; ignora_zeros = true, avisar = true, ignorados = ign)
    end
    return df
end

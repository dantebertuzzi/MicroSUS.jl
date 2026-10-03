# Os três leem os mesmos valores? Exporta colunas de cada arquivo pelas três
# ferramentas, normalizadas para texto, e compara célula a célula.
#
#   DBC=<pasta> RSCRIPT=<Rscript> python benchmark/confere.py
import csv, datetime, os, subprocess, sys, tempfile
from dbfread import DBF
from pyreaddbc import dbc2dbf

DBC = os.environ["DBC"]
RSCRIPT = os.environ.get("RSCRIPT", "Rscript")
COLUNAS = {
    "DOPE2023.dbc": ["DTOBITO", "CAUSABAS", "CODMUNRES", "IDADE", "SEXO", "LINHAA"],
    "DOSP2023.dbc": ["DTOBITO", "CAUSABAS", "CODMUNRES", "IDADE", "SEXO", "LINHAA"],
    "DNSP2023.dbc": ["DTNASC", "CODMUNRES", "PESO", "IDADEMAE", "SEXO", "SEMAGESTAC"],
    "DENGBR23.dbc": ["DT_NOTIFIC", "ID_MN_RESI", "CLASSI_FIN", "NU_IDADE_N", "CS_SEXO"],
}

def norm(x):
    if x is None:
        return ""
    if isinstance(x, (datetime.date, datetime.datetime)):
        return x.strftime("%Y%m%d")
    if isinstance(x, float):
        return str(int(x)) if x.is_integer() else repr(x)
    return str(x).strip()

def le_python(arq, cols):
    with tempfile.TemporaryDirectory() as d:
        dbf = os.path.join(d, "x.dbf")
        dbc2dbf(arq, dbf)
        return [[norm(r[c]) for c in cols] for r in DBF(dbf, encoding="iso-8859-1")]

R = r'''
a <- commandArgs(TRUE); suppressPackageStartupMessages(library(microdatasus))
d <- microdatasus:::read_dbc(a[1], as_character = TRUE); cols <- strsplit(a[2], ",")[[1]]
f <- function(x) { x <- trimws(as.character(x)); x[is.na(x)] <- ""
  sub("^([0-9]{4})-([0-9]{2})-([0-9]{2})$", "\\1\\2\\3", x) }
out <- as.data.frame(lapply(d[cols], f), stringsAsFactors = FALSE)
write.table(out, a[3], sep = "\t", quote = FALSE, row.names = FALSE, col.names = FALSE, na = "")
'''
JL = r'''
using MicroSUS, Dates
arq, cols, saida = ARGS[1], Symbol.(split(ARGS[2], ",")), ARGS[3]
t = MicroSUS.materializar(ler(arq; colunas = cols, schema = nothing, pool = false))
f(x::Missing) = ""; f(x::Date) = Dates.format(x, "yyyymmdd")
f(x::AbstractFloat) = isinteger(x) ? string(Int(x)) : string(x); f(x) = strip(string(x))
open(saida, "w") do io
    for i in 1:length(t[cols[1]])
        println(io, join((f(t[c][i]) for c in cols), '\t'))
    end
end
'''

def le_tsv(p, ncols):
    with open(p, encoding="utf-8", errors="replace") as f:
        return [(l.rstrip("\n").split("\t") + [""] * ncols)[:ncols] for l in f]

with tempfile.TemporaryDirectory() as tmp:
    rs, js = os.path.join(tmp, "r.R"), os.path.join(tmp, "j.jl")
    open(rs, "w").write(R); open(js, "w").write(JL)
    for arq, cols in COLUNAS.items():
        p = os.path.join(DBC, arq)
        tr, tj = os.path.join(tmp, "r.tsv"), os.path.join(tmp, "j.tsv")
        subprocess.run([RSCRIPT, rs, p, ",".join(cols), tr], check=True)
        subprocess.run(["julia", "--project=.", js, p, ",".join(cols), tj], check=True)
        py, r, j = le_python(p, cols), le_tsv(tr, len(cols)), le_tsv(tj, len(cols))
        print(f"{arq}: linhas julia={len(j)} R={len(r)} python={len(py)}")
        for k, c in enumerate(cols):
            dif_r = sum(1 for a, b in zip(j, r) if a[k] != b[k])
            dif_p = sum(1 for a, b in zip(j, py) if a[k] != b[k])
            ex = next(((a[k], b[k]) for a, b in zip(j, r) if a[k] != b[k]), None)
            print(f"  {c:12s} ≠R: {dif_r:8d}  ≠Python: {dif_p:8d}" + (f"   ex. julia={ex[0]!r} R={ex[1]!r}" if ex else ""))

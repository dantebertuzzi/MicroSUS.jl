# Pilha de leitura do PySUS (pyreaddbc + dbfread + pandas) — uma medição:
#   python benchmark/bench_python.py ARQUIVO TAREFA [REPETICOES]
import gc, os, re, statistics, sys, tempfile, time
from importlib.metadata import version
import pandas as pd
from dbfread import DBF
from pyreaddbc import dbc2dbf

def rss(campo):
    with open("/proc/self/status") as f:
        for l in f:
            if l.startswith(campo + ":"):
                return int(re.sub(r"\D", "", l)) / 1024

CVLI = re.compile(r"^(X8[5-9]|X9|Y0[0-9]|Y871)")   # o mesmo recorte de eh_agressao

def le(arq):
    # como o PySUS: .dbc → .dbf (pyreaddbc), .dbf → registros (dbfread) → pandas
    with tempfile.TemporaryDirectory() as d:
        dbf = os.path.join(d, "x.dbf")
        dbc2dbf(arq, dbf)
        return pd.DataFrame(iter(DBF(dbf, encoding="iso-8859-1", char_decode_errors="replace")))

def tarefa(arq, t):
    if t == "tudo":
        return le(arq)
    if t == "cvli":
        d = le(arq)
        return d.loc[d["CAUSABAS"].fillna("").str.match(CVLI), ["DTOBITO", "CAUSABAS", "CODMUNRES"]]
    raise SystemExit(f"tarefa sem equivalente no Python: {t}")

arq, t = sys.argv[1], sys.argv[2]
reps = int(sys.argv[3]) if len(sys.argv) > 3 else 3
gc.collect(); base = rss("VmRSS")
t0 = time.perf_counter(); df = tarefa(arq, t); frio = time.perf_counter() - t0
pico = rss("VmHWM")
dims = df.shape; del df
quentes = []
for _ in range(reps):
    gc.collect()
    t0 = time.perf_counter(); tarefa(arq, t); quentes.append(time.perf_counter() - t0)
print('{"ferramenta":"pyreaddbc %s + dbfread %s + pandas %s (Python %s)","arquivo":"%s","tarefa":"%s","linhas":%d,"colunas":%d,"t_frio":%.3f,"t_quente":%.3f,"rss_base_mb":%.1f,"rss_pico_mb":%.1f}' % (
    version("pyreaddbc"), version("dbfread"), version("pandas"), sys.version.split()[0],
    os.path.basename(arq), t, dims[0], dims[1], frio, statistics.median(quentes), base, pico))

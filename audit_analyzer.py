import hashlib, re, unicodedata
def normalizar(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c)).lower()
def analisar(texto, cadastro, categoria="original", metodo="texto", hash_pdf=None):
    raw = texto[:6000]
    norm = normalizar(raw)
    cab = norm[:1800]
    regex = r"\b(portaria|resolucao\s+administrativa|resolucao)\b([^\n]{0,100}?)\s+(?:n[.\s]*[o°]?\s*)?([0-9]{1,4}(?:\.[0-9]{3})*)\s*/\s*(20[0-9]{2}|19[0-9]{2})\b"
    m = re.search(regex, cab)
    base = {"estado":"inconclusivo","documento":None,"evidencia":raw[:1800],"metodo":metodo,"hash_evidencia":hash_pdf or hashlib.sha256(raw.encode()).hexdigest(),"motivo":""}
    if not m:
        base["motivo"]="Cabeçalho com tipo, número e ano não reconhecido de forma inequívoca."
        return base
    tipo = "Portaria" if m.group(1)=="portaria" else "Resolução"
    numero = int(m.group(3).replace(".",""))
    ano = int(m.group(4))
    emissor = None
    if tipo=="Portaria":
        area = m.group(2)
        if re.search(r"\b(?:dg|diretoria[- ]geral)\b",area):
            emissor="Diretoria-Geral"
        elif re.search(r"\bvp\b|vice[- ]presid",area):
            emissor="Vice-Presidência"
        elif re.search(r"\bgp\b|presid",area) or re.search(r"(?:desembargador|desembargadora)\s+presidente",cab):
            emissor="Presidência"
    else:
        if "administrativa" in m.group(1) or re.search(r"\bra\b",m.group(2)):
            emissor="Administrativa"
    base["documento"]={"tipo":tipo,"numero":numero,"ano":ano,"emissor":emissor}
    if categoria!="original":
        base["motivo"]="Arquivo compilado ou anexo: identificar o original antes de validar a identidade."
        return base
    if not emissor:
        base["motivo"]="Número e ano candidatos identificados; espécie/emissor insuficientes para validar o tipo."
        return base
    divergencias=[]
    if tipo!=cadastro["tipo"]:
        divergencias.append("tipo")
    if tipo=="Portaria" and emissor!="Presidência":
        divergencias.append("emissor")
    if tipo=="Resolução" and emissor!="Administrativa":
        divergencias.append("espécie")
    if numero!=cadastro["numero"]:
        divergencias.append("número")
    if ano!=cadastro["ano"]:
        divergencias.append("ano")
    base["estado"]="divergente" if divergencias else "conferente_automatico"
    base["motivo"]="Divergência em: "+", ".join(divergencias) if divergencias else "Cabeçalho compatível; conferência automática, sem validação humana."
    return base
